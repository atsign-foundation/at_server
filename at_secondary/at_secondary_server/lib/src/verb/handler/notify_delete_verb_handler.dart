import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class NotifyDeleteVerbHandler extends AbstractVerbHandler {
  static NotifyDelete notifyDelete = NotifyDelete();

  NotifyDeleteVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  @override
  bool accept(String command) => command.startsWith('notify:delete');

  @override
  Verb getVerb() {
    return notifyDelete;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var id = verbParams[ID];
    if (id == null || id.isEmpty) {
      throw IllegalArgumentException('Notification Id cannot be null or empty');
    }
    await NotificationManager.getInstance().remove(id);
    response.data = 'success';
  }
}
