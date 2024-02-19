import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

// UpdateVerbHandler is used to process update verb
// update can be used to update the public/private keys
// Ex: update:public:email@alice alice@atsign.com \n
class UpdateVerbHandler extends AbstractUpdateVerbHandler {
  static Update update = Update();

  UpdateVerbHandler(SecondaryKeyStore keyStore,
      StatsNotificationService statsNotificationService, notificationManager)
      : super(keyStore, statsNotificationService, notificationManager);

  // Method to verify whether command is accepted or not
  // Input: command
  @override
  bool accept(String command) =>
      command.startsWith('update:') && !command.startsWith('update:meta');

  // Method to return Instance of verb belongs to this VerbHandler
  @override
  Verb getVerb() {
    return update;
  }

  // Method which will process update Verb
  // This will process given verb and write response to response object
  // Input : Response, verbParams, AtConnection
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var updatePreProcessResult =
        await super.preProcessAndNotify(response, verbParams, atConnection);

    logger.finer(
        'calling keyStore.put(${updatePreProcessResult.atKey}, ${updatePreProcessResult.atData}');

    try {
      // update the key in data store
      var result = await keyStore.put(
          updatePreProcessResult.atKey, updatePreProcessResult.atData,
          metadata:
              updatePreProcessResult.atData.metaData!.toCommonsMetadata());

      response.data = result?.toString();
    } catch (e, st) {
      logger.warning('$e\n$st');
    }
  }
}
