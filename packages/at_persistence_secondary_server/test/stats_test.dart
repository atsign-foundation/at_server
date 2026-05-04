import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() {
  group('SecondaryKeyStore.stats()', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('stats_');
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

    test('empty keystore yields zero counts and null timestamps', () async {
      final s = await bundle.keyStore.stats();
      expect(s.totalKeys, 0);
      expect(s.ttlKeys, 0);
      expect(s.ttbKeys, 0);
      expect(s.oldestCreatedAt, isNull);
      expect(s.newestCreatedAt, isNull);
    });

    test('totalKeys reflects every key, including TTL and TTB ones', () async {
      await bundle.keyStore.put('public:a@alice', AtData()..data = 'v');
      await bundle.keyStore.put(
          'public:b@alice',
          AtData()
            ..data = 'v'
            ..metaData = (AtMetaData()..ttl = 60000));
      await bundle.keyStore.put(
          'public:c@alice',
          AtData()
            ..data = 'v'
            ..metaData = (AtMetaData()..ttb = 30000));
      final s = await bundle.keyStore.stats();
      expect(s.totalKeys, 3);
      expect(s.ttlKeys, 1);
      expect(s.ttbKeys, 1);
    });

    test('oldest/newest createdAt span all entries', () async {
      await bundle.keyStore.put('public:a@alice', AtData()..data = 'v');
      await Future.delayed(const Duration(milliseconds: 10));
      await bundle.keyStore.put('public:b@alice', AtData()..data = 'v');
      final s = await bundle.keyStore.stats();
      expect(s.oldestCreatedAt, isNotNull);
      expect(s.newestCreatedAt, isNotNull);
      expect(s.oldestCreatedAt!.isBefore(s.newestCreatedAt!), isTrue);
    });

    test('sizeBytes is zero on Hive (not reported)', () async {
      await bundle.keyStore.put('public:a@alice', AtData()..data = 'v');
      final s = await bundle.keyStore.stats();
      expect(s.sizeBytes, 0,
          reason:
              'Hive impl leaves sizeBytes at 0 — SQL backends report exact');
    });
  });

  group('AtNotificationKeystore.stats()', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('stats_notif_');
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

    test('counts notifications + reports ttbKeys==0', () async {
      // AtNotificationBuilder defaults ttl to AtNotification.defaultTtl,
      // so every built notification has non-null ttl regardless of
      // whether the caller set it. Test asserts on totalKeys (exact)
      // and ttbKeys (always 0 for notifications).
      final notif = bundle.notificationKeystore!;
      final n1 = (AtNotificationBuilder()
            ..fromAtSign = '@alice'
            ..toAtSign = '@bob'
            ..notification = 'phone@bob')
          .build();
      final n2 = (AtNotificationBuilder()
            ..fromAtSign = '@alice'
            ..toAtSign = '@charlie'
            ..notification = 'email@charlie')
          .build();
      await notif.put(n1.id!, n1);
      await notif.put(n2.id!, n2);
      final s = await notif.stats();
      expect(s.totalKeys, 2);
      expect(s.ttlKeys, greaterThan(0));
      // Notifications have no ttb concept.
      expect(s.ttbKeys, 0);
    });
  });
}
