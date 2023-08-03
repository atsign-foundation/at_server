import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';

class LocalLookupVerbHandler extends AbstractVerbHandler {
  static LocalLookup llookup = LocalLookup();

  LocalLookupVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.llookup)}:');

  @override
  Verb getVerb() {
    return llookup;
  }

  @override
  HashMap<String, String?> parse(String command) {
    var verbParams = super.parse(command);
    if (command.contains('public:')) {
      verbParams.putIfAbsent('isPublic', () => 'true');
    }
    if (command.contains('cached:')) {
      verbParams.putIfAbsent('isCached', () => 'true');
    }
    return verbParams;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var forAtSign = verbParams[FOR_AT_SIGN];
    var atSign = verbParams[AT_SIGN];
    var key = verbParams[AT_KEY];
    var operation = verbParams[OPERATION];
    atSign = AtUtils.fixAtSign(atSign!);
    var keyNamespace = key?.substring(key.lastIndexOf('.') + 1);
    key = '$key$atSign';
    bool isPublic = false;
    if (forAtSign != null) {
      forAtSign = AtUtils.fixAtSign(forAtSign);
      key = '$forAtSign:$key';
    }
    if (verbParams.containsKey('isPublic')) {
      key = 'public:$key';
      isPublic = true;
    }
    if (verbParams.containsKey('isCached')) {
      key = 'cached:$key';
    }
    final enrollApprovalId =
        (atConnection.getMetaData() as InboundConnectionMetadata)
            .enrollmentId;
    bool isAuthorized = true; // for legacy clients allow access by default
    if (!isPublic && enrollApprovalId != null && keyNamespace != null) {
      isAuthorized = await super.isAuthorized(enrollApprovalId, keyNamespace);
    }
    if (!isAuthorized) {
      throw UnAuthorizedException(
          'Enrollment Id: $enrollApprovalId is not authorized for local lookup operation on the key: $key');
    }
    AtData? atData = await keyStore.get(key);
    var isActive = false;
    isActive = SecondaryUtil.isActiveKey(atData);
    if (isActive) {
      logger.finer('isActiveKey($key) : $isActive');
      response.data = SecondaryUtil.prepareResponseData(operation, atData);
    }
  }
}
