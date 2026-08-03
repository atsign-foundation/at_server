import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/config/at_config.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/crypto/signing_key_constants.dart';
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

  /// Matches [PolVerbHandler]'s retry budget for the same class of call: an
  /// unauthenticated outbound lookup on a possibly-pooled, possibly-stale
  /// client.
  static const _maxOutboundAttempts = 2;

  final AtAccessLog accessLog;

  /// Used only on the peer path, to fetch the peer's own outbound connection
  /// and ask what signature types it publishes — a *separate* connection from
  /// the inbound one the peer dialed in on. The pool carries this connection
  /// through to POL, which reuses it to fetch the cookie.
  final OutboundClientManager outboundClientManager;

  final _dummyInboundConnection = DummyInboundConnection();

  FromVerbHandler(super.keyStore,
      {required this.accessLog, required this.outboundClientManager}) {
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

    logger.finer('fromAtSign : $fromAtSign currentAtSign : $currentAtSign');
    final bool isSelf = fromAtSign == currentAtSign;
    if (isSelf) {
      atConnectionMetadata.self = true;
    }

    if (!isSelf && AtSecondaryConfig.clientCertificateRequired) {
      var result = await _verifyFromAtSign(fromAtSign, atConnection);
      logger.finer('_verifyFromAtSign result : $result');
      if (!result) {
        throw UnAuthenticatedException('Certificate Verification Failed');
      }
    }

    // Only after the cert check passes: UnAuthenticatedException does not close
    // the connection (see GlobalExceptionHandler), so marking `from` earlier
    // would leave a cert-failed connection open and half-authenticated.
    if (!isSelf) {
      atConnectionMetadata.from = true;
      atConnectionMetadata.fromAtSign = fromAtSign;
    }

    //store key with private/public prefix, sessionId and fromAtSign
    String storedSecretId =
        '$keyPrefix${atConnectionMetadata.sessionID}$fromAtSign';

    // The challenge the peer/client signs, and what we store locally to
    // verify it later. Peer pol auth (fromAtSign != currentAtSign) gets a
    // verifier-bound challenge naming this server; when we and the peer share
    // a negotiable signature type, the challenge also demands it, and the
    // chosen type plus the peer's key for it are cached alongside the
    // challenge so POL needs no record fetch of its own. POL verifies the
    // signature over the challenge, so the demand is covered by that
    // signature. The self path (client PKAM/CRAM) keeps the bare UUID it
    // always has.
    final String challenge;
    final String storedValue;
    if (isSelf) {
      challenge = Uuid().v4();
      storedValue = challenge;
    } else {
      final chosen = await _chooseAlgoFor(fromAtSign);
      challenge = SecondaryUtil.buildBoundPolChallenge(currentAtSign,
          chosenAlgo: chosen?.type);
      storedValue = StoredPolChallenge(
              challenge: challenge,
              chosenAlgo: chosen?.type,
              peerPublicKey: chosen?.publicKey)
          .encode();
    }
    logger.finer('Storing challenge to $storedSecretId');
    await _storeSecret(storedSecretId, storedValue);
    response.data =
        '$responsePrefix${atConnectionMetadata.sessionID}$fromAtSign:$challenge';

    try {
      await accessLog.insert(fromAtSign, from.name());
    } on DataStoreException catch (e) {
      logger.severe('Hive error adding to access log:${e.toString()}');
    }
  }

  /// Persists [data] as the handshake challenge at [storedSecretId], TTL 60s.
  Future<void> _storeSecret(String storedSecretId, String data) async {
    final atData = AtData()
      ..data = data
      ..metaData = (AtMetaData()..ttl = 60 * 1000); //expire in 1 min
    await keyStore.put(storedSecretId, atData);
  }

  /// Picks the signature type to demand from [fromAtSign] — this server's
  /// decision, via [chooseNegotiatedAlgo] — and fetches the peer's key for it.
  ///
  /// Returns `null` — meaning "demand nothing, fall back to legacy RSA" —
  /// when we hold no negotiable key of our own
  /// ([SigningKeyManager.isInitialised] false, e.g. `disablePqAuth` or a
  /// failed init), the peer publishes no record, or nothing in it matches a
  /// type we hold. Read off the singleton rather than injected, matching
  /// [AtSecondaryServerImpl.signingKeyManager]'s existing use elsewhere in
  /// this class.
  ///
  /// A fetch failure is treated the same as "no record" unless
  /// [AtSecondaryConfig.failClosedOnPqNegotiationFetchFailure] is set, in
  /// which case it is rethrown and fails the from: command outright.
  Future<({String type, String publicKey})?> _chooseAlgoFor(
      Atsign fromAtSign) async {
    final manager = AtSecondaryServerImpl.getInstance().signingKeyManager;
    if (!manager.isInitialised) return null;

    String? record;
    try {
      record = await _fetchPeerSigningPublicKeys(fromAtSign);
    } catch (e) {
      logger.warning('Failed to fetch signing_publickeys for $fromAtSign: $e');
      if (AtSecondaryConfig.failClosedOnPqNegotiationFetchFailure) {
        rethrow;
      }
      return null;
    }
    return record == null
        ? null
        : chooseNegotiatedAlgo(manager.availableTypes, record);
  }

  /// Fetches [fromAtSign]'s `signing_publickeys` record over our own
  /// unauthenticated outbound connection to its server.
  ///
  /// A pooled client may be reused here; if its socket died without a
  /// detectable close (peer restart) the reuse times out rather than failing
  /// to connect, so on failure we discard it and retry once with a fresh
  /// connection — mirroring [PolVerbHandler]'s cookie fetch.
  Future<String?> _fetchPeerSigningPublicKeys(Atsign fromAtSign) async {
    for (int attempt = 0;; attempt++) {
      final oc = await outboundClientManager.getClient(
          fromAtSign, _dummyInboundConnection,
          handshakeRequired: false);
      String doing = '';
      try {
        if (!oc.isConnectionCreated) {
          doing = 'connecting to $fromAtSign';
          await oc.connect();
        }
        doing = 'fetching signing_publickeys from $fromAtSign';
        return stripDataPrefix(
            await oc.plookUp('$signingPublicKeysRecordName$fromAtSign'));
      } on Exception catch (e) {
        await oc.outboundConnection?.close();
        if (attempt >= _maxOutboundAttempts - 1) {
          logger.severe('Exception while $doing (final attempt) : $e');
          rethrow;
        }
        logger.info('Exception while $doing; retrying with a fresh outbound '
            'connection : $e');
      }
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
