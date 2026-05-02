import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() {
  group('SecondaryKeyStore.scanKeys()', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('scan_keys_');
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
      // Seed a representative spread of atKey shapes.
      Future<void> put(String k) =>
          bundle.keyStore.put(k, AtData()..data = 'v');
      await put('public:phone.wavi@alice');
      await put('public:email.wavi@alice');
      await put('@bob:secret.wavi@alice');
      await put('@bob:plan.tasks@alice');
      await put('@charlie:plan.tasks@alice');
      await put('private:apkam.__manage@alice');
    });

    tearDown(() async {
      await factory.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('unrestricted pattern yields every available key', () async {
      final keys = await bundle.keyStore.scanKeys(KeyPattern()).toList();
      expect(keys.length, 6);
    });

    test('filter by sharedBy', () async {
      final keys = await bundle.keyStore
          .scanKeys(KeyPattern(sharedBy: '@alice'))
          .toList();
      expect(keys.length, 6);
      // @bob isn't an owner here.
      final none = await bundle.keyStore
          .scanKeys(KeyPattern(sharedBy: '@bob'))
          .toList();
      expect(none, isEmpty);
    });

    test('filter by sharedWith', () async {
      final bobKeys = await bundle.keyStore
          .scanKeys(KeyPattern(sharedWith: '@bob'))
          .toList();
      expect(bobKeys.length, 2);
      expect(bobKeys, contains('@bob:secret.wavi@alice'));
      expect(bobKeys, contains('@bob:plan.tasks@alice'));

      final charlieKeys = await bundle.keyStore
          .scanKeys(KeyPattern(sharedWith: '@charlie'))
          .toList();
      expect(charlieKeys, ['@charlie:plan.tasks@alice']);
    });

    test('filter by namespace', () async {
      final waviKeys = await bundle.keyStore
          .scanKeys(KeyPattern(namespace: 'wavi'))
          .toList();
      expect(waviKeys.length, 3);
      expect(
          waviKeys.every((k) => k.contains('.wavi@')), isTrue,
          reason: 'every wavi key has .wavi@ in it');

      final tasksKeys = await bundle.keyStore
          .scanKeys(KeyPattern(namespace: 'tasks'))
          .toList();
      expect(tasksKeys.length, 2);
    });

    test('filter by idPrefix', () async {
      final pKeys = await bundle.keyStore
          .scanKeys(KeyPattern(idPrefix: 'p'))
          .toList();
      // 'phone', 'plan' (twice) — three keys whose id starts with 'p'.
      expect(pKeys.length, 3);
    });

    test('AND of multiple fields', () async {
      final keys = await bundle.keyStore
          .scanKeys(KeyPattern(sharedWith: '@bob', namespace: 'tasks'))
          .toList();
      expect(keys, ['@bob:plan.tasks@alice']);
    });

    test('no matches yields empty stream', () async {
      final keys = await bundle.keyStore
          .scanKeys(KeyPattern(namespace: 'nope_does_not_exist'))
          .toList();
      expect(keys, isEmpty);
    });

    test('public/self/private keys excluded when sharedWith filter set',
        () async {
      // None of the 'public:' or 'private:' seeded keys have sharedWith,
      // so a sharedWith filter must exclude them.
      final keys = await bundle.keyStore
          .scanKeys(KeyPattern(sharedWith: '@bob'))
          .toList();
      expect(keys, everyElement(startsWith('@bob:')));
      expect(keys, isNot(contains('public:phone.wavi@alice')));
    });

    test('case-insensitive on @sign comparison', () async {
      // @ALICE should match keys owned by @alice.
      final keys = await bundle.keyStore
          .scanKeys(KeyPattern(sharedBy: '@ALICE'))
          .toList();
      expect(keys.length, 6);
    });

    test('isKeyExists / exists / scanKeys all agree on a single key',
        () async {
      const k = 'public:phone.wavi@alice';
      expect(bundle.keyStore.isKeyExists(k), isTrue);
      expect(await bundle.keyStore.exists(k), isTrue);
      final hits = await bundle.keyStore
          .scanKeys(KeyPattern(idPrefix: 'phone'))
          .toList();
      expect(hits, contains(k));
    });
  });

  group('AtNotificationKeystore.scanKeys()', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('scan_keys_notif_');
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

    test('unrestricted yields every notification id', () async {
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

      final keys = await notif.scanKeys(KeyPattern()).toList();
      expect(keys, containsAll([n1.id, n2.id]));
    });

    test('atKey-shaped fields cannot match notification ids', () async {
      final notif = bundle.notificationKeystore!;
      final n = (AtNotificationBuilder()
            ..fromAtSign = '@alice'
            ..toAtSign = '@bob'
            ..notification = 'phone@bob')
          .build();
      await notif.put(n.id!, n);

      // sharedBy / sharedWith / namespace don't apply to notification
      // ids — scan returns empty.
      expect(
          await notif.scanKeys(KeyPattern(sharedBy: '@alice')).toList(),
          isEmpty);
      expect(
          await notif.scanKeys(KeyPattern(namespace: 'wavi')).toList(),
          isEmpty);
    });
  });
}
