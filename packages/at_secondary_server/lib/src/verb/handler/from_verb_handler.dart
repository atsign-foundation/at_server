import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:uuid/uuid.dart';

class FromVerbHandler extends AbstractVerbHandler {
  static From from = From();
  static final _rootDomain = AtSecondaryConfig.rootServerUrl;
  static final _rootPort = AtSecondaryConfig.rootServerPort;
  static final bool? clientCertificateRequired =
      AtSecondaryConfig.clientCertificateRequired;

  FromVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

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
    atConfigInstance = AtConfig(
        await AtCommitLogManagerImpl.getInstance().getCommitLog(currentAtSign),
        currentAtSign);
    atConnection.initiatedBy = currentAtSign;
    var atConnectionMetadata =
        atConnection.getMetaData() as InboundConnectionMetadata;
    var fromAtSign = verbParams[AT_SIGN];
    if (verbParams[CLIENT_CONFIG] != null &&
        verbParams[CLIENT_CONFIG]!.isNotEmpty) {
      atConnectionMetadata.clientVersion =
          jsonDecode(verbParams[CLIENT_CONFIG]!)[VERSION];
    }
    fromAtSign = AtUtils.formatAtSign(fromAtSign);
    fromAtSign = AtUtils.fixAtSign(fromAtSign!);
    var atData = AtData();
    var keyPrefix = (fromAtSign == currentAtSign) ? 'private:' : 'public:';
    var responsePrefix = (fromAtSign == currentAtSign) ? 'data:' : 'proof:';
    var proof = Uuid().v4(); // proof
    atData.data = proof;

    var inBlockList = await atConfigInstance.checkInBlockList(fromAtSign);

    if (inBlockList) {
      logger.severe('$fromAtSign is in blocklist of $currentAtSign');
      throw BlockedConnectionException('Unable to connect');
    }

    if (fromAtSign != AtSecondaryServerImpl.getInstance().currentAtSign &&
        clientCertificateRequired!) {
      var result = await _verifyFromAtSign(fromAtSign, atConnection);
      logger.finer('_verifyFromAtSign result : $result');
      if (!result) {
        throw UnAuthenticatedException('Certificate Verification Failed');
      }
    }

    //store key with private/public prefix, sessionId and fromAtSign
    await keyStore.put(
        '$keyPrefix${atConnectionMetadata.sessionID}$fromAtSign', atData,
        time_to_live: 60 * 1000); //expire in 1 min
    response.data =
        '$responsePrefix${atConnectionMetadata.sessionID}$fromAtSign:$proof';

    logger.finer('fromAtSign : $fromAtSign currentAtSign : $currentAtSign');
    if (fromAtSign == currentAtSign) {
      atConnectionMetadata.self = true;
    } else {
      atConnectionMetadata.from = true;
      atConnectionMetadata.fromAtSign = fromAtSign;
    }
    var atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    try {
      await atAccessLog?.insert(fromAtSign, from.name());
    } on DataStoreException catch (e) {
      logger.severe('Hive error adding to access log:${e.toString()}');
    }
  }

  Future<bool> _verifyFromAtSign(
      String fromAtSign, InboundConnection atConnection) async {
    logger.finer(
        'In _verifyFromAtSign fromAtSign : $fromAtSign, rootDomain : $_rootDomain, port : $_rootPort');
    // ignore: deprecated_member_use
    var secondaryUrl = await AtLookupImpl.findSecondary(fromAtSign, _rootDomain, _rootPort!);
    if (secondaryUrl == null) {
      throw SecondaryNotFoundException(
          'No secondary url found for atsign: $fromAtSign');
    }
    logger.finer('_verifyFromAtSign secondaryUrl : $secondaryUrl');
    var secondaryInfo = SecondaryUtil.getSecondaryInfo(secondaryUrl);
    var host = secondaryInfo[0];
    var secSocket = atConnection.getSocket() as SecureSocket;
    logger.finer('secSocket : $secSocket');
    var cn = secSocket.peerCertificate;
    logger.finer('CN : $cn');
    if (cn == null) {
      logger.finer(
          'CN is null.stream flag ${atConnection.getMetaData().isStream}');
      return atConnection.getMetaData().isStream;
    }

    if (clientCertificateRequired!) {
      var result = _verifyClientCerts(cn, host);
      return result;
    }
    return true;
  }

  bool _verifyClientCerts(X509Certificate cn, String host) {
    var subject = cn.subject;
    logger.finer('Connected from: $subject');
    if (subject.contains(host)) {
      return true;
    }
    // If you would like to see the cert
    var x509Pem = cn.pem;
    // test with an internet available certificate to ensure we are picking out the SAN and not the CN
    var data = X509Utils.x509CertificateFromPem(x509Pem);
    var subjectAlternativeName = data.subjectAlternativNames!;
    logger.finer('SAN: $subjectAlternativeName');
    if (subjectAlternativeName.contains(host)) {
      return true;
    }
    var commonName = data.subject['2.5.4.3']!;
    logger.finer('CN: $commonName');
    if (commonName.contains(host)) {
      return true;
    }
    return false;
  }
}
