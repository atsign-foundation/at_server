import 'dart:collection';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
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
    var deleteKey;
    var atSign = AtUtils.formatAtSign(verbParams[AT_SIGN]);
    deleteKey = '${verbParams[AT_KEY]}${atSign}';
    if (verbParams[FOR_AT_SIGN] != null) {
      deleteKey =
      '${AtUtils.formatAtSign(verbParams[FOR_AT_SIGN])}:${deleteKey}';
    }
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
      var forAtSign = verbParams[FOR_AT_SIGN];
      var key = verbParams[AT_KEY];
      var atSign = verbParams[AT_SIGN];
      forAtSign = AtUtils.formatAtSign(forAtSign);
      atSign = AtUtils.formatAtSign(atSign);

      // send notification to other secondary is AUTO_NOTIFY is enabled
      if (AUTO_NOTIFY && (forAtSign != atSign)) {
        try {
          _notify(forAtSign, atSign, key,
              SecondaryUtil().getNotificationPriority(verbParams[PRIORITY]));
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

  void _notify(forAtSign, atSign, key, priority) {
    if (forAtSign == null) {
      return;
    }
    key = '${forAtSign}:${key}${atSign}';
    var atNotification = (AtNotificationBuilder()
      ..type = NotificationType.sent
      ..fromAtSign = atSign
      ..toAtSign = forAtSign
      ..notification = key
      ..priority = priority
      ..opType = OperationType.delete)
        .build();
    NotificationManager.getInstance().notify(atNotification);
  }
}
