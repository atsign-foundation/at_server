import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';

import '../verb_enum.dart';
import 'abstract_verb_handler.dart';
import 'notify_verb_handler.dart';

/// class to handle notify:list verb
class NotifyAllVerbHandler extends AbstractVerbHandler {
  static NotifyAll notifyAll = NotifyAll();

  final NotificationManager notificationManager;

  NotifyAllVerbHandler(
    super.keyStore,
    this.notificationManager,
  );

  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.notify)}:all');

  @override
  Verb getVerb() {
    return notifyAll;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    int ttlMillis;
    int ttbMillis;
    int? ttrMillis;
    bool? isCascade;
    final currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    final atSign =
        AtUtils.fixAtSign(verbParams[AtConstants.atSign] ?? currentAtSign);
    if (atSign != currentAtSign) {
      throw UnAuthorizedException(
          '$atSign is not authorized to send notification as $currentAtSign');
    }
    var messageType =
        SecondaryUtil.getMessageType(verbParams[AtConstants.messageType]);
    if (messageType == MessageType.text) {
      throw InvalidSyntaxException(NotifyVerbHandler.textNotSupported);
    }
    var operation =
        SecondaryUtil.getOperationType(verbParams[AtConstants.operation]);
    var value = verbParams[AtConstants.atValue];
    var key = '${verbParams[AtConstants.atKey]!}$atSign';

    final recipients = _recipients(verbParams[AtConstants.forAtSign]);
    final inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    // NOTE each recipient's key is judged whole, as notify judges it, and
    // every one before any is stored, so a refusal stores nothing.
    for (final forAtSign in recipients) {
      final recipientKey = '$forAtSign:$key';
      if (!await isAuthorized(inboundConnectionMetadata, atKey: recipientKey)) {
        throw UnAuthorizedException(
            'Connection with enrollment ID ${inboundConnectionMetadata.enrollmentId}'
            ' is not authorized to notify key: $recipientKey');
      }
    }

    try {
      ttlMillis = AtMetadataUtil.validateTTL(verbParams[AtConstants.ttl]);
      ttbMillis = AtMetadataUtil.validateTTB(verbParams[AtConstants.ttb]);
      if (verbParams[AtConstants.ttr] != null) {
        ttrMillis =
            AtMetadataUtil.validateTTR(int.parse(verbParams[AtConstants.ttr]!));
      }
      isCascade = AtMetadataUtil.validateCascadeDelete(ttrMillis,
          AtMetadataUtil.getBoolVerbParams(verbParams[AtConstants.ccd]));
    } on InvalidSyntaxException {
      rethrow;
    }

    var resultMap = <String, String?>{};
    var dataSignature = SecondaryUtil.signChallenge(
        key, AtSecondaryServerImpl.getInstance().signingKey);
    for (final forAtSign in recipients) {
      final isSelf = forAtSign == currentAtSign;
      var updatedKey = '$forAtSign:$key';
      var atMetadata = AtMetaData()
        ..ttl = ttlMillis
        ..ttb = ttbMillis
        ..ttr = ttrMillis
        ..isCascade = isCascade
        ..dataSignature = dataSignature;
      var atNotification = (AtNotificationBuilder()
            ..type = isSelf ? NotificationType.received : NotificationType.sent
            ..notificationStatus = isSelf
                ? NotificationStatus.delivered
                : NotificationStatus.queued
            ..fromAtSign = currentAtSign
            ..toAtSign = forAtSign
            ..notification = updatedKey
            ..notificationDateTime = DateTime.now().toUtcMillisecondsPrecision()
            ..opType = operation
            ..messageType = messageType
            ..atValue = value
            ..atMetaData = atMetadata)
          .build();

      await notificationManager.notify(atNotification);
      resultMap[forAtSign] = atNotification.id;
    }
    response.data = json.encode(resultMap);
  }

  /// The atSigns [forAtSignList] names, each normalised and named once, in
  /// the order first named. Empty tokens name nobody.
  static Set<String> _recipients(String? forAtSignList) => {
        for (final token in (forAtSignList ?? '')
            .replaceAll('[', '')
            .replaceAll(']', '')
            .split(','))
          if (token.isNotEmpty) AtUtils.fixAtSign(token)
      };
}
