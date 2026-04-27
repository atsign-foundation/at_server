import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:meta/meta.dart';

class SyncProgressiveVerbHandler extends AbstractVerbHandler {
  static SyncFrom syncFrom = SyncFrom();

  final AtCommitLog? _commitLogOverride;
  AtCommitLog get commitLog =>
      _commitLogOverride ?? AtSecondaryServerImpl.getInstance().commitLog;

  SyncProgressiveVerbHandler(super.keyStore, {AtCommitLog? commitLog})
      : _commitLogOverride = commitLog;

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
    // Use the injected commit log.
    final AtCommitLog atCommitLog = commitLog;
    int? skipDeletesUntil = verbParams[AtConstants.skipDeletesUntil] != null
        ? int.parse(verbParams[AtConstants.skipDeletesUntil]!)
        : null;
    int? syncLimit = verbParams[AtConstants.syncLimit] != null
        ? int.parse(verbParams[AtConstants.syncLimit]!)
        : null;
    // Get entries to sync
    Iterator<MapEntry<String, CommitEntry>> commitEntryIterator;
    // if client doesn't pass syncLimit set the default value from server
    syncLimit ??= AtSecondaryConfig.syncPageLimit;
    commitEntryIterator = atCommitLog.getEntries(
        int.parse(verbParams[AtConstants.fromCommitSequence]!) + 1,
        regex: verbParams['regex'],
        skipDeletesUntil: skipDeletesUntil,
        limit: syncLimit);

    List<KeyStoreEntry> syncResponse = [];
    InboundConnectionMetadata connectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    await prepareResponse(
      capacity,
      syncLimit,
      syncResponse,
      commitEntryIterator,
      connectionMetadata,
      enrollmentId: connectionMetadata.enrollmentId,
    );

    response.data = jsonEncode(syncResponse);
  }

  /// Adds items from the [commitEntryIterator] to the [syncResponse] until either
  /// 1. there is at least one item in [syncResponse], and the response length is greater than [desiredMaxSyncResponseLength], or
  /// 2. there are [AtSecondaryConfig.syncPageLimit] items in the [syncResponse]
  @visibleForTesting
  Future<void> prepareResponse(
      int desiredMaxSyncResponseLength,
      int syncPageLimit,
      List<KeyStoreEntry> syncResponse,
      Iterator<dynamic> commitEntryIterator,
      InboundConnectionMetadata connectionMetadata,
      {String? enrollmentId}) async {
    int currentResponseLength = 0;
    while (
        commitEntryIterator.moveNext() && syncResponse.length < syncPageLimit) {
      var atKeyType = AtKey.getKeyType(commitEntryIterator.current.key,
          enforceNameSpace: false);
      if (atKeyType == KeyType.invalidKey) {
        logger.warning(
            'prepareResponse | ${commitEntryIterator.current.key} is an invalid key. Skipping.');
        continue;
      }
      try {
        AtKey.fromString(commitEntryIterator.current.key!);
      } on InvalidSyntaxException catch (_) {
        logger.warning(
            'prepareResponse | found an invalid key "${commitEntryIterator.current.key!}" in the commit log. Skipping.');
        continue;
      }
      if (!(await isAuthorized(
        connectionMetadata,
        atKey: commitEntryIterator.current.key!,
      ))) {
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

        AtData? atData = await keyStore.get(commitEntryIterator.current.key);
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

  Map _populateMetadata(AtData value) {
    var metaDataMap = <String, dynamic>{};
    AtMetaData? metaData = value.metaData;
    if (metaData == null) {
      return metaDataMap;
    }
    Iterator itr = metaData.toJson().entries.iterator;
    while (itr.moveNext()) {
      // The value of [AtConstants.sharedWithPublicKeyHash] stores a Map containing
      // the hash value and the hashing algorithm used for hashing the data.
      // For example, {"hash":"dummy_value", "hashingAlgo":"sha512"}.
      // Using toString() will not allow convert this into a Map, which is necessary
      // for constructing the PublicKeyHash type on the client side.
      // Therefore, a JSON-encoded string is used here, and on the client side,
      // "jsonDecode" will be used to retrieve the Map and build the PublicKeyHash instance.
      if (itr.current.key == AtConstants.sharedWithPublicKeyHash &&
          itr.current.value != null) {
        metaDataMap[itr.current.key] = jsonEncode(itr.current.value);
        continue;
      }
      if (itr.current.value != null) {
        metaDataMap[itr.current.key] = itr.current.value.toString();
      }
    }
    return metaDataMap;
  }

  void logResponse(String response) {
    if (!logger.isLoggable('finer')) {
      return;
    }
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
