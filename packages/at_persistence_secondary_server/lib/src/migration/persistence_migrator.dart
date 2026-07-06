import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// Per-store counts produced by a [PersistenceMigrator.migrate] run.
class MigrationReport {
  final int keys;
  final int commitEntries;
  final int accessEntries;
  final int notifications;

  MigrationReport({
    required this.keys,
    required this.commitEntries,
    required this.accessEntries,
    required this.notifications,
  });

  @override
  String toString() =>
      'MigrationReport{keys: $keys, commitEntries: $commitEntries, '
      'accessEntries: $accessEntries, notifications: $notifications}';
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
class PersistenceMigrator {
  static Future<MigrationReport> migrate(
      AtPersistenceBundle source, AtPersistenceBundle target) async {
    // 1. Keystore — every key, including expired / not-yet-born.
    var keys = 0;
    final keyList = await (await source.keyValueStore
            .scanKeys(KeyPattern(), includeExpired: true))
        .toList();
    for (final k in keyList) {
      final data = await source.keyValueStore.get(k);
      if (data == null) continue;
      await target.keyValueStore.restore(k, data);
      keys++;
    }

    // 2. Commit log — preserve commit ids and sync identity.
    var commitEntries = 0;
    final srcCommitLog = source.keyValueStore.commitLog;
    final tgtCommitLog = target.keyValueStore.commitLog;
    if (srcCommitLog != null && tgtCommitLog != null) {
      await for (final entry in srcCommitLog.iterate()) {
        await tgtCommitLog.replay(entry);
        commitEntries++;
      }
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
    );
  }
}
