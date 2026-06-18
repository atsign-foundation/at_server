import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/config/at_config.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
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

  final AtCommitLog commitLog;
  final AtAccessLog accessLog;

  FromVerbHandler(super.keyStore, super.context,
      {required this.commitLog, required this.accessLog}) {
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
    var currentAtSign = context.currentAtSign;
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

    if (fromAtSign != context.currentAtSign &&
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
    final AtData atData = AtData();
    final String proof = Uuid().v4(); // proof
    atData.data = proof;
    atData.metaData = AtMetaData()..ttl = 60 * 1000; //expire in 1 min
    logger.finer('Storing secret to $storedSecretId');
    await keyStore.put(storedSecretId, atData);
    response.data =
        '$responsePrefix${atConnectionMetadata.sessionID}$fromAtSign:$proof';

    logger.finer('fromAtSign : $fromAtSign currentAtSign : $currentAtSign');
    if (fromAtSign == currentAtSign) {
      atConnectionMetadata.self = true;
    } else {
      atConnectionMetadata.from = true;
      atConnectionMetadata.fromAtSign = fromAtSign;
    }
    try {
      await accessLog.insert(fromAtSign, from.name());
    } on DataStoreException catch (e) {
      logger.severe('Hive error adding to access log:${e.toString()}');
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
