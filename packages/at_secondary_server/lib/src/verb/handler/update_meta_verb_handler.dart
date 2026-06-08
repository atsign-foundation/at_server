import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';

class UpdateMetaVerbHandler extends AbstractUpdateVerbHandler {
  static UpdateMeta updateMeta = UpdateMeta();

  UpdateMetaVerbHandler(
    super.keyStore,
    super.statsNotificationService,
    super.notificationManager,
    super.atSign,
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

    final mutexRef = updateMutexes.putIfAbsent(dataStoreKey, MutexRef.new);

    try {
      mutexRef.waiters++;
      if (logger.isLoggable('finest')) {
        logger.finest(
            'Acquiring mutex for $dataStoreKey - ${mutexRef.waiters} waiting (including me)');
      }
      await mutexRef.mutex.acquire();

      var updatePreProcessResult = await super.preProcessAndNotify(
        response,
        verbParams,
        updateParams,
        atConnection,
      );

      // update the key in data store
      logger.finer(
          'calling keyValueStore.putMeta(${updatePreProcessResult.atKey}, ${updatePreProcessResult.atData.metaData!}');
      var result = await keyStore.putMeta(updatePreProcessResult.atKey,
          updatePreProcessResult.atData.metaData!);
      response.data = result?.toString();
    } finally {
      mutexRef.mutex.release();
      mutexRef.waiters--;
      if (mutexRef.waiters == 0) {
        if (logger.isLoggable('finest')) {
          logger.finest(
              'Releasing mutex on $dataStoreKey : 0 now waiting for mutex on $dataStoreKey - removing mutex');
        }
        updateMutexes.remove(dataStoreKey);
      } else {
        if (logger.isLoggable('finest')) {
          logger.finest(
              'Releasing mutex on $dataStoreKey : ${mutexRef.waiters} still waiting for mutex on $dataStoreKey');
        }
      }
    }
  }
}
