import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() {
  group('SecondaryKeyStore.exists()', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('exists_');
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

    test('returns true for a key that has been put', () async {
      await bundle.keyStore.put('public:phone@alice', AtData()..data = '+1...');
      expect(await bundle.keyStore.exists('public:phone@alice'), isTrue);
    });

    test('returns false for a key that has never been written', () async {
      expect(await bundle.keyStore.exists('public:never@alice'), isFalse);
    });

    test('returns false after the key has been removed', () async {
      await bundle.keyStore
          .put('public:transient@alice', AtData()..data = 'temp');
      expect(await bundle.keyStore.exists('public:transient@alice'), isTrue);
      await bundle.keyStore.remove('public:transient@alice');
      expect(await bundle.keyStore.exists('public:transient@alice'), isFalse);
    });

    test('case-insensitive on the key (matches isKeyExists / get behaviour)',
        () async {
      // The keystore lower-cases keys before storing on disk; querying
      // with mixed case should still hit.
      await bundle.keyStore.put('public:Mixed@alice', AtData()..data = 'x');
      expect(await bundle.keyStore.exists('public:Mixed@alice'), isTrue);
      expect(await bundle.keyStore.exists('public:mixed@alice'), isTrue);
      expect(await bundle.keyStore.exists('PUBLIC:MIXED@alice'), isTrue);
    });

    test('agrees with isKeyExists() on every probe', () async {
      // exists() is documented as the async flavour of isKeyExists();
      // they must answer identically for any input. Both methods are
      // on the abstract SecondaryKeyStore so the test reaches them
      // without downcasting.
      await bundle.keyStore.put('public:k1@alice', AtData()..data = 'v1');
      for (final probe in [
        'public:k1@alice',
        'public:absent@alice',
        'public:K1@alice',
      ]) {
        expect(
          await bundle.keyStore.exists(probe),
          equals(bundle.keyStore.isKeyExists(probe)),
          reason: 'mismatch for probe "$probe"',
        );
      }
    });
  });

  group('AtNotificationKeystore.exists()', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('exists_notif_');
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

    test('returns true after put, false after remove', () async {
      final notif = bundle.notificationKeystore!;
      final n = (AtNotificationBuilder()
            ..fromAtSign = '@alice'
            ..toAtSign = '@bob'
            ..notification = 'phone@bob')
          .build();
      final id = n.id!;
      await notif.put(id, n);
      expect(await notif.exists(id), isTrue);
      await notif.remove(id);
      expect(await notif.exists(id), isFalse);
    });

    test('returns false for an id that has never been written', () async {
      final notif = bundle.notificationKeystore!;
      expect(await notif.exists('does-not-exist'), isFalse);
    });
  });
}
