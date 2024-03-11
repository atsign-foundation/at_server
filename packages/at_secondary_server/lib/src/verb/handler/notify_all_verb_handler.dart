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

/// class to handle notify:list verb
class NotifyAllVerbHandler extends AbstractVerbHandler {
  static NotifyAll notifyAll = NotifyAll();

  NotifyAllVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

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
    var forAtSignList = verbParams[AtConstants.forAtSign];
    var atSign = verbParams[AtConstants.atSign];
    if (atSign.isNotNullOrEmpty) {
      atSign = AtUtils.fixAtSign(atSign!);
    }
    var key = verbParams[AtConstants.atKey]!;
    var inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    var isAuthorized =
        await super.isAuthorized(inboundConnectionMetadata, '$key$atSign');
    if (!isAuthorized) {
      throw UnAuthorizedException(
          'Connection with enrollment ID ${inboundConnectionMetadata.enrollmentId}'
          ' is not authorized to notify key: $key$atSign');
    }
    var messageType =
        SecondaryUtil.getMessageType(verbParams[AtConstants.messageType]);
    var operation =
        SecondaryUtil.getOperationType(verbParams[AtConstants.operation]);
    var value = verbParams[AtConstants.atValue];

    // If messageType is key, append the atSign to key. For messageType text,
    // atSign is not appended to the key.
    if (messageType == MessageType.key) {
      key = '$key$atSign';
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
    if (forAtSignList != null && forAtSignList.isNotEmpty) {
      var forAtSigns = forAtSignList.split(',');
      var forAtSignsSet = forAtSigns.toSet();
      for (var forAtSign in forAtSignsSet) {
        var updatedKey = '$forAtSign:$key';
        var atMetadata = AtMetaData()
          ..ttl = ttlMillis
          ..ttb = ttbMillis
          ..ttr = ttrMillis
          ..isCascade = isCascade
          ..dataSignature = dataSignature;
        var atNotification = (AtNotificationBuilder()
              ..type = NotificationType.sent
              ..fromAtSign = atSign
              ..toAtSign = forAtSign
              ..notification = updatedKey
              ..opType = operation
              ..messageType = messageType
              ..atValue = value
              ..atMetaData = atMetadata)
            .build();

        var notificationID =
            await NotificationManager.getInstance().notify(atNotification);
        resultMap[forAtSign] = notificationID;
      }
    }
    response.data = json.encode(resultMap);
  }
}
