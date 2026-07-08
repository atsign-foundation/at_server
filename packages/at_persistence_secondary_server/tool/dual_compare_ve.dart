import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:path/path.dart' as p;

/// Compares one atSign's Hive vs SQLite DB sets as laid out by the functional
/// virtualenv after a `persistenceBackend=dual` run: Hive under the legacy
/// `hive/ commit_log/ access_log/ notification_log/` names, SQLite under
/// `storage/sqlite/`. Prints IDENTICAL or the differences; exits 1 on any
/// difference so a CI step can gate on it.
///
///   dart run tool/dual_compare_ve.dart `<secondary-dir>` `<atSign>`
Future<void> main(List<String> args) async {
  if (args.length != 2) {
    print('usage: dual_compare_ve.dart <secondary-dir> <atSign>');
    return;
  }
  final dir = args[0], atSign = args[1];

  final hiveFactory = HiveAtPersistenceFactory();
  final sqliteFactory = SqliteAtPersistenceFactory();
  try {
    final hive = await hiveFactory.initialize(
        atSign,
        HivePersistenceConfig.serverDefaults(
          storagePath: p.join(dir, 'hive'),
          commitLogPath: p.join(dir, 'commit_log'),
          accessLogPath: p.join(dir, 'access_log'),
          notificationStoragePath: p.join(dir, 'notification_log'),
        ));
    final sqlite = await sqliteFactory.initialize(
        atSign,
        SqlitePersistenceConfig.serverDefaults(
            storagePath: p.join(dir, 'storage', 'sqlite')));

    final hiveSnap = await PersistenceSnapshot.capture(hive);
    final sqliteSnap = await PersistenceSnapshot.capture(sqlite);
    final diffs = hiveSnap.differencesFrom(sqliteSnap);

    if (diffs.isEmpty) {
      print(
          'IDENTICAL $atSign  hive=${hiveSnap.counts} sqlite=${sqliteSnap.counts}');
    } else {
      print('MISMATCH(${diffs.length}) $atSign  '
          'hive=${hiveSnap.counts} sqlite=${sqliteSnap.counts}');
      for (final d in diffs.take(8)) {
        print('  $d');
      }
    }
  } finally {
    await hiveFactory.close();
    await sqliteFactory.close();
  }
}
