import 'dart:collection';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/notification_util.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_utils.dart';

class DeleteVerbHandler extends AbstractVerbHandler {
  static Delete delete = Delete();
  static final AUTO_NOTIFY = AtSecondaryConfig.autoNotify;

  DeleteVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith(getName(VerbEnum.delete) + ':');

  @override
  Verb getVerb() {
    return delete;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {
    var deleteKey = verbParams[AT_KEY];
    assert(deleteKey.isNotEmpty);
    deleteKey = deleteKey.trim().toLowerCase().replaceAll(' ', '');
    if (deleteKey == AT_CRAM_SECRET) {
      await keyStore.put(AT_CRAM_SECRET_DELETED, AtData()..data = 'true');
    }
    var result = await keyStore.remove(deleteKey);
    response.data = result?.toString();
    logger.finer('delete success. delete key: $deleteKey');
    try {
      if (!deleteKey.startsWith('@')) {
        return;
      }
      var index = deleteKey.indexOf(':');
      var forAtSign = deleteKey.substring(0, index);
      var key = deleteKey.substring(index + 1);
      var fromAtSign = key.substring(key.indexOf('@'));
      fromAtSign = AtUtils.formatAtSign(fromAtSign);
      // store notification entry
      await NotificationUtil.storeNotification(atConnection, fromAtSign,
          forAtSign, key, NotificationType.sent, OperationType.delete);
      // send notification to other secondary is AUTO_NOTIFY is enabled
      if (AUTO_NOTIFY && (fromAtSign != forAtSign)) {
        deleteKey = 'delete:' + deleteKey;
        try {
          await NotificationUtil.sendNotification(
              forAtSign, atConnection, deleteKey);
        } catch (exception) {
          logger.severe(
              'Exception while sending notification ${exception.toString()}');
        }
      }
    } catch (exception) {
      logger.severe(
          'Exception while sending notification ${exception.toString()}');
    }
  }
}
