import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:mutex/mutex.dart';

// UpdateVerbHandler is used to process update verb
// update can be used to update the public/private keys
// Ex: update:public:email@alice alice@atsign.com \n
class UpdateVerbHandler extends AbstractUpdateVerbHandler {
  static Update update = Update();

  UpdateVerbHandler(
    super.keyStore,
    super.statsNotificationService,
    super.notificationManager,
  );

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
    UpdateParams updateParams = getUpdateParams(verbParams);

    String dataStoreKey = getDataStoreKey(updateParams);

    updateMutexes.putIfAbsent(dataStoreKey, () => (Mutex(), 0));

    try {
      var mutexRecord = updateMutexes[dataStoreKey]!;
      updateMutexes[dataStoreKey] = (mutexRecord.$1, mutexRecord.$2 +1);
      logger.finest('Acquiring mutex for $dataStoreKey - ${mutexRecord.$2 +1} waiting (including me)');
      await mutexRecord.$1.acquire();

      var updatePreProcessResult = await super.preProcessAndNotify(
        response,
        verbParams,
        updateParams,
        atConnection,
      );

      // update the key in data store
      var result = await keyStore.put(
        updatePreProcessResult.atKey,
        updatePreProcessResult.atData,
      );
      response.data = result?.toString();
    } finally {
      String logMsg = 'Releasing mutex on $dataStoreKey';
      var mutexRecord = updateMutexes[dataStoreKey]!;
      mutexRecord.$1.release();
      updateMutexes[dataStoreKey] = (mutexRecord.$1, mutexRecord.$2 -1);
      if (updateMutexes[dataStoreKey]!.$2 == 0) {
        logger.finest('$logMsg : 0 now waiting for mutex on $dataStoreKey - removing mutex');
        updateMutexes.remove(dataStoreKey);
      } else {
        logger.finest('$logMsg : ${updateMutexes[dataStoreKey]!.$2} still waiting for mutex on $dataStoreKey');
      }
    }
  }
}
