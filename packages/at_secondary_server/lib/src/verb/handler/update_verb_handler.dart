import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/constants/wire_param_names.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

/// Handles `update:`, which writes a value and its metadata to the keystore.
/// Ex: `update:public:email@alice alice@atsign.com`
class UpdateVerbHandler extends AbstractUpdateVerbHandler {
  static Update update = Update();

  UpdateVerbHandler(
    super.keyStore,
    super.statsNotificationService,
    super.notificationManager,
    super.atSign,
  );

  @override
  bool accept(String command) =>
      command.startsWith('update:') && !command.startsWith('update:meta');

  @override
  Verb getVerb() {
    return update;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    UpdateParams updateParams = getUpdateParams(verbParams);

    // Lowercased because the keystore folds keys to lowercase, so two
    // case-variants of one command name the same record and must contend for
    // the same mutex.
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

      // A write of the flat legacy credential that the gate in isAuthorized
      // admitted, which is a CRAM connection installing an atSign's first
      // keypair, is redirected into the `primary` enrollment. The flat key is
      // never written, so none exists on a running server, and nothing is
      // committed for it.
      if (canonicalAtKey(updatePreProcessResult.atKey) ==
          AtConstants.atPkamPublicKey) {
        await AtSecondaryServerImpl.getInstance()
            .enrollmentManager
            .installLegacyKeyIntoPrimary(updatePreProcessResult.atData.data!);
        response.data = '-1';
        return;
      }

      // The :nc flag maps to skipCommit: write no commit entry and purge the
      // key's existing one, so the response is -1.
      var result = await keyStore.put(
        updatePreProcessResult.atKey,
        updatePreProcessResult.atData,
        skipCommit: verbParams[WireParams.noCommit] != null,
        assertedTimestamps: updatePreProcessResult.assertedTimestamps,
      );
      response.data = result?.toString();

      // Queued from the STORED record, after the write; see notifyAfterStore.
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
