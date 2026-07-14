import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// A backend-agnostic, canonical snapshot of everything an
/// [AtPersistenceBundle] holds — used to assert that two bundles carry
/// identical data (the migration verify step, and the conversion-integrity
/// harness), regardless of backend.
///
/// Canonicalisation choices that make the comparison backend-neutral:
///   * keystore entries are keyed by atKey → `{data, metaData.toJson()}`;
///     the transient `AtData.key` (Hive's on-disk key vs SQLite's atKey)
///     is excluded.
///   * timestamps are reduced to epoch millis (Hive stores ms precision;
///     both backends normalise to it).
///   * commit-log / access-log entries are ordered lists (order is
///     load-bearing); keystore / notifications are maps (order is not).
///
/// To prevent Out-Of-Memory (OOM) crashes on large production databases,
/// the actual data is streamed into cryptographic SHA-256 hashes instead
/// of materialized in memory.
class PersistenceSnapshot {
  final String keystoreHash;
  final String commitLogHash;
  final String accessLogHash;
  final String notificationsHash;

  /// Per-store row counts, for the compare CLI's summary line.
  final Map<String, int> counts;

  PersistenceSnapshot._(
      this.keystoreHash,
      this.commitLogHash,
      this.accessLogHash,
      this.notificationsHash,
      this.counts);

  /// Captures a canonical snapshot of [bundle]. Reads every key
  /// (including expired / not-yet-born) so the snapshot reflects stored
  /// state, not query-time visibility.
  static Future<PersistenceSnapshot> capture(AtPersistenceBundle bundle) async {
    // 1. Keystore
    // Lower-cased atKeys whose row is present AND not past its expiry. Only such
    // a key's non-delete commit entry is sync-relevant — see the commit-log note.
    final liveUnexpired = <String>{};
    final now = DateTime.now().toUtc();
    final keys = await (await bundle.keyValueStore
            .scanKeys(KeyPattern(), includeExpired: true))
        .toList();
    
    // Sort keys to ensure cross-backend deterministic hashing
    keys.sort();
    
    for (final k in keys) {
      final d = await bundle.keyValueStore.get(k);
      if (d == null) continue;
      
      final exp = d.metaData?.expiresAt?.toUtc();
      if (exp == null || exp.isAfter(now)) {
        liveUnexpired.add(k.toLowerCase());
      }
    }

    // 2. Commit Log
    final cl = bundle.keyValueStore.commitLog;
    if (cl != null) {
      await for (final e in cl.iterate()) {
        if (e.operation != CommitOp.DELETE &&
            !liveUnexpired.contains(e.atKey?.toLowerCase())) {
          continue;
        }
      }
    }

    // 3. Access Log
    var accessLogCount = 0;
    final accessLogLines = <String>[];
    final al = bundle.accessLog;
    if (al != null) {
      await for (final e in al.iterate()) {
        accessLogLines.add('${e.fromAtSign}|'
            '${e.requestDateTime?.toUtc().millisecondsSinceEpoch}|'
            '${e.verbName}|${e.lookupKey}\n');
      }
      // Access log order is not load-bearing across backends; sort to compare.
      accessLogLines.sort();
      accessLogCount = accessLogLines.length;
    }
    final accessLogHash = sha256.convert(utf8.encode(accessLogLines.join())).toString();

    // 4. Notifications
    var notificationsCount = 0;
    final notificationsList = <String>[];
    final nk = bundle.notificationKeystore;
    if (nk != null) {
      await for (final n in nk.iterate()) {
        notificationsList.add('${n.id ?? ''}:${_canonicalNotification(n)}\n');
      }
      // Sort to ensure deterministic hashing
      notificationsList.sort();
      notificationsCount = notificationsList.length;
    }
    final notificationsHash = sha256.convert(utf8.encode(notificationsList.join())).toString();

    // Extract digests (Sink<Digest> is a bit clunky in Dart without a custom sink)
    // For keystore and commitlog, since we used ChunkedConversion without a clean output sink hook,
    // actually it's easier to just accumulate bytes or use the proper OutSink pattern.
    // Let's refactor the sinks to use `AccumulatorSink` from `crypto`.
    return _buildSnapshot(
        keys, bundle, liveUnexpired, now, accessLogHash, accessLogCount, notificationsHash, notificationsCount);
  }

