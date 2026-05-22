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
    final AtCommitLog atCommitLog = commitLog;
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
    // Resolve enrollment ONCE per request — sync iterates many candidate
    // entries against a single enrollment context, so the per-entry filter
    // inside the iterate() where: closure can stay synchronous.
    final EnrollDataStoreValue? enroll =
        (enrollmentId == null) ? null : await resolveEnrollment(enrollmentId);
    final int? latestCommitId = atCommitLog.lastCommittedSequenceNumber();

    bool whereFilter(CommitEntry entry) {
      final atKey = entry.atKey;
      if (atKey == null) return false;

      // Invalid key shape — corrupt commit-log entry.
      if (AtKey.getKeyType(atKey, enforceNameSpace: false) ==
          KeyType.invalidKey) {
        logger.warning('sync filter | $atKey is an invalid key. Skipping.');
        return false;
      }
      try {
        AtKey.fromString(atKey);
      } on InvalidSyntaxException catch (_) {
        logger.warning(
            'sync filter | found an invalid key "$atKey" in the commit log. Skipping.');
        return false;
      }

      // skipDeletesUntil: skip DELETE entries below the threshold,
      // unless this is the latest commit entry overall (then it stays
      // so the client can advance its watermark).
      if (skipDeletesUntil != null &&
          entry.operation == CommitOp.DELETE &&
          entry.commitId != null &&
          entry.commitId! <= skipDeletesUntil &&
          entry.commitId != latestCommitId) {
        return false;
      }

      // Regex / always-include-in-sync filter.
      if (regex != null &&
          regex.isNotEmpty &&
          !RegExp(regex).hasMatch(atKey) &&
          !sync_filter.alwaysIncludeInSync(atKey)) {
        return false;
      }

      // Enrollment authorization (sync seam from 3.5c).
      if (!isAuthorizedSync(enroll, enrollmentId, atKey: atKey)) {
        return false;
      }

      // Note: for non-DELETE entries the keystore-presence check is
      // applied in the output-flow loop (prepareResponse), where the
      // keyValueStore.get is the real guard against the TOCTOU window
      // between filter-time and fetch-time. The keystore's existence
      // check is async, so it cannot run inside this synchronous
      // `where` predicate.
      return true;
    }

    final List<KeyStoreEntry> syncResponse = [];
    await prepareResponse(
      capacity,
      syncLimit,
      syncResponse,
      atCommitLog.iterate(fromCommitId: fromCommitId, where: whereFilter),
    );

    response.data = jsonEncode(syncResponse);
  }

  /// Drains the filtered [stream] of commit entries into [syncResponse],
  /// applying output-flow logic only:
  ///
  ///   - For non-DELETE entries, fetch the value from [keyStore]; skip if
  ///     missing (handles the TOCTOU window between filter-time and
  ///     fetch-time, where a concurrent delete can null the get).
  ///   - Stop adding once `syncResponse.length >= syncPageLimit`.
  ///   - Stop when adding the current entry would exceed
  ///     [desiredMaxSyncResponseLength], provided at least one entry is
  ///     already in the response. The first entry is always added even
  ///     if it exceeds the buffer, so the client has something to
  ///     advance past.
  ///
  /// The stream is unbounded by design — if every entry past `from`
  /// fails the filter, the loop terminates on stream-end with
  /// `syncResponse` empty. That returns `[]` to the client, but
  /// bounded in time (one full scan), not the ad-infinitum loop the
  /// previous limit-based impl was vulnerable to when filters
  /// rejected every candidate in a 25-entry window.
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
        final atData = await keyStore.get(entry.atKey!);
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
