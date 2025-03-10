import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:mutex/mutex.dart';

class UpdateMetaVerbHandler extends AbstractUpdateVerbHandler {
  static UpdateMeta updateMeta = UpdateMeta();

  UpdateMetaVerbHandler(
    super.keyStore,
    super.statsNotificationService,
    super.notificationManager,
  );

  @override
  bool accept(String command) => command.startsWith('update:meta:');

  @override
  Verb getVerb() => updateMeta;

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
      updateMutexes[dataStoreKey] = (mutexRecord.$1, mutexRecord.$2 + 1);
      logger.finest(
          'Acquiring mutex for $dataStoreKey - ${mutexRecord.$2 + 1} waiting (including me)');
      await mutexRecord.$1.acquire();

      var updatePreProcessResult = await super.preProcessAndNotify(
        response,
        verbParams,
        updateParams,
        atConnection,
      );

      // update the key in data store
      logger.finer(
          'calling keyStore.putMeta(${updatePreProcessResult.atKey}, ${updatePreProcessResult.atData.metaData!}');
      var result = await keyStore.putMeta(updatePreProcessResult.atKey,
          updatePreProcessResult.atData.metaData!);
      response.data = result?.toString();
    } finally {
      String logMsg = 'Releasing mutex on $dataStoreKey';
      var mutexRecord = updateMutexes[dataStoreKey]!;
      mutexRecord.$1.release();
      updateMutexes[dataStoreKey] = (mutexRecord.$1, mutexRecord.$2 - 1);
      if (updateMutexes[dataStoreKey]!.$2 == 0) {
        logger.finest(
            '$logMsg : 0 now waiting for mutex on $dataStoreKey - removing mutex');
        updateMutexes.remove(dataStoreKey);
      } else {
        logger.finest(
            '$logMsg : ${updateMutexes[dataStoreKey]!.$2} still waiting for mutex on $dataStoreKey');
      }
    }
  }
}
