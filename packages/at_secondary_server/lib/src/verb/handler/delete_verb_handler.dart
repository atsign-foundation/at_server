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

  // Sets autoNotify from `config:set`, which the server subscribes to at
  // startup. `config:set` needs a connection authorised for the __config
  // namespace; it is not gated on the server's testing mode.
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
    // :dAt is the caller-asserted deletion time, pinned by the verb grammar
    // to ISO 8601 UTC. It becomes the DELETE commit entry's opTime and
    // travels to the sharedWith atServer on the auto-notification, so the
    // receiver's cached-key delete records the origin deletion time. With :nc
    // there is no commit entry for it to stamp.
    DateTime? deletedAt;
    if (verbParams[WireParams.deletedAt] != null) {
      deletedAt = DateTime.parse(verbParams[WireParams.deletedAt]!);
    }
    var deleteKey = verbParams[AtConstants.atKey];
    // The CRAM secret's key carries no atSign.
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
    // The keystore's own fold, not a copy of it: the CRAM-secret comparison
    // below and the authorisation check both decide by string equality
    // against this value, so a fold that drifted from the store's would
    // answer about a key the store does not hold.
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
      // An immutable record needs the force flag. Cached data is exempt:
      // deleting another atSign's cached copy is always allowed.
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
      // Read immediately before the removal, because removing a key the store
      // does not hold is not an error here, and the CRAM tombstone below must
      // record a deletion that happened rather than one that was commanded.
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

    // The CRAM secret is the registrar's activation credential, and this
    // marker stops it being replanted on a later start (see
    // [AtSecondaryServerImpl.plantCramSecretIfRequired]). Written HERE,
    // after the authorisation check and after the removal actually succeeded,
    // because CRAM is an atSign's last recovery route once its roots are
    // revoked: a caller that cannot delete the secret must not be able to
    // close that route, and neither may a command that deleted nothing.
    //
    // Deliberately NOT inside the try above: one guard per operation, so a
    // failure writing the marker cannot be mistaken for the removal not
    // having happened. A crash between the two durable writes leaves the
    // secret gone with no marker, and a restart with `-s` replants. That is
    // the safer ordering; the opposite one bars replanting after a delete
    // that never completed.
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

      // Auto-notify the sharedWith atSign, unless autoNotify is off.
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
    // A client-asserted :dAt travels as the metadata's updatedAt, emitted on
    // the wire as :uAt: (the notify grammar has no dAt group, and a deletion
    // is the record's last update). Without an assertion no metadata is
    // attached at all, so an ordinary delete notification keeps the wire
    // shape a receiver predating the timestamp syntax can parse.
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
    // config.yaml spells these as 'signing_publickey<@atsign>'.
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
