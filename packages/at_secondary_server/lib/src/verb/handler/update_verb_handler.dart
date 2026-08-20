import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/constants/wire_param_names.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

// UpdateVerbHandler is used to process update verb
// update can be used to update the public/private keys
// Ex: update:public:email@alice alice@atsign.com \n
class UpdateVerbHandler extends AbstractUpdateVerbHandler {
  static Update update = Update();

  UpdateVerbHandler(
    super.keyStore,
    super.statsNotificationService,
    super.notificationManager,
    super.atSign,
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

    // Lowercased: the keystore canonicalizes keys to lowercase, so two
    // case-variants of one command name the same stored record and must
    // contend for the same mutex.
    String dataStoreKey = getDataStoreKey(updateParams).toLowerCase();

    final mutexRef = updateMutexes.putIfAbsent(dataStoreKey, MutexRef.new);

    try {
      mutexRef.waiters++;
      if (logger.isLoggable('finest')) {
        logger.finest(
            'Acquiring mutex for $dataStoreKey - ${mutexRef.waiters} waiting (including me)');
      }
      await mutexRef.mutex.acquire();

      var updatePreProcessResult = await super.preProcess(
        response,
        verbParams,
        updateParams,
        atConnection,
      );

      // update the key in data store. The :nc flag maps to skipCommit
      // (write no commit entry AND purge the key's existing one, so the
      // response is -1); asserted timestamps are stored faithfully.
      var result = await keyStore.put(
        updatePreProcessResult.atKey,
        updatePreProcessResult.atData,
        skipCommit: verbParams[WireParams.noCommit] != null,
        assertedTimestamps: assertedTimestampsOf(updateParams.metadata!),
      );
      response.data = result?.toString();

      // Queue the auto-notification from the STORED record, after the
      // write — see notifyAfterStore.
      await super.notifyAfterStore(verbParams, updateParams,
          updatePreProcessResult);
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
