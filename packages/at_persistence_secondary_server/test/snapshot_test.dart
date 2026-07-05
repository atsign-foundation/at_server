import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:test/test.dart';

void main() {
  group('AtKeyValueStore.snapshot() — Hive best-effort', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('snapshot_');
      factory = HiveAtPersistenceFactory();
      bundle = await factory.initialize(
        '@alice',
        HivePersistenceConfig.serverDefaults(
          storagePath: '${tempDir.path}/hive',
          commitLogPath: '${tempDir.path}/commitLog',
          accessLogPath: '${tempDir.path}/accessLog',
          notificationStoragePath: '${tempDir.path}/notification',
        ),
      );
    });

    tearDown(() async {
      await factory.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('Hive keystore reports supportsSnapshots == false', () {
      expect(bundle.keyValueStore.supportsSnapshots, isFalse);
    });

    test('snapshot() returns a usable handle', () async {
      await bundle.keyValueStore.put('public:k@alice', AtData()..data = 'v');
      final snap = await bundle.keyValueStore.snapshot();
      expect((await snap.get('public:k@alice'))?.data, 'v');
      final keys = await snap.scanKeys(KeyPattern()).toList();
      expect(keys, contains('public:k@alice'));
      await snap.release();
    });

    test(
        'best-effort: writes after snapshot ARE visible through the handle '
        '(Hive has no MVCC)', () async {
      await bundle.keyValueStore.put('public:k@alice', AtData()..data = 'v1');
      final snap = await bundle.keyValueStore.snapshot();
      expect((await snap.get('public:k@alice'))?.data, 'v1');
      // Mutate after the snapshot.
      await bundle.keyValueStore.put('public:k@alice', AtData()..data = 'v2');
      // Hive's best-effort impl: the snapshot reflects live state.
      expect((await snap.get('public:k@alice'))?.data, 'v2',
          reason: 'on Hive (supportsSnapshots == false), the snapshot '
              'observes live state');
      await snap.release();
    });

    test('release() is idempotent', () async {
      final snap = await bundle.keyValueStore.snapshot();
      await snap.release();
      await snap.release(); // second call doesn't throw
    });

    test('post-release reads throw StateError', () async {
      final snap = await bundle.keyValueStore.snapshot();
      await snap.release();
      expect(() => snap.get('public:k@alice'), throwsA(isA<StateError>()));
      expect(
          () => snap.scanKeys(KeyPattern()).first, throwsA(isA<StateError>()));
    });

    test('absent key via snapshot returns null (not throws)', () async {
      final snap = await bundle.keyValueStore.snapshot();
      expect(await snap.get('public:nope@alice'), isNull);
      await snap.release();
    });
  });

  group('AtNotificationKeystore.snapshot() — Hive best-effort', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('snapshot_notif_');
      factory = HiveAtPersistenceFactory();
      bundle = await factory.initialize(
        '@alice',
        HivePersistenceConfig.serverDefaults(
          storagePath: '${tempDir.path}/hive',
          commitLogPath: '${tempDir.path}/commitLog',
          accessLogPath: '${tempDir.path}/accessLog',
          notificationStoragePath: '${tempDir.path}/notification',
        ),
      );
    });

    tearDown(() async {
      await factory.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('reports supportsSnapshots == false', () {
      expect(bundle.notificationKeystore!.supportsSnapshots, isFalse);
    });

    test('snapshot returns a usable handle', () async {
      final notif = bundle.notificationKeystore!;
      final n = (AtNotificationBuilder()
            ..fromAtSign = '@alice'
            ..toAtSign = '@bob'
            ..notification = 'phone@bob')
          .build();
      await notif.put(n.id!, n);

      final snap = await notif.snapshot();
      expect(await snap.get(n.id!), isNotNull);
      await snap.release();
    });
  });
}