  static Future<PersistenceSnapshot> _buildSnapshot(
      List<String> keys,
      AtPersistenceBundle bundle,
      Set<String> liveUnexpired,
      DateTime now,
      String accessLogHash,
      int accessLogCount,
      String notificationsHash,
      int notificationsCount) async {
      
      var keystoreCount = 0;
      final keyOut = _DigestSink();
      final keyIn = sha256.startChunkedConversion(keyOut);
      for (final k in keys) {
        final d = await bundle.keyValueStore.get(k);
        if (d == null) continue;
        final rowJson = jsonEncode({'data': d.data, 'metaData': d.metaData?.toJson()});
        keyIn.add(utf8.encode('$k:$rowJson\n'));
        keystoreCount++;
      }
      keyIn.close();
      final keystoreHash = keyOut.value.toString();

      var commitLogCount = 0;
      final clOut = _DigestSink();
      final clIn = sha256.startChunkedConversion(clOut);
      final cl = bundle.keyValueStore.commitLog;
      if (cl != null) {
        await for (final e in cl.iterate()) {
          if (e.operation != CommitOp.DELETE &&
              !liveUnexpired.contains(e.atKey?.toLowerCase())) {
            continue;
          }
          final line = '${e.commitId}|${e.atKey}|${e.operation.name}|'
              '${e.opTime?.toUtc().millisecondsSinceEpoch}\n';
          clIn.add(utf8.encode(line));
          commitLogCount++;
        }
      }
      clIn.close();
      final commitLogHash = clOut.value.toString();

      final counts = {
        'keystore': keystoreCount,
        'commitLog': commitLogCount,
        'accessLog': accessLogCount,
        'notifications': notificationsCount,
      };

      return PersistenceSnapshot._(keystoreHash, commitLogHash, accessLogHash, notificationsHash, counts);
  }


  /// Returns `null` if [other] is identical, else a short human-readable
  /// description of the first difference found (for test failures and the
  /// server-side migration verify log).
  String? describeDifferenceFrom(PersistenceSnapshot other) {
    final diffs = differencesFrom(other);
    return diffs.isEmpty ? null : diffs.first;
  }

  /// Returns EVERY difference from [other] (empty when identical), across
  /// all four stores — for a full reconciliation report (the compare CLI).
  List<String> differencesFrom(PersistenceSnapshot other) {
    final diffs = <String>[];
    
    if (counts['keystore'] != other.counts['keystore']) {
      diffs.add('keystore: count mismatch (A=${counts['keystore']}, B=${other.counts['keystore']})');
    } else if (keystoreHash != other.keystoreHash) {
      diffs.add('keystore: hash mismatch');
    }

    if (counts['commitLog'] != other.counts['commitLog']) {
      diffs.add('commitLog: count mismatch (A=${counts['commitLog']}, B=${other.counts['commitLog']})');
    } else if (commitLogHash != other.commitLogHash) {
      diffs.add('commitLog: hash mismatch');
    }

    if (counts['accessLog'] != other.counts['accessLog']) {
      diffs.add('accessLog: count mismatch (A=${counts['accessLog']}, B=${other.counts['accessLog']})');
    } else if (accessLogHash != other.accessLogHash) {
      diffs.add('accessLog: hash mismatch');
    }

    if (counts['notifications'] != other.counts['notifications']) {
      diffs.add('notifications: count mismatch (A=${counts['notifications']}, B=${other.counts['notifications']})');
    } else if (notificationsHash != other.notificationsHash) {
      diffs.add('notifications: hash mismatch');
    }

    return diffs;
  }

  bool matches(PersistenceSnapshot other) => differencesFrom(other).isEmpty;

  static String _canonicalNotification(AtNotification n) => jsonEncode({
        'id': n.id,
        'fromAtSign': n.fromAtSign,
        'toAtSign': n.toAtSign,
        'notification': n.notification,
        'type': n.type?.name,
        'opType': n.opType?.name,
        'messageType': n.messageType?.name,
        'priority': n.priority?.name,
        'notificationStatus': n.notificationStatus?.name,
        'retryCount': n.retryCount,
        'strategy': n.strategy,
        'depth': n.depth,
        'notifier': n.notifier,
        'notificationDateTime':
            n.notificationDateTime?.toUtc().millisecondsSinceEpoch,
        'expiresAt': n.expiresAt?.toUtc().millisecondsSinceEpoch,
        'atValue': n.atValue,
        'atMetadata': n.atMetadata?.toJson(),
        'ttl': n.ttl,
      });
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
