import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_secondary/src/verb/handler/sync_handler_helpers.dart';

class SyncProgressiveVerbHandler extends AbstractVerbHandler {
  static SyncFrom syncFrom = SyncFrom();

  SyncProgressiveVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith(getName(VerbEnum.sync) + ':') &&
      command.startsWith('sync:from');

  @override
  Verb getVerb() {
    return syncFrom;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var syncResponse = [];
    var syncBuffer = ByteBuffer(capacity: AtSecondaryConfig.syncBufferSize);
    // Get Commit Log Instance.
    var atCommitLog = await (AtCommitLogManagerImpl.getInstance()
        .getCommitLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    // Get entries to sync
    var itr = atCommitLog!.getEntries(
        int.parse(verbParams[AT_FROM_COMMIT_SEQUENCE]!) + 1,
        regex: verbParams['regex']);
    // Iterates on all the elements in iterator
    // Loop breaks when the [syncBuffer] reaches the limit.
    // and when syncResponse length equals the [AtSecondaryConfig.syncPageLimit]
    int syncPageLimit = AtSecondaryConfig.syncPageLimit;
    while (itr.moveNext() &&
        syncResponse.length < syncPageLimit) {
      var keyStoreEntry = KeyStoreEntry();
      keyStoreEntry.atKey = itr.current.key;
      keyStoreEntry.commitId = itr.current.value.commitId;
      keyStoreEntry.operation = itr.current.value.operation;
      if (itr.current.value.operation != CommitOp.DELETE) {
        // If commitOperation is update (or) update_all (or) update_meta and key does not
        // exist in keystore, skip the key to sync and continue.
        if (!keyStore!.isKeyExists(itr.current.key)) {
          logger.finer(
              '${itr.current.key} does not exist in the keystore. skipping the key to sync');
          continue;
        }
        var atData = await keyStore!.get(itr.current.key);
        if (atData == null) {
          logger.info('atData is null for ${itr.current.key}');
          continue;
        }
        keyStoreEntry.value = atData.data;
        keyStoreEntry.atMetaData = populateMetadata(atData);
      }
      // If syncBuffer reaches the limit, break the loop.
      if (syncBuffer.isOverFlow(utf8.encode(jsonEncode(keyStoreEntry)))) {
        break;
      }
      syncBuffer.append(utf8.encode(jsonEncode(keyStoreEntry)));
      syncResponse.add(keyStoreEntry);
    }
    //Clearing the buffer data
    syncBuffer.clear();
    response.data = jsonEncode(syncResponse);
  }

  void logResponse(String response) {
    try {
      var parsedResponse = '';
      final responseJson = jsonDecode(response);
      for (var syncRecord in responseJson) {
        final newRecord = {};
        newRecord['atKey'] = syncRecord['atKey'];
        newRecord['operation'] = syncRecord['operation'];
        newRecord['commitId'] = syncRecord['commitId'];
        newRecord['metadata'] = syncRecord['metadata'];
        parsedResponse += newRecord.toString();
      }
      logger.finer('progressive sync response: $parsedResponse');
    } on Exception catch (e, trace) {
      logger.severe(
          'exception logging progressive sync response: ${e.toString()}');
      logger.severe(trace);
    }
  }
}
