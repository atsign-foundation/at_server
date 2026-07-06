import 'dart:convert';

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
class PersistenceSnapshot {
  /// atKey → canonical `{data, metaData}` JSON.
  final Map<String, String> keystore;

  /// Ordered `commitId|atKey|op|opTimeMillis` lines.
  final List<String> commitLog;

  /// Ordered `fromAtSign|requestAtMillis|verb|lookupKey` lines.
  final List<String> accessLog;

  /// notification id → canonical field JSON.
  final Map<String, String> notifications;

  PersistenceSnapshot._(
      this.keystore, this.commitLog, this.accessLog, this.notifications);

  /// Captures a canonical snapshot of [bundle]. Reads every key
  /// (including expired / not-yet-born) so the snapshot reflects stored
  /// state, not query-time visibility.
  static Future<PersistenceSnapshot> capture(AtPersistenceBundle bundle) async {
    final keystore = <String, String>{};
    // Lower-cased atKeys whose row is present AND not past its expiry. Only such
    // a key's non-delete commit entry is sync-relevant — see the commit-log note.
    final liveUnexpired = <String>{};
    final now = DateTime.now().toUtc();
    final keys = await (await bundle.keyValueStore
            .scanKeys(KeyPattern(), includeExpired: true))
        .toList();
    for (final k in keys) {
      final d = await bundle.keyValueStore.get(k);
      if (d == null) continue;
      keystore[k] =
          jsonEncode({'data': d.data, 'metaData': d.metaData?.toJson()});
      final exp = d.metaData?.expiresAt?.toUtc();
      if (exp == null || exp.isAfter(now)) {
        liveUnexpired.add(k.toLowerCase());
      }
    }

    final commitLog = <String>[];
    final cl = bundle.keyValueStore.commitLog;
    if (cl != null) {
      await for (final e in cl.iterate()) {
        // Tolerate a divergence Hive produces but a faithful SQLite mirror does
        // not. After a TTL-expiry `skipCommit` sweep, Hive can leave a stale
        // non-delete commit entry in its box for an expired key: the sweep tries
        // to purge the entry via the cache-based getLatestCommitEntry, and on a
        // cache miss the box entry survives orphaned (a Hive cache/box
        // inconsistency). SQLite carries no such stale entry. A commit entry for
        // a key that is absent or expired is sync-benign — its value is gone or
        // will not sync live — so skip non-delete entries whose key is not
        // present-and-unexpired. DELETE entries, and entries for live unexpired
        // keys, are always compared: real mirror data loss still fails here.
        if (e.operation != CommitOp.DELETE &&
            !liveUnexpired.contains(e.atKey?.toLowerCase())) {
          continue;
        }
        commitLog.add('${e.commitId}|${e.atKey}|${e.operation.name}|'
            '${e.opTime?.toUtc().millisecondsSinceEpoch}');
      }
    }

    final accessLog = <String>[];
    final al = bundle.accessLog;
    if (al != null) {
      await for (final e in al.iterate()) {
        accessLog.add('${e.fromAtSign}|'
            '${e.requestDateTime?.toUtc().millisecondsSinceEpoch}|'
            '${e.verbName}|${e.lookupKey}');
      }
      // The access log is an audit trail; its cross-backend insertion order
      // is not load-bearing (and interleaves under concurrent dual-write), so
      // compare it as a multiset. Migration preserves order, so sorting is a
      // no-op there.
      accessLog.sort();
    }

    final notifications = <String, String>{};
    final nk = bundle.notificationKeystore;
    if (nk != null) {
      await for (final n in nk.iterate()) {
        notifications[n.id ?? ''] = _canonicalNotification(n);
      }
    }

    return PersistenceSnapshot._(keystore, commitLog, accessLog, notifications);
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
    _collectMapDiffs('keystore', keystore, other.keystore, diffs);
    _collectListDiffs('commitLog', commitLog, other.commitLog, diffs);
    _collectListDiffs('accessLog', accessLog, other.accessLog, diffs);
    _collectMapDiffs(
        'notifications', notifications, other.notifications, diffs);
    return diffs;
  }

  bool matches(PersistenceSnapshot other) =>
      differencesFrom(other).isEmpty;

  /// Per-store row counts, for the compare CLI's summary line.
  Map<String, int> get counts => {
        'keystore': keystore.length,
        'commitLog': commitLog.length,
        'accessLog': accessLog.length,
        'notifications': notifications.length,
      };

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

  static void _collectMapDiffs(String label, Map<String, String> a,
      Map<String, String> b, List<String> out) {
    for (final key in a.keys) {
      if (!b.containsKey(key)) {
        out.add('$label: key only in A: $key');
      } else if (a[key] != b[key]) {
        out.add('$label: value differs for $key\n    A=${a[key]}\n    B=${b[key]}');
      }
    }
    for (final key in b.keys) {
      if (!a.containsKey(key)) out.add('$label: key only in B: $key');
    }
  }

  static void _collectListDiffs(
      String label, List<String> a, List<String> b, List<String> out) {
    if (a.length != b.length) {
      out.add('$label: length ${a.length} (A) != ${b.length} (B)');
    }
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) {
        out.add('$label[$i] differs:\n    A=${a[i]}\n    B=${b[i]}');
      }
    }
  }
}
