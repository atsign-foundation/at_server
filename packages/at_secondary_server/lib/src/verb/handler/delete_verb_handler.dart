import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
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

  DeleteVerbHandler(super.keyStore, super.statsNotificationService);

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
    String atSign = '';
    if (verbParams[AtConstants.atSign] != null) {
      atSign = AtUtils.fixAtSign(verbParams[AtConstants.atSign]!);
    }
    var deleteKey = verbParams[AtConstants.atKey];
    // If key is cram secret do not append atsign.
    if (verbParams[AtConstants.atKey] != AtConstants.atCramSecret) {
      deleteKey = '$deleteKey$atSign';
    }
    // fetch protected keys listed in config.yaml
    protectedKeys ??= _getProtectedKeys(atSign);
    // check to see if a key is protected. Cannot delete key if it's protected
    if (_isProtectedKey(deleteKey!, isCached: verbParams['isCached'])) {
      throw UnAuthorizedException(
          'Cannot delete protected key: \'$deleteKey\'');
    }
    // Sets Response bean to the response bean in ChangeVerbHandler
    await super.processVerb(response, verbParams, atConnection);
    // var keyNamespace = verbParams[AtConstants.atKey]!
    //     .substring(deleteKey.lastIndexOf('.') + 1);
    if (verbParams[AtConstants.forAtSign] != null) {
      deleteKey =
          '${AtUtils.fixAtSign(verbParams[AtConstants.forAtSign]!)}:$deleteKey';
    }
    if (verbParams['isPublic'] == 'true') {
      deleteKey = 'public:$deleteKey';
    }
    if (verbParams['isCached'] == 'true') {
      deleteKey = 'cached:$deleteKey';
    }
    assert(deleteKey.isNotEmpty);
    deleteKey = deleteKey.trim().toLowerCase().replaceAll(' ', '');
    if (deleteKey == AtConstants.atCramSecret) {
      await keyStore.put(
          AtConstants.atCramSecretDeleted, AtData()..data = 'true');
    }

    InboundConnectionMetadata inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;

    bool isAuthorized =
        await super.isAuthorized(inboundConnectionMetadata, atKey: deleteKey);

    if (!isAuthorized) {
      throw UnAuthorizedException(
          'Connection with enrollment ID ${inboundConnectionMetadata.enrollmentId}'
          ' is not authorized to delete key: $deleteKey');
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
      var forAtSign = verbParams[AtConstants.forAtSign];
      var key = verbParams[AtConstants.atKey];
      var atSign = verbParams[AtConstants.atSign];
      if (forAtSign.isNotNullOrEmpty) {
        forAtSign = AtUtils.fixAtSign(forAtSign!);
      }
      if (atSign.isNotNullOrEmpty) {
        atSign = AtUtils.fixAtSign(atSign!);
      }

      // send notification to other secondary if [AtSecondaryConfig.autoNotify] is true
      if (_autoNotify && (forAtSign != atSign)) {
        try {
          _notify(
              forAtSign,
              atSign,
              key,
              SecondaryUtil.getNotificationPriority(
                  verbParams[AtConstants.priority]));
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

  bool _isProtectedKey(String key, {String? isCached}) {
    isCached ??= 'false';
    if (protectedKeys!.contains(key) && isCached == 'false') {
      logger.severe('Cannot delete key. \'$key\' is a protected key');
      return true;
    }
    return false;
  }
}
