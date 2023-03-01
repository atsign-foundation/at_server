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
import 'package:meta/meta.dart';

class SyncProgressiveVerbHandler extends AbstractVerbHandler {
  static SyncFrom syncFrom = SyncFrom();

  SyncProgressiveVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  /// Represents the size of the sync buffer
  @visibleForTesting
  int capacity = AtSecondaryConfig.syncBufferSize;

  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.sync)}:') &&
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
    var syncBuffer = ByteBuffer(capacity: capacity);
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
    while (itr.moveNext() &&
        syncResponse.length < AtSecondaryConfig.syncPageLimit) {
      var keyStoreEntry = KeyStoreEntry();
      keyStoreEntry.key = itr.current.key;
      keyStoreEntry.commitId = itr.current.value.commitId;
      keyStoreEntry.operation = itr.current.value.operation;
      if (itr.current.value.operation != CommitOp.DELETE) {
        // If commitOperation is update (or) update_all (or) update_meta and key does not
        // exist in keystore, skip the key to sync and continue.
        if (!keyStore.isKeyExists(itr.current.key)) {
          logger.finer(
              '${itr.current.key} does not exist in the keystore. skipping the key to sync');
          continue;
        }
        var atData = await keyStore.get(itr.current.key);
        if (atData == null) {
          logger.info('atData is null for ${itr.current.key}');
          continue;
        }
        keyStoreEntry.value = atData.data;
        keyStoreEntry.atMetaData = _populateMetadata(atData);
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

  Map _populateMetadata(value) {
    var metaDataMap = <String, dynamic>{};
    AtMetaData? metaData = value?.metaData;
    if (metaData == null) {
      return metaDataMap;
    }
    metaData.toJson().forEach((key, value) {
      if (value != null) {
        metaDataMap[key] = value.toString();
      }
    });
    return metaDataMap;
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

/// Class to represents the sync entry.
class KeyStoreEntry {
  late String key;
  String? value;
  Map? atMetaData;
  late int commitId;
  late CommitOp operation;

  @override
  String toString() {
    return 'atKey: $key, value: $value, metadata: $atMetaData, commitId: $commitId, operation: $operation';
  }

  Map toJson() {
    var map = {};
    map['atKey'] = key;
    map['value'] = value;
    map['metadata'] = atMetaData;
    map['commitId'] = commitId;
    map['operation'] = operation.name;
    return map;
  }

  KeyStoreEntry fromJson(Map json) {
    key = json['atKey'];
    value = json['value'];
    atMetaData = json['metadata'];
    commitId = json['commitId'];
    operation = json['operation'];
    return this;
  }
}
