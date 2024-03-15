import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_server_spec/at_server_spec.dart';

class NotifyStatusVerbHandler extends AbstractVerbHandler {
  static NotifyStatus notifyStatus = NotifyStatus();

  NotifyStatusVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.notify)}:status');

  @override
  Verb getVerb() {
    return notifyStatus;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var notificationId = verbParams['notificationId'];

    var atNotification =
        await AtNotificationKeystore.getInstance().get(notificationId);
    NotificationStatus? status;
    if (atNotification == null) {
      response.data = null;
      return;
    }
    var inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    var atKey = atNotification.notification;
    var isAuthorized =
        await super.isAuthorized(inboundConnectionMetadata, atKey: atKey!);
    if (!isAuthorized) {
      throw UnAuthorizedException(
          'Connection with enrollment ID ${inboundConnectionMetadata.enrollmentId} is not authorized to fetch notify key: $atKey');
    }
    if (atNotification.isExpired()) {
      status = NotificationStatus.expired;
    } else {
      status = atNotification.notificationStatus;
    }
    response.data = status.toString().split('.').last;
  }
}
