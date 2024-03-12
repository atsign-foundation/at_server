import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class NotifyFetchVerbHandler extends AbstractVerbHandler {
  static NotifyFetch notifyFetch = NotifyFetch();

  NotifyFetchVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.notify)}:fetch');

  @override
  Verb getVerb() {
    return notifyFetch;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var notificationId = verbParams['notificationId'];
    var atNotification =
        await AtNotificationKeystore.getInstance().get(notificationId);
    if (atNotification == null) {
      response.data = jsonEncode({
        'id': notificationId,
        'notificationStatus': NotificationStatus.expired.toString()
      });
      return;
    }
    var inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    var atKey = atNotification.notification;
    var isAuthorized =
        await super.isAuthorized(inboundConnectionMetadata, atKey);
    if (!isAuthorized) {
      throw UnAuthorizedException(
          'Connection with enrollment ID ${inboundConnectionMetadata.enrollmentId} is not authorized to fetch notify key: $atKey');
    }
    response.data = _getJsonEncodedString(atNotification);
  }

  String _getJsonEncodedString(AtNotification atNotification) {
    var atNotificationJson = atNotification.toJson();
    if (atNotificationJson['atMetadata'] != null) {
      atNotificationJson['atMetadata'] =
          SecondaryUtil.removeNulls(atNotification.atMetadata!.toJson());
    }
    for (MapEntry entry in atNotificationJson.entries) {
      if (entry.value is! String) {
        atNotificationJson[entry.key] = entry.value.toString();
      }
    }
    return jsonEncode(atNotificationJson);
  }
}
