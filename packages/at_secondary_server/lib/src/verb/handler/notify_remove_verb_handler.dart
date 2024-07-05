import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class NotifyRemoveVerbHandler extends AbstractVerbHandler {
  static NotifyRemove notifyRemove = NotifyRemove();

  NotifyRemoveVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) => command.startsWith('notify:remove:');

  @override
  Verb getVerb() {
    return notifyRemove;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var id = verbParams[AtConstants.id];
    if (id == null || id.isEmpty) {
      throw IllegalArgumentException('Notification Id cannot be null or empty');
    }
    var atNotification = await AtNotificationKeystore.getInstance().get(id);
    var inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    if (atNotification != null) {
      var atKey = atNotification.notification;
      var isAuthorized =
          await super.isAuthorized(inboundConnectionMetadata, atKey: atKey!);
      if (!isAuthorized) {
        throw UnAuthorizedException(
            'Connection with enrollment ID ${inboundConnectionMetadata.enrollmentId} is not authorized to remove notify key: $atKey');
      }
    }
    await NotificationManager.getInstance().remove(id);
    response.data = 'success';
  }
}
