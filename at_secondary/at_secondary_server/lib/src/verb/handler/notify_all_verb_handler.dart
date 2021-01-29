import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/src/keystore/secondary_keystore.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_server_spec/src/connection/inbound_connection.dart';
import 'package:at_server_spec/src/verb/notify_all.dart';
import 'package:at_server_spec/src/verb/verb.dart';
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
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {
    InboundConnectionMetadata atConnectionMetadata = atConnection.getMetaData();
    var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    var fromAtSign = atConnectionMetadata.fromAtSign;
    var ttl_ms;
    var ttb_ms;
    var ttr_ms;
    var isCascade;
    var forAtSignList = verbParams[FOR_AT_SIGN];
    var atSign = verbParams[AT_SIGN];
    atSign = AtUtils.formatAtSign(atSign);
    var key = verbParams[AT_KEY];
    var messageType = SecondaryUtil().getMessageType(verbParams[MESSAGE_TYPE]);
    var operation = SecondaryUtil().getOperationType(verbParams[AT_OPERATION]);
    var value = verbParams[AT_VALUE];

    try {
      ttl_ms = AtMetadataUtil.validateTTL(verbParams[AT_TTL]);
      ttb_ms = AtMetadataUtil.validateTTB(verbParams[AT_TTB]);
      if (verbParams[AT_TTR] != null) {
        ttr_ms = AtMetadataUtil.validateTTR(int.parse(verbParams[AT_TTR]));
      }
      isCascade = AtMetadataUtil.validateCascadeDelete(
          ttr_ms, AtMetadataUtil.getBoolVerbParams(verbParams[CCD]));
    } on InvalidSyntaxException {
      rethrow;
    }

    var resultMap = Map<String, String>();
    var dataSignature = SecondaryUtil.signChallenge(
        key, AtSecondaryServerImpl.getInstance().signingKey);
    if (forAtSignList != null && forAtSignList.isNotEmpty) {
      var forAtSigns = forAtSignList.split(',');
      var forAtSignsSet = forAtSigns.toSet();
      for (var forAtSign in forAtSignsSet) {
        var updated_key = '${forAtSign}:${key}';
        var atMetadata = AtMetaData()
          ..ttl = ttl_ms
          ..ttb = ttb_ms
          ..ttr = ttr_ms
          ..isCascade = isCascade
          ..dataSignature = dataSignature;
        var atNotification = (AtNotificationBuilder()
              ..type = NotificationType.sent
              ..fromAtSign = atSign
              ..toAtSign = forAtSign
              ..notification = updated_key
              ..opType = operation
              ..messageType = messageType
              ..atMetaData = atMetadata
              ..atValue = value)
            .build();

        var notificationID =
            await NotificationManager.getInstance().notify(atNotification);
        resultMap[forAtSign] = notificationID;
      }
    }
    response.data = json.encode(resultMap);
  }
}
