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

  //setter to set autoNotify value from dynamic server config "config:set".
  //only works when testingMode is set to true
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
    // :dAt — the caller-asserted deletion time. Recorded as the DELETE
    // commit entry's opTime, and carried to the sharedWith atServer on the
    // auto-notification (as :uAt: — the notify grammar has no dAt group)
    // so the receiver's cached-key delete records the origin deletion
    // time. With :nc there is no commit entry, so it has nothing to stamp
    // locally. The verb grammar pins the value to ISO 8601 UTC.
    DateTime? deletedAt;
    if (verbParams[WireParams.deletedAt] != null) {
      deletedAt = DateTime.parse(verbParams[WireParams.deletedAt]!);
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
    // The keystore's own fold, not a copy of it: the CRAM-secret comparison
    // just below and the authorisation check that follows both decide by
    // string equality against this value, so a fold that drifted from the
    // store's would answer about a key the store does not hold.
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
      // if this is not cached (because we should always be allowed to delete
      // cached data from other atSigns)
      // and the data exists
      // then check if the data is immutable
      // and if so, prevent deletion unless the "force" flag was set
      if (verbParams['isCached'] != 'true') {
        if (await keyStore.exists(deleteKey)) {
          AtData atData = (await keyStore.get(deleteKey))!;
          if (atData.metaData?.immutable == true) {
            // immutable records need the force flag in order to be deleted
            bool force = verbParams[AtConstants.force] == AtConstants.force;
            if (!force) {
              throw IllegalStateException(
                  'Immutable records may not be deleted without the force flag');
            }
          }
        }
      }
      // Read immediately before the removal, because removing a key the
      // store does not hold is not an error here — it succeeds with a
      // commit id of -1 — and the CRAM tombstone below must record a
      // deletion that happened rather than a command that was sent.
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
    // marker is what stops it being replanted on a later start (see
    // [AtSecondaryServerImpl.plantCramSecretIfRequired]). It is written HERE
    // — after the authorisation check above, and after the removal actually
    // succeeded — because it records a deletion that happened rather than
    // one that was merely attempted.
    //
    // Written earlier, it was reachable by any connection that got as far as
    // this handler: an enrollment holding nothing but an ordinary namespace
    // was refused the delete and still permanently disabled CRAM, on an
    // atSign that need never have had a secret at all. Once the flat PKAM
    // credential is retired, CRAM is the last recovery route an atSign has,
    // so a caller who cannot delete the secret must not be able to close
    // that route either — nor may a command that deleted nothing.
    //
    // Deliberately NOT inside the try above: one guard per operation, so a
    // failure writing the marker cannot be mistaken for the removal not
    // having happened. The two are separate durable writes, and a crash
    // between them leaves the secret gone with no marker — a restart with
    // `-s` would then replant. That is the safer of the two orderings: the
    // opposite one loses the secret's replant permanently on a delete that
    // never completed.
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

      // send notification to other secondary if [AtSecondaryConfig.autoNotify] is true
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
    // A client-asserted :dAt travels as the metadata's updatedAt, emitted
    // on the wire as :uAt: (the notify grammar has no dAt group — a
    // deletion is the record's last update). Without an assertion, no
    // metadata is attached at all, keeping an ordinary delete
    // notification's wire shape exactly what it always was — a receiver
    // built before the timestamp syntax existed still parses it.
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
    // fetch all protected private keys from config yaml
    for (var key in AtSecondaryConfig.protectedKeys) {
      // protected keys are stored as 'signing_publickey<@atsign>'
      // replace <@atsign> with actual atsign during runtime
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
