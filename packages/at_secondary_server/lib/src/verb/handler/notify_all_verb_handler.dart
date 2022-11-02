import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
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
    var forAtSignList = verbParams[FOR_AT_SIGN];
    var atSign = verbParams[AT_SIGN];
    atSign = AtUtils.formatAtSign(atSign);
    var key = verbParams[AT_KEY]!;
    var messageType = SecondaryUtil.getMessageType(verbParams[MESSAGE_TYPE]);
    var operation = SecondaryUtil.getOperationType(verbParams[AT_OPERATION]);
    var value = verbParams[AT_VALUE];

    try {
      ttlMillis = AtMetadataUtil.validateTTL(verbParams[AT_TTL]);
      ttbMillis = AtMetadataUtil.validateTTB(verbParams[AT_TTB]);
      if (verbParams[AT_TTR] != null) {
        ttrMillis = AtMetadataUtil.validateTTR(int.parse(verbParams[AT_TTR]!));
      }
      isCascade = AtMetadataUtil.validateCascadeDelete(
          ttrMillis, AtMetadataUtil.getBoolVerbParams(verbParams[CCD]));
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
              ..notification = key
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
