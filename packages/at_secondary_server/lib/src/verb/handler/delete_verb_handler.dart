import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/wire_param_names.dart';
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

  final NotificationManager notificationManager;

  DeleteVerbHandler(
    super.keyStore,
    super.statsNotificationService,
    this.notificationManager,
  );

  static setAutoNotify(bool newState) {
    _autoNotify = newState;
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
    // NOTE :dAt is the caller-asserted deletion time; with :nc there is no
    // commit entry for it to stamp.
    DateTime? deletedAt;
    if (verbParams[WireParams.deletedAt] != null) {
      deletedAt = DateTime.parse(verbParams[WireParams.deletedAt]!);
    }
    var deleteKey = verbParams[AtConstants.atKey];
    if (verbParams[AtConstants.atKey] != AtConstants.atCramSecret) {
      deleteKey = '$deleteKey$atSign';
    }
    protectedKeys ??= _getProtectedKeys(atSign);
    if (_isProtectedKey(deleteKey!, isCached: verbParams['isCached'])) {
      throw UnAuthorizedException(
          'Cannot delete protected key: \'$deleteKey\'');
    }
    await super.processVerb(response, verbParams, atConnection);
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
    // NOTE the keystore's own fold, not a copy of it: the checks below decide
    // by string equality against this value.
    deleteKey = canonicalAtKey(deleteKey);

    InboundConnectionMetadata inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;

    bool isAuthorized =
        await super.isAuthorized(inboundConnectionMetadata, atKey: deleteKey);

    if (!isAuthorized) {
      throw UnAuthorizedException(
          'Connection with enrollment ID ${inboundConnectionMetadata.enrollmentId}'
          ' is not authorized to delete key: $deleteKey');
    }
    bool cramSecretExisted = false;
    try {
      // NOTE cached data is exempt: another atSign's cached copy may always
      // be deleted.
      if (verbParams['isCached'] != 'true') {
        if (await keyStore.exists(deleteKey)) {
          AtData atData = (await keyStore.get(deleteKey))!;
          if (atData.metaData?.immutable == true) {
            bool force = verbParams[AtConstants.force] == AtConstants.force;
            if (!force) {
              throw IllegalStateException(
                  'Immutable records may not be deleted without the force flag');
            }
          }
        }
      }
      // NOTE read immediately before the removal: removing a key the store
      // does not hold is not an error here.
      cramSecretExisted = deleteKey == AtConstants.atCramSecret &&
          await keyStore.exists(deleteKey);
      var result = await keyStore.remove(deleteKey,
          skipCommit: verbParams[WireParams.noCommit] != null,
          deletedAt: deletedAt);
      response.data = result?.toString();
      logger.finer('delete success. delete key: $deleteKey');
    } on KeyNotFoundException {
      logger.warning('key $deleteKey does not exist in keystore');
      rethrow;
    }

    // NOTE the marker stops the CRAM secret being replanted on a later start,
    // and is written only after the removal has actually succeeded. It is
    // deliberately outside the try above: one guard per operation.
    if (cramSecretExisted) {
      await keyStore.put(
          AtConstants.atCramSecretDeleted, AtData()..data = 'true');
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

      if (_autoNotify && (forAtSign != atSign)) {
        try {
          await _notify(
              forAtSign,
              atSign,
              key,
              SecondaryUtil.getNotificationPriority(
                  verbParams[AtConstants.priority]),
              deletedAt: deletedAt);
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

  Future<void> _notify(forAtSign, atSign, key, priority,
      {DateTime? deletedAt}) async {
    if (forAtSign == null) {
      return;
    }
    key = '$forAtSign:$key$atSign';
    // NOTE a client-asserted :dAt travels as the metadata's updatedAt, and
    // without an assertion no metadata is attached at all.
    var atNotification = (AtNotificationBuilder()
          ..type = NotificationType.sent
          ..fromAtSign = atSign
          ..toAtSign = forAtSign
          ..notification = key
          ..priority = priority
          ..opType = OperationType.delete
          ..atMetaData = deletedAt == null
              ? null
              : (AtMetaData()
                ..updatedAt = deletedAt.toUtcMillisecondsPrecision()))
        .build();
    await notificationManager.notify(atNotification);
  }

  Set<String> _getProtectedKeys(String? atsign) {
    atsign ??= AtSecondaryServerImpl.getInstance().currentAtSign;
    Set<String> protectedKeys = {};
    for (var key in AtSecondaryConfig.protectedKeys) {
      protectedKeys.add(key.replaceFirst('<@atsign>', atsign));
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
