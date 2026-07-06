import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/impl/sqlite/sqlite_database.dart';
import 'package:at_persistence_secondary_server/src/impl/sqlite/sqlite_persistence_config.dart';
import 'package:at_persistence_secondary_server/src/impl/sqlite/sqlite_schema.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  final root = '${Directory.current.path}/test/sqlite/tmp';

  tearDown(() {
    final dir = Directory(root);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('SqlitePersistenceConfig', () {
    test('derives per-atSign db path under storagePath', () {
      final config = SqlitePersistenceConfig.serverDefaults(storagePath: root);
      expect(config.backend, AtPersistenceBackendId.sqlite);
      expect(config.dbPathFor('@alice🛠'), '$root/@alice🛠/atsign.db');
      expect(config.enableCommitLog, true);
      expect(config.enableAccessLog, true);
      expect(config.enableNotificationKeystore, true);
    });

    test('clientDefaults disables the optional capabilities', () {
      final config = SqlitePersistenceConfig.clientDefaults(storagePath: root);
      expect(config.enableCommitLog, false);
      expect(config.enableAccessLog, false);
      expect(config.enableNotificationKeystore, false);
    });
  });

  group('SqliteDatabase / SqliteSchema', () {
    test('open creates the file, all tables, seed counter, user_version', () {
      final config = SqlitePersistenceConfig.serverDefaults(storagePath: root);
      final path = config.dbPathFor('@alice');
      final db = SqliteDatabase.open('@alice', path);

      expect(File(path).existsSync(), true);

      final tables = db.raw
          .select(
              "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
          .map((r) => r['name'] as String)
          .toList();
      expect(
          tables,
          containsAll(
              ['at_data', 'commit_log', 'counters', 'notifications', 'access_log']));

      final ver = db.raw.select('PRAGMA user_version;').first.values.first;
      expect(ver, SqliteSchema.contractVersion);

      final counter = db.raw.select(
          "SELECT value FROM counters WHERE name = 'last_commit_id';");
      expect(counter.first['value'], 0);

      final journal =
          db.raw.select('PRAGMA journal_mode;').first.values.first;
      expect((journal as String).toLowerCase(), 'wal');

      db.close();
    });

    test('re-opening an existing db is idempotent (no data loss)', () {
      final path =
          SqlitePersistenceConfig.serverDefaults(storagePath: root)
              .dbPathFor('@bob');
      var db = SqliteDatabase.open('@bob', path);
      db.raw.execute(
          "INSERT INTO at_data (atkey, value, metadata) VALUES ('k@bob','v','{}');");
      db.close();

      db = SqliteDatabase.open('@bob', path);
      final rows = db.raw.select('SELECT atkey, value FROM at_data;');
      expect(rows.length, 1);
      expect(rows.first['value'], 'v');
      db.close();
    });

    test('runInTransaction rolls back on throw', () {
      final path =
          SqlitePersistenceConfig.serverDefaults(storagePath: root)
              .dbPathFor('@carol');
      final db = SqliteDatabase.open('@carol', path);

      expect(
          () => db.runInTransaction(() {
                db.raw.execute(
                    "INSERT INTO at_data (atkey, value, metadata) VALUES ('k@carol','v','{}');");
                throw StateError('boom');
              }),
          throwsA(isA<StateError>()));

      expect(db.raw.select('SELECT COUNT(*) c FROM at_data;').first['c'], 0);
      db.close();
    });

    test('nested runInTransaction commits once; inner throw rolls back all',
        () {
      final path =
          SqlitePersistenceConfig.serverDefaults(storagePath: root)
              .dbPathFor('@dave');
      final db = SqliteDatabase.open('@dave', path);

      // Happy path: nested join commits the whole thing.
      db.runInTransaction(() {
        db.raw.execute(
            "INSERT INTO at_data (atkey, value, metadata) VALUES ('a@dave','1','{}');");
        db.runInTransaction(() {
          db.raw.execute(
              "INSERT INTO at_data (atkey, value, metadata) VALUES ('b@dave','2','{}');");
        });
      });
      expect(db.raw.select('SELECT COUNT(*) c FROM at_data;').first['c'], 2);

      // Inner throw aborts the whole outer transaction.
      expect(
          () => db.runInTransaction(() {
                db.raw.execute(
                    "INSERT INTO at_data (atkey, value, metadata) VALUES ('c@dave','3','{}');");
                db.runInTransaction(() {
                  throw StateError('inner boom');
                });
              }),
          throwsA(isA<StateError>()));
      expect(db.raw.select('SELECT COUNT(*) c FROM at_data;').first['c'], 2);
      db.close();
    });

    test('clear drops rows and resets the counter, keeping the db open', () {
      final path =
          SqlitePersistenceConfig.serverDefaults(storagePath: root)
              .dbPathFor('@erin');
      final db = SqliteDatabase.open('@erin', path);
      db.raw.execute(
          "INSERT INTO at_data (atkey, value, metadata) VALUES ('k@erin','v','{}');");
      db.raw.execute(
          "UPDATE counters SET value = 7 WHERE name = 'last_commit_id';");

      db.clear();

      expect(db.raw.select('SELECT COUNT(*) c FROM at_data;').first['c'], 0);
      expect(
          db.raw
              .select("SELECT value FROM counters WHERE name='last_commit_id';")
              .first['value'],
          0);
      db.close();
    });

    test('refuses to open a forward-versioned database', () {
      final path =
          SqlitePersistenceConfig.serverDefaults(storagePath: root)
              .dbPathFor('@frank');
      // Create the db normally (dir + file + schema at v1), then stamp it
      // with a newer contract version to simulate a forward-versioned file.
      SqliteDatabase.open('@frank', path).close();
      final raw = sqlite3.open(path);
      raw.execute('PRAGMA user_version = 999;');
      raw.dispose();

      expect(() => SqliteDatabase.open('@frank', path),
          throwsA(isA<StateError>()));
    });
  });
}
