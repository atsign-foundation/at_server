import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:at_secondary/src/conf/config_util.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/persistence_backend.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final tmp = '${Directory.current.path}/test/persistence_migration_tmp';

  void useTempConfig() {
    AtSecondaryConfig.configYamlMap = YamlMap.wrap({
      'hive': {
        'storagePath': '$tmp/hive',
        'commitLogPath': '$tmp/commitLog',
        'accessLogPath': '$tmp/accessLog',
        'notificationStoragePath': '$tmp/notif',
      },
      'persistence': {'storageRoot': tmp},
    });
  }

  setUp(useTempConfig);

  tearDown(() {
    AtSecondaryConfig.configYamlMap = ConfigUtil.getYaml();
    final dir = Directory(tmp);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('config getters default to hive / storage', () {
    AtSecondaryConfig.configYamlMap = YamlMap.wrap({});
    expect(AtSecondaryConfig.persistenceBackend, 'hive');
    expect(AtSecondaryConfig.storageRoot, 'storage');
  });

  test('marker round-trips through disk', () {
    final path = '$tmp/.persistence_backend';
    final now = DateTime.now();
    PersistenceBackendMarker.write(
        path,
        PersistenceBackendMarker(
            activeBackend: 'sqlite',
            previousBackend: 'hive',
            previousPaths: ['$tmp/hive', '$tmp/commitLog'],
            migratedAt: now));
    final read = PersistenceBackendMarker.read(path)!;
    expect(read.activeBackend, 'sqlite');
    expect(read.previousBackend, 'hive');
    expect(read.previousPaths, ['$tmp/hive', '$tmp/commitLog']);
    expect(read.migratedAt!.toUtc(), now.toUtc());
  });

  test(
      'migrateIfNeeded hive -> sqlite migrates, verifies, flips marker, '
      'retains source', () async {
    const atSign = '@migrate_alice';

    // Seed a Hive store via the configured hive config.
    final hiveFactory = PersistenceBackendManager.factoryFor('hive');
    final hiveBundle = await hiveFactory.initialize(
        atSign, PersistenceBackendManager.configFor('hive'));
    await hiveBundle.keyValueStore
        .create('phone.wavi$atSign', AtData()..data = '12345');
    await hiveBundle.keyValueStore
        .create('email.wavi$atSign', AtData()..data = 'a@b.com');
    await hiveFactory.close();

    // No marker yet → current backend defaults to hive → migrate to sqlite.
    await PersistenceBackendManager.migrateIfNeeded(atSign, 'sqlite');

    // Marker flipped, source retained.
    final marker = PersistenceBackendMarker.read('$tmp/.persistence_backend')!;
    expect(marker.activeBackend, 'sqlite');
    expect(marker.previousBackend, 'hive');
    expect(marker.previousPaths, isNotEmpty);
    expect(marker.migratedAt, isNotNull);
    expect(Directory('$tmp/hive').existsSync(), true,
        reason: 'source retained');

    // The SQLite target has the data.
    final sqliteFactory = SqliteAtPersistenceFactory();
    final sqliteBundle = await sqliteFactory.initialize(
        atSign, PersistenceBackendManager.configFor('sqlite'));
    expect((await sqliteBundle.keyValueStore.get('phone.wavi$atSign'))!.data,
        '12345');
    expect((await sqliteBundle.keyValueStore.get('email.wavi$atSign'))!.data,
        'a@b.com');
    await sqliteFactory.close();

    // Idempotent: with the marker now on sqlite, a second call is a no-op.
    await PersistenceBackendManager.migrateIfNeeded(atSign, 'sqlite');
  });

  test('reverse migrateIfNeeded sqlite -> hive works', () async {
    const atSign = '@migrate_bob';

    // Start with data on sqlite + a marker saying sqlite is active.
    final sqliteFactory = SqliteAtPersistenceFactory();
    final sqliteBundle = await sqliteFactory.initialize(
        atSign, PersistenceBackendManager.configFor('sqlite'));
    await sqliteBundle.keyValueStore
        .create('loc.wavi$atSign', AtData()..data = 'paris');
    await sqliteFactory.close();
    PersistenceBackendMarker.write('$tmp/.persistence_backend',
        PersistenceBackendMarker(activeBackend: 'sqlite'));

    await PersistenceBackendManager.migrateIfNeeded(atSign, 'hive');

    final marker = PersistenceBackendMarker.read('$tmp/.persistence_backend')!;
    expect(marker.activeBackend, 'hive');
    expect(marker.previousBackend, 'sqlite');

    final hiveFactory = PersistenceBackendManager.factoryFor('hive');
    final hiveBundle = await hiveFactory.initialize(
        atSign, PersistenceBackendManager.configFor('hive'));
    expect(
        (await hiveBundle.keyValueStore.get('loc.wavi$atSign'))!.data, 'paris');
    await hiveFactory.close();
  });

  test('sweepStaleSource deletes retained source once old enough', () {
    // A marker recording a migration completed 10 days ago, with a
    // retained (existing) source dir.
    Directory('$tmp/oldhive').createSync(recursive: true);
    File('$tmp/oldhive/box.hive').writeAsStringSync('stale');
    PersistenceBackendMarker.write(
        '$tmp/.persistence_backend',
        PersistenceBackendMarker(
          activeBackend: 'sqlite',
          previousBackend: 'hive',
          previousPaths: ['$tmp/oldhive'],
          migratedAt: DateTime.now().subtract(Duration(days: 10)),
        ));

    // Too young → no-op.
    expect(
        PersistenceBackendManager.sweepStaleSource('$tmp/.persistence_backend',
            retention: Duration(days: 30)),
        isEmpty);
    expect(Directory('$tmp/oldhive').existsSync(), true);

    // Old enough → deleted, marker cleared of previous*.
    final deleted = PersistenceBackendManager.sweepStaleSource(
        '$tmp/.persistence_backend',
        retention: Duration(days: 7));
    expect(deleted, ['$tmp/oldhive']);
    expect(Directory('$tmp/oldhive').existsSync(), false);
    final after = PersistenceBackendMarker.read('$tmp/.persistence_backend')!;
    expect(after.activeBackend, 'sqlite');
    expect(after.previousBackend, isNull);
  });
}
