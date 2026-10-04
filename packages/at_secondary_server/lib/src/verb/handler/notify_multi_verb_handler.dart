import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';

/// Handles `notify:multi`, which notifies several atSigns of one key with one
/// value and the metadata each recipient needs to read it.
class NotifyMultiVerbHandler extends AbstractVerbHandler {
  static NotifyMulti notifyMulti = NotifyMulti();

  /// Fields `notify:multi` refuses: those describing one recipient's copy of
  /// a value, which no single value can be right for; those the atServer does
  /// not deliver to a recipient; and `ttr` and `ccd`, which would make each
  /// recipient keep a cached copy.
  static const refusedFields = [
    AtConstants.ttr,
    AtConstants.ccd,
    AtConstants.sharedKeyEncrypted,
    AtConstants.sharedWithPublicKeyCheckSum,
    AtConstants.sharedWithPublicKeyHash,
    AtConstants.sharedWithPublicKeyHashingAlgo,
    AtConstants.sharedKeyEncryptedEncryptingKeyName,
    AtConstants.sharedKeyEncryptedEncryptingAlgo,
    AtConstants.isBinary,
    AtConstants.encoding,
    AtConstants.sharedKeyStatus,
    AtConstants.publicDataSignature,
  ];

  final NotificationManager notificationManager;

  NotifyMultiVerbHandler(super.keyStore, this.notificationManager);

  @override
  bool accept(String command) => command.startsWith('notify:multi:');

  @override
  Verb getVerb() => notifyMulti;

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    for (final field in refusedFields) {
      if (verbParams[field] != null) {
        throw InvalidSyntaxException('notify:multi does not take $field');
      }
    }
    NotifyVerbHandler.refuseConflictingLifetime(verbParams);
    final currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    final atSign = AtUtils.fixAtSign(verbParams[AtConstants.atSign]!);
    if (atSign != currentAtSign) {
      throw UnAuthorizedException(
          '$atSign is not authorized to send notification as $currentAtSign');
    }
    final key = '${verbParams[AtConstants.atKey]}$atSign';
    final connectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    if (!await isAuthorized(connectionMetadata, atKey: key)) {
      throw UnAuthorizedException(
          'Connection with enrollment ID ${connectionMetadata.enrollmentId}'
          ' is not authorized to notify key: $key');
    }
    final operation =
        SecondaryUtil.getOperationType(verbParams[AtConstants.operation]);
    final ttlnMillis = NotifyVerbHandler.getNotificationExpiryInMillis(
        verbParams[AtConstants.ttlNotification]);
    final ephemeral = NotifyVerbHandler.isEphemeral(verbParams);
    final explicitExpiry =
        verbParams[AtConstants.notificationExpiresAt] != null;
    final createdAt = DateTime.now().toUtcMillisecondsPrecision();
    final expiresAt = NotifyVerbHandler.setsOwnExpiry(verbParams)
        ? NotifyVerbHandler.notificationExpiresAt(verbParams, createdAt)
        : null;

    final result = <String, String>{};
    for (final forAtSign in _recipients(verbParams[AtConstants.forAtSign]!)) {
      final isSelf = forAtSign == currentAtSign;
      final atNotification = (AtNotificationBuilder()
            ..type = isSelf ? NotificationType.received : NotificationType.sent
            ..notificationStatus = isSelf
                ? NotificationStatus.delivered
                : NotificationStatus.queued
            ..fromAtSign = currentAtSign
            ..toAtSign = forAtSign
            ..notification = '$forAtSign:$key'
            ..notificationDateTime = createdAt
            ..opType = operation
            ..messageType = MessageType.key
            ..atValue = verbParams[AtConstants.atValue]
            ..atMetaData = NotifyVerbHandler.metadataFromParams(verbParams)
            ..ttl = ttlnMillis
            ..expiresAt = expiresAt)
          .build();
      result[forAtSign] = atNotification.id!;
      // NOTE an expiry already past is accepted, and the copy dropped.
      if (!atNotification.isExpired()) {
        await notificationManager.notify(atNotification,
            ephemeral: ephemeral, explicitExpiry: explicitExpiry);
      }
    }
    response.data = json.encode(result);
  }

  /// The atSigns [forAtSignList] names, each normalised and named once, in
  /// the order first named.
  static Set<String> _recipients(String forAtSignList) =>
      {for (final token in forAtSignList.split(',')) AtUtils.fixAtSign(token)};
}
