import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_utils.dart';

/// Per-store counts produced by a [PersistenceMigrator.migrate] run.
class MigrationReport {
  final int keys;
  final int commitEntries;
  final int accessEntries;
  final int notifications;

  /// Non-delete commit entries dropped because their key is absent from the
  /// source keystore. See [PersistenceMigrator] for why these exist and why
  /// migration is where they get cleaned up.
  final int orphanedCommitEntries;

  MigrationReport({
    required this.keys,
    required this.commitEntries,
    required this.accessEntries,
    required this.notifications,
    required this.orphanedCommitEntries,
  });

  @override
  String toString() =>
      'MigrationReport{keys: $keys, commitEntries: $commitEntries, '
      'accessEntries: $accessEntries, notifications: $notifications, '
      'orphanedCommitEntries: $orphanedCommitEntries}';
}

/// Copies every store from one [AtPersistenceBundle] to another, backend-
/// agnostically, using the verbatim primitives so nothing is re-derived:
///   * keystore   — `scanKeys(includeExpired) + get → restore`
///   * commit log — `iterate → replay` (preserving `commitId`, and the
///                   allocator is bumped past every replayed id)
///   * access log — `iterate → replay` (preserving `requestDateTime`)
///   * notifications — `iterate → put`
///
/// The result is byte-identical to the source under
/// [PersistenceSnapshot]. The target should be freshly initialised (empty)
/// — the migrator does not clear it first.
///
/// One exception to "verbatim": ORPHANED commit entries are dropped. A
/// non-delete commit entry whose key is absent from the keystore cannot be
/// synced — the atServer fetches each entry's value by atKey, finds nothing,
/// and skips it. The Hive backend produces these: its commit log's box and
/// its in-memory cache can disagree, and the TTL-expiry purge is driven by
/// the cache, so it can miss the box row. The SQLite backend purges by atKey
/// directly against storage and cannot produce one.
///
/// Migration is the right place to clean them up: both stores are already
/// being walked, so it costs nothing, and copying them forward would make
/// them permanent residents of a backend that can never generate one.
class PersistenceMigrator {
  static final _logger = AtSignLogger('PersistenceMigrator');

  static Future<MigrationReport> migrate(
      AtPersistenceBundle source, AtPersistenceBundle target) async {
    // 1. Keystore — every key, including expired / not-yet-born.
    var keys = 0;
    // Lower-cased keys actually restored into the target. Pass 2 keeps a
    // commit entry only if its key made it here, so the target can never
    // hold a commit entry referencing a key it does not have.
    final restoredKeys = <String>{};
    final keyList = await (await source.keyValueStore
            .scanKeys(KeyPattern(), includeExpired: true))
        .toList();
    for (final k in keyList) {
      final data = await source.keyValueStore.get(k);
      if (data == null) continue;
      await target.keyValueStore.restore(k, data);
      restoredKeys.add(k.toLowerCase());
      keys++;
    }

    // 2. Commit log — preserve commit ids and sync identity, minus orphans.
    var commitEntries = 0;
    var orphanedCommitEntries = 0;
    final srcCommitLog = source.keyValueStore.commitLog;
    final tgtCommitLog = target.keyValueStore.commitLog;
    if (srcCommitLog != null && tgtCommitLog != null) {
      await for (final entry in srcCommitLog.iterate()) {
        final atKey = entry.atKey;
        // A DELETE entry legitimately has no keystore row — it IS the
        // tombstone telling clients the key went away. Dropping those would
        // break delete propagation, so they always survive. An entry with a
        // null atKey is left alone too: it cannot be matched either way, and
        // malformed-entry repair is the backend's job, not the migrator's.
        if (entry.operation != CommitOp.DELETE &&
            atKey != null &&
            !restoredKeys.contains(atKey.toLowerCase())) {
          _logger.info('Dropping orphaned commit entry: commitId'
              '=${entry.commitId} $atKey (key absent from keystore)');
          orphanedCommitEntries++;
          continue;
        }
        await tgtCommitLog.replay(entry);
        commitEntries++;
      }
    }
    if (orphanedCommitEntries > 0) {
      _logger.warning('Dropped $orphanedCommitEntries orphaned commit '
          'entries during migration (keys absent from keystore)');
    }

    // 3. Access log — preserve timestamps and order.
    var accessEntries = 0;
    final srcAccessLog = source.accessLog;
    final tgtAccessLog = target.accessLog;
    if (srcAccessLog != null && tgtAccessLog != null) {
      await for (final entry in srcAccessLog.iterate()) {
        await tgtAccessLog.replay(entry);
        accessEntries++;
      }
    }

    // 4. Notifications — put stores verbatim; read normalises both sides.
    var notifications = 0;
    final srcNotif = source.notificationKeystore;
    final tgtNotif = target.notificationKeystore;
    if (srcNotif != null && tgtNotif != null) {
      await for (final n in srcNotif.iterate()) {
        final id = n.id;
        if (id == null) continue;
        await tgtNotif.put(id, n);
        notifications++;
      }
    }

    return MigrationReport(
      keys: keys,
      commitEntries: commitEntries,
      accessEntries: accessEntries,
      notifications: notifications,
      orphanedCommitEntries: orphanedCommitEntries,
    );
  }
}
