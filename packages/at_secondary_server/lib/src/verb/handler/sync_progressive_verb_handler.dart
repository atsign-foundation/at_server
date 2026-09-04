import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/regex_util.dart' as sync_filter;
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:meta/meta.dart';

class SyncProgressiveVerbHandler extends AbstractVerbHandler {
  static SyncFrom syncFrom = SyncFrom();

  final AtCommitLog commitLog;

  SyncProgressiveVerbHandler(super.keyStore, {required this.commitLog});

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
    final int fromCommitId =
        int.parse(verbParams[AtConstants.fromCommitSequence]!) + 1;
    final int? skipDeletesUntil =
        verbParams[AtConstants.skipDeletesUntil] != null
            ? int.parse(verbParams[AtConstants.skipDeletesUntil]!)
            : null;
    final String? regex = verbParams['regex'];
    int syncLimit = verbParams[AtConstants.syncLimit] != null
        ? int.parse(verbParams[AtConstants.syncLimit]!)
        : AtSecondaryConfig.syncPageLimit;

    final connectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    final enrollmentId = connectionMetadata.enrollmentId;
    // NOTE resolved once per request, so the per-entry filter below can stay
    // synchronous.
    final bool cram = AbstractVerbHandler.isCramConnection(connectionMetadata);
    final EnrollDataStoreValue? enroll = (cram || enrollmentId == null)
        ? null
        : await resolveEnrollment(enrollmentId);
    final int? latestCommitId = commitLog.lastCommittedSequenceNumber();

    bool whereFilter(CommitEntry entry) {
      final atKey = entry.atKey;
      if (atKey == null) return false;

      if (AtKey.getKeyType(atKey, enforceNameSpace: false) ==
          KeyType.invalidKey) {
        logger.warning('sync filter | $atKey is an invalid key. Skipping.');
        return false;
      }
      try {
        AtKey.fromString(atKey);
      } catch (_) {
        // NOTE AtKey.fromString raises Errors as well as Exceptions on some
        // key shapes; the entry is skipped rather than ending the walk.
        logger.warning(
            'sync filter | found an invalid key "$atKey" in the commit log. Skipping.');
        return false;
      }

      if (regex != null &&
          regex.isNotEmpty &&
          !RegExp(regex).hasMatch(atKey) &&
          !sync_filter.alwaysIncludeInSync(atKey)) {
        return false;
      }

      if (!isAuthorizedSync(enroll, enrollmentId, cram: cram, atKey: atKey)) {
        return false;
      }

      // NOTE the keystore-presence check happens in prepareResponse; the
      // keystore's existence check is async and cannot run in this
      // synchronous predicate.
      return true;
    }

    final List<KeyStoreEntry> syncResponse = [];
    await prepareResponse(
      capacity,
      syncLimit,
      syncResponse,
      commitLog.iterate(
        fromCommitId: fromCommitId,
        where: whereFilter,
        skipDeletesUntil: skipDeletesUntil,
        latestCommitId: latestCommitId,
      ),
    );

    response.data = jsonEncode(syncResponse);
  }

  /// Drains the filtered [stream] of commit entries into [syncResponse],
  /// stopping at [syncPageLimit] entries or at
  /// [desiredMaxSyncResponseLength] bytes.
  ///
  /// The first entry is always added, even when it exceeds the buffer, so the
  /// client has something to advance past.
  @visibleForTesting
  Future<void> prepareResponse(
    int desiredMaxSyncResponseLength,
    int syncPageLimit,
    List<KeyStoreEntry> syncResponse,
    Stream<CommitEntry> stream,
  ) async {
    int currentResponseLength = 0;
    await for (final entry in stream) {
      if (syncResponse.length >= syncPageLimit) break;

      final keyStoreEntry = KeyStoreEntry()
        ..key = entry.atKey!
        ..commitId = entry.commitId!
        ..operation = entry.operation!;

      if (entry.operation != CommitOp.DELETE) {
        final AtData? atData;
        try {
          atData = await keyStore.get(entry.atKey!);
        } on KeyNotFoundException {
          // NOTE the commit entry can outlive the key, so a missing value is
          // skipped rather than failing the whole sync request.
          logger.info('${entry.atKey} not found in keystore; skipping entry');
          continue;
        }
        if (atData == null) {
          logger.info('atData is null for ${entry.atKey}');
          continue;
        }
        keyStoreEntry.value = atData.data;
        keyStoreEntry.atMetaData = _populateMetadata(atData);
      }

      final encoded = utf8.encode(jsonEncode(keyStoreEntry));
      final isOverflow =
          currentResponseLength + encoded.length > desiredMaxSyncResponseLength;
      if (syncResponse.isNotEmpty && isOverflow) {
        logger.finer(
            'Sync progressive verb buffer overflow. BufferSize:$desiredMaxSyncResponseLength');
        break;
      }
      syncResponse.add(keyStoreEntry);
      if (isOverflow) {
        logger.finer(
            'Sync progressive verb buffer overflow. BufferSize:$desiredMaxSyncResponseLength');
        break;
      }
      currentResponseLength += encoded.length;
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
      // NOTE structured value: JSON-encoded so the client can jsonDecode it
      // back into a Map, which toString() would not allow.
      if (itr.current.key == AtConstants.sharedWithPublicKeyHash &&
          itr.current.value != null) {
        metaDataMap[itr.current.key] = jsonEncode(itr.current.value);
        continue;
      }
      // NOTE the client decodes this with Metadata.decodeAppMetadata, whose
      // String form is base64(JSON).
      if (itr.current.key == AtConstants.appMetadata &&
          itr.current.value != null) {
        metaDataMap[itr.current.key] =
            Metadata.encodeAppMetadata(metaData.appMetadata!);
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
