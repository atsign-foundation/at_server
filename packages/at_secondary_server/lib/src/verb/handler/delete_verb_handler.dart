import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/change_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';

class DeleteVerbHandler extends ChangeVerbHandler {
  static Delete delete = Delete();
  static bool _autoNotify = AtSecondaryConfig.autoNotify;
  Set<String>? protectedKeys;

  DeleteVerbHandler(SecondaryKeyStore keyStore,
      StatsNotificationService statsNotificationService)
      : super(keyStore, statsNotificationService);

  //setter to set autoNotify value from dynamic server config "config:set".
  //only works when testingMode is set to true
  static setAutoNotify(bool newState) {
    if (AtSecondaryConfig.testingMode) {
      _autoNotify = newState;
    }
  }

  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.delete)}:');

  @override
  Verb getVerb() {
    return delete;
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
    String? atSign = AtUtils.formatAtSign(verbParams[AT_SIGN]);
    var deleteKey = verbParams[AT_KEY];
    // If key is cram secret do not append atsign.
    if (verbParams[AT_KEY] != AT_CRAM_SECRET) {
      deleteKey = '$deleteKey$atSign';
    }
    // fetch protected keys listed in config.yaml
    protectedKeys ??= _getProtectedKeys(atSign);
    // check to see if a key is protected. Cannot delete key if it's protected
    if (_isProtectedKey(deleteKey!)) {
      throw UnAuthorizedException(
          'Cannot delete protected key: \'$deleteKey\'');
    }
    // Sets Response bean to the response bean in ChangeVerbHandler
    await super.processVerb(response, verbParams, atConnection);
    var keyNamespace =
        verbParams[AT_KEY]!.substring(deleteKey.lastIndexOf('.') + 1);
    if (verbParams[FOR_AT_SIGN] != null) {
      deleteKey = '${AtUtils.formatAtSign(verbParams[FOR_AT_SIGN])}:$deleteKey';
    }
    if (verbParams['isPublic'] == 'true') {
      deleteKey = 'public:$deleteKey';
    }
    if (verbParams['isCached'] == 'true') {
      deleteKey = 'cached:$deleteKey';
    }
    assert(deleteKey.isNotEmpty);
    deleteKey = deleteKey.trim().toLowerCase().replaceAll(' ', '');
    if (deleteKey == AT_CRAM_SECRET) {
      await keyStore.put(AT_CRAM_SECRET_DELETED, AtData()..data = 'true');
    }
    final enrollApprovalId =
        (atConnection.getMetaData() as InboundConnectionMetadata).enrollmentId;
    bool isAuthorized = true; // for legacy clients allow access by default
    if (enrollApprovalId != null) {
      isAuthorized = await super.isAuthorized(enrollApprovalId, keyNamespace);
    }
    if (!isAuthorized) {
      throw UnAuthorizedException(
          'Enrollment Id: $enrollApprovalId is not authorized for delete operation on the key: $deleteKey');
    }
    try {
      var result = await keyStore.remove(deleteKey);
      response.data = result?.toString();
      logger.finer('delete success. delete key: $deleteKey');
    } on KeyNotFoundException {
      logger.warning('key $deleteKey does not exist in keystore');
      rethrow;
    }
    try {
      if (!deleteKey.startsWith('@')) {
        return;
      }
      var forAtSign = verbParams[FOR_AT_SIGN];
      var key = verbParams[AT_KEY];
      var atSign = verbParams[AT_SIGN];
      forAtSign = AtUtils.formatAtSign(forAtSign);
      atSign = AtUtils.formatAtSign(atSign);

      // send notification to other secondary if [AtSecondaryConfig.autoNotify] is true
      if (_autoNotify && (forAtSign != atSign)) {
        try {
          _notify(forAtSign, atSign, key,
              SecondaryUtil.getNotificationPriority(verbParams[PRIORITY]));
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
    key = '$forAtSign:$key$atSign';
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

  Set<String> _getProtectedKeys(String? atsign) {
    atsign ??= AtSecondaryServerImpl.getInstance().currentAtSign;
    Set<String> protectedKeys = {};
    // fetch all protected private keys from config yaml
    for (var key in AtSecondaryConfig.protectedKeys) {
      // protected keys are stored as 'signing_publickey<@atsign>'
      // replace <@atsign> with actual atsign during runtime
      protectedKeys.add(key.replaceFirst('<@atsign>', atsign!));
    }
    return protectedKeys;
  }

  bool _isProtectedKey(String key) {
    if (protectedKeys!.contains(key)) {
      logger.severe('Cannot delete key. \'$key\' is a protected key');
      return true;
    }
    return false;
  }
}
