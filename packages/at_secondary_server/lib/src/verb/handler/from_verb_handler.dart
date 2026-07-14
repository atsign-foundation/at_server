import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_chops/at_chops_ffi.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/config/at_config.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/crypto/pq_key_fetch.dart';
import 'package:at_secondary/src/crypto/pq_key_manager.dart';
import 'package:at_secondary/src/crypto/x_wing_cert.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:uuid/uuid.dart';

class FromVerbHandler extends AbstractVerbHandler {
  static From from = From();
  static final _rootDomain = AtSecondaryConfig.rootServerUrl;
  static final _rootPort = AtSecondaryConfig.rootServerPort;

  final AtAccessLog? accessLog;

  /// Used to live-fetch a peer's published PQ cert on first contact so the
  /// initial handshake can be PQ-safe.
  final OutboundClientManager outboundClientManager;

  /// Defaults to [AtSecondaryConfig.disablePqAuth]; an instance field (rather
  /// than reading the config statically) so tests can inject the value
  /// instead of toggling process env vars.
  final bool disablePqAuth;

  FromVerbHandler(super.keyStore, this.outboundClientManager,
      {required this.accessLog, bool? disablePqAuth})
      : disablePqAuth = disablePqAuth ?? AtSecondaryConfig.disablePqAuth {
    logger.level = 'info';
  }

