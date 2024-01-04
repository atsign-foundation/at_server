import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
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
    // Get Commit Log Instance.
    var atCommitLog = await (AtCommitLogManagerImpl.getInstance()
        .getCommitLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    // Get entries to sync
    var commitEntryIterator = atCommitLog!.getEntries(
        int.parse(verbParams[AtConstants.fromCommitSequence]!) + 1,
        regex: verbParams['regex']);

    List<KeyStoreEntry> syncResponse = [];
    await prepareResponse(capacity, syncResponse, commitEntryIterator,
        enrollmentId: (atConnection.getMetaData() as InboundConnectionMetadata)
            .enrollmentId);

    response.data = jsonEncode(syncResponse);
  }

  /// Adds items from the [commitEntryIterator] to the [syncResponse] until either
  /// 1. there is at least one item in [syncResponse], and the response length is greater than [desiredMaxSyncResponseLength], or
  /// 2. there are [AtSecondaryConfig.syncPageLimit] items in the [syncResponse]
  @visibleForTesting
  Future<void> prepareResponse(int desiredMaxSyncResponseLength,
      List<KeyStoreEntry> syncResponse, Iterator<dynamic> commitEntryIterator,
      {String? enrollmentId}) async {
    int currentResponseLength = 0;
    Map<String, String> enrolledNamespaces = {};

    if (enrollmentId != null && enrollmentId.isNotEmpty) {
      String enrollmentKey =
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace${AtSecondaryServerImpl.getInstance().currentAtSign}';
      enrolledNamespaces =
          (await getEnrollDataStoreValue(enrollmentKey)).namespaces;
    }

    while (commitEntryIterator.moveNext() &&
        syncResponse.length < AtSecondaryConfig.syncPageLimit) {
      var atKeyType = AtKey.getKeyType(commitEntryIterator.current.key,
          enforceNameSpace: false);
      if (atKeyType == KeyType.invalidKey) {
        logger.warning(
            'prepareResponse | ${commitEntryIterator.current.key} is an invalid key. Skipping.');
        continue;
      }
      late AtKey parsedAtKey;
      try {
        parsedAtKey = AtKey.fromString(commitEntryIterator.current.key!);
      } on InvalidSyntaxException catch (_) {
        logger.warning(
            'prepareResponse | found an invalid key "${commitEntryIterator.current.key!}" in the commit log. Skipping.');
        continue;
      }
      String? keyNamespace = parsedAtKey.namespace;
      if ((keyNamespace != null && keyNamespace.isNotEmpty) &&
          enrolledNamespaces.isNotEmpty &&
          (!enrolledNamespaces.containsKey(allNamespaces) &&
              !enrolledNamespaces.containsKey(enrollManageNamespace) &&
              !enrolledNamespaces.containsKey(keyNamespace))) {
        continue;
      }
      var keyStoreEntry = KeyStoreEntry();
      keyStoreEntry.key = commitEntryIterator.current.key;
      keyStoreEntry.commitId = commitEntryIterator.current.value.commitId;
      keyStoreEntry.operation = commitEntryIterator.current.value.operation;
      if (commitEntryIterator.current.value.operation != CommitOp.DELETE) {
        // If commitOperation is update (or) update_all (or) update_meta and key does not
        // exist in keystore, skip the key to sync and continue
        if (!keyStore.isKeyExists(commitEntryIterator.current.key)) {
          logger.finer(
              'prepareResponse | ${commitEntryIterator.current.key} does not exist in the keystore. Skipping.');
          continue;
        }

        var atData = await keyStore.get(commitEntryIterator.current.key);
        if (atData == null) {
          logger.info('atData is null for ${commitEntryIterator.current.key}');
          continue;
        }
        keyStoreEntry.value = atData.data;
        keyStoreEntry.atMetaData = _populateMetadata(atData);
      }

      var utfJsonEncodedEntry = utf8.encode(jsonEncode(keyStoreEntry));

      bool isOverflow = currentResponseLength + utfJsonEncodedEntry.length >
          desiredMaxSyncResponseLength;

      // If we've already got an item in the response, and this item would overflow our syncBufferSize
      if (syncResponse.isNotEmpty && isOverflow) {
        logger.finer(
            'Sync progressive verb buffer overflow. BufferSize:$desiredMaxSyncResponseLength');
        break;
      }

      // We ensure that if entries are available then at least one is always returned.
      // If we don't do that, then the client will keep on requesting a sync from the
      // same point, and the server will keep on returning empty lists, ad infinitum.
      syncResponse.add(keyStoreEntry);

      if (isOverflow) {
        logger.finer(
            'Sync progressive verb buffer overflow. BufferSize:$desiredMaxSyncResponseLength');
        break;
      } else {
        currentResponseLength += utfJsonEncodedEntry.length;
      }
    }
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
