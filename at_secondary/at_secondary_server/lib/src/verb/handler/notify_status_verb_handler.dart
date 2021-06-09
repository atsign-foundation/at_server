import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/src/keystore/secondary_keystore.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_server_spec/src/connection/inbound_connection.dart';
import 'package:at_server_spec/src/verb/verb.dart';

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

    var notificationManager = NotificationManager.getInstance();
    var status = await notificationManager.getStatus(notificationId);
    response.data = status.toString().split('.').last;
  }
}