  late AtConfig atConfigInstance;

  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.from)}:');

  @override
  Verb getVerb() {
    return from;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    atConfigInstance = AtConfig(keyStore, currentAtSign);
    atConnection.initiatedBy = currentAtSign;
    var atConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    Atsign fromAtSign = verbParams[AtConstants.atSign]!.toAtsign();

    if (verbParams[AtConstants.clientConfig] != null &&
        verbParams[AtConstants.clientConfig]!.isNotEmpty) {
      var decodedClientConfig =
          jsonDecode(verbParams[AtConstants.clientConfig]!);
      atConnectionMetadata
        ..clientVersion = decodedClientConfig[AtConstants.version]
        ..clientId = decodedClientConfig[AtConstants.clientId]
        ..appName = decodedClientConfig[AtConstants.appName]
        ..appVersion = decodedClientConfig[AtConstants.appVersion]
        ..platform = decodedClientConfig[AtConstants.platform];
    }

    var keyPrefix = (fromAtSign == currentAtSign) ? 'private:' : 'public:';
    var responsePrefix = (fromAtSign == currentAtSign) ? 'data:' : 'proof:';

    var inBlockList = await atConfigInstance.checkInBlockList(fromAtSign);

    if (inBlockList) {
      logger.severe('$fromAtSign is in blocklist of $currentAtSign');
      throw BlockedConnectionException('Unable to connect');
    }

    if (fromAtSign != AtSecondaryServerImpl.getInstance().currentAtSign &&
        AtSecondaryConfig.clientCertificateRequired) {
      var result = await _verifyFromAtSign(fromAtSign, atConnection);
      logger.finer('_verifyFromAtSign result : $result');
      if (!result) {
        throw UnAuthenticatedException('Certificate Verification Failed');
      }
    }

    //store key with private/public prefix, sessionId and fromAtSign
    String storedSecretId =
        '$keyPrefix${atConnectionMetadata.sessionID}$fromAtSign';

    // Try the PQ path: live-fetch fromAtSign's X-Wing cert.
    if (fromAtSign != currentAtSign) {
      String? pqProof;
      if (!disablePqAuth) {
        pqProof = await _tryBuildPqProof(
            fromAtSign.toString(),
            atConnectionMetadata.sessionID!,
            storedSecretId);
      }
      if (pqProof != null) {
        response.data =
            '$responsePrefix${atConnectionMetadata.sessionID}$fromAtSign:$pqProof';
        logger.finer('PQ proof issued for $fromAtSign');
        // fall through to set from/access-log metadata below
      } else {
        // Legacy UUID path
        final AtData atData = AtData();
        final String proof = Uuid().v4();
        atData.data = proof;
        atData.metaData = AtMetaData()..ttl = 60 * 1000;
        logger.finer('Storing legacy secret to $storedSecretId');
        await keyStore.put(storedSecretId, atData);
        response.data =
            '$responsePrefix${atConnectionMetadata.sessionID}$fromAtSign:$proof';
      }
    } else {
      // Self (private: prefix) always uses UUID — no server-to-server PQ needed
      final AtData atData = AtData();
      final String proof = Uuid().v4();
      atData.data = proof;
      atData.metaData = AtMetaData()..ttl = 60 * 1000;
      await keyStore.put(storedSecretId, atData);
      response.data =
          '$responsePrefix${atConnectionMetadata.sessionID}$fromAtSign:$proof';
    }

    logger.finer('fromAtSign : $fromAtSign currentAtSign : $currentAtSign');
    if (fromAtSign == currentAtSign) {
      atConnectionMetadata.self = true;
    } else {
      atConnectionMetadata.from = true;
      atConnectionMetadata.fromAtSign = fromAtSign;
    }
    try {
      await accessLog?.insert(fromAtSign, from.name());
    } on DataStoreException catch (e) {
      logger.severe('Hive error adding to access log:${e.toString()}');
    }
  }

  /// Returns a `pq:<base64Url(ciphertext)>` proof string and stores a
  /// `pq:<key-confirmation-tag>` locally at [storedSecretId] if the remote's
  /// X-Wing cert can be live-fetched and passes ML-DSA-65 verification.
  /// Returns null to fall back to the legacy UUID flow — every abandon
  /// branch is logged so a stuck-on-legacy peer is diagnosable.
  Future<String?> _tryBuildPqProof(
      String fromAtSign, String sessionID, String storedSecretId) async {
    try {
      // Always fetch the peer's published PQ cert live (unauthenticated
      // plookUp). Nothing is cached:
      // each handshake honours the peer's current keys, so there is no
      // stale-cert failure mode.
      final certRaw = await fetchPeerPqCert(outboundClientManager, fromAtSign);
      if (certRaw == null) {
        logger.info('No PQ cert fetched for $fromAtSign — falling back to UUID');
        return null;
      }

      final cert = XWingCert.tryParse(certRaw);
      if (cert == null) {
        logger.info('PQ cert for $fromAtSign failed to parse — falling back to UUID');
        return null;
      }
      if (!await cert.verify()) {
        logger.info('PQ cert for $fromAtSign failed verification — falling back to UUID');
        return null;
      }

      final result = await AtPqc.xWing.encapsulate(cert.xwingPublicKey);
      final ciphertextB64 = base64Url.encode(result.ciphertext);

      // Store an HKDF key-confirmation tag (bound to this handshake) rather
      // than the raw shared secret, so the secret never traverses the wire —
      // POL compares tags. The 'pq:' prefix marks PQ mode; the wire proof
      // carries the ciphertext under the 'pq' challenge marker.
      final tag =
          deriveConfirmationTag(result.sharedSecret, '$sessionID$fromAtSign');
      final atData = AtData()
        ..data = 'pq:${base64Url.encode(tag)}'
        ..metaData = (AtMetaData()..ttl = 60 * 1000);
      await keyStore.put(storedSecretId, atData);

      return 'pq:$ciphertextB64';
    } catch (e) {
      logger.warning('PQ proof attempt failed, falling back to UUID: $e');
      return null;
    }
  }

  Future<bool> _verifyFromAtSign(
      String fromAtSign, InboundConnection atConnection) async {
    logger.finer(
        'In _verifyFromAtSign fromAtSign : $fromAtSign, rootDomain : $_rootDomain, port : $_rootPort');
    var secondaryUrl = (await AtSecondaryServerImpl.getInstance()
            .secondaryAddressFinder
            .findSecondary(fromAtSign))
        .toString();

    logger.finer('_verifyFromAtSign secondaryUrl : $secondaryUrl');
    var secondaryInfo = SecondaryUtil.getSecondaryInfo(secondaryUrl);
    var host = secondaryInfo[0];
    var secSocket = atConnection.underlying as SecureSocket;
    logger.finer('secSocket : $secSocket');
    var cn = secSocket.peerCertificate;
    logger.finer('CN : $cn');
    if (cn == null) {
      logger.finer('CN is null.stream flag ${atConnection.metaData.isStream}');
      return atConnection.metaData.isStream;
    }

    if (AtSecondaryConfig.clientCertificateRequired) {
      var result = _verifyClientCerts(cn, host);
      return result;
    }
    return true;
  }

  bool _verifyClientCerts(X509Certificate cn, String host) {
    logger.info(
        'Connected from: $cn : ${cn.subject} issued by ${cn.issuer} valid from ${cn.startValidity} to ${cn.endValidity}');

    X509CertificateData certData = X509Utils.x509CertificateFromPem(cn.pem);
    List<String> subjectAlternativeNames =
        certData.tbsCertificate?.extensions?.subjectAlternativNames ?? [];
    logger.info('SAN: $subjectAlternativeNames');

    String commonName = certData.tbsCertificate?.subject['2.5.4.3'] ?? '';
    logger.info('CN: $commonName');

    bool matched = false;

    if (cn.subject.trim() == host ||
        cn.subject.replaceFirst('/CN=', '').trim() == host) {
      logger.info('Matched host "$host" to cn.subject ${cn.subject}');
      matched = true;
    }

    if (subjectAlternativeNames.contains(host)) {
      logger.info(
          'Matched host "$host" to subjectAlternativeNames $subjectAlternativeNames');
      matched = true;
    }

    if (commonName == host) {
      logger.info('Matched host "$host" to commonName $commonName');
      matched = true;
    }

    return matched;
  }
}
