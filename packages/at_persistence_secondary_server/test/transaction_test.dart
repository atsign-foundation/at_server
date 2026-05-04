import 'dart:async';
import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() {
  group('SecondaryKeyStore.transaction()', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('txn_');
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

    test('successful body applies all buffered ops', () async {
      await bundle.keyStore.transaction((txn) async {
        await txn.put('public:a@alice', AtData()..data = 'one', AtMetaData());
        await txn.put('public:b@alice', AtData()..data = 'two', AtMetaData());
      });
      expect(await bundle.keyStore.exists('public:a@alice'), isTrue);
      expect(await bundle.keyStore.exists('public:b@alice'), isTrue);
      expect((await bundle.keyStore.get('public:a@alice'))?.data, 'one');
    });

    test('body throws → no ops applied, exception propagates', () async {
      // Pre-seed an unrelated key.
      await bundle.keyStore.put('public:c@alice', AtData()..data = 'three');

      Object? caught;
      try {
        await bundle.keyStore.transaction((txn) async {
          await txn.put('public:a@alice', AtData()..data = 'one', AtMetaData());
          await txn.remove('public:c@alice');
          throw StateError('rolling back');
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>());
      // Buffered put is NOT applied.
      expect(await bundle.keyStore.exists('public:a@alice'), isFalse);
      // Buffered remove is NOT applied — pre-seeded key stays.
      expect(await bundle.keyStore.exists('public:c@alice'), isTrue);
    });

    test('txn.get() reads buffered values', () async {
      await bundle.keyStore.transaction((txn) async {
        await txn.put('public:tmp@alice', AtData()..data = 'x', AtMetaData());
        // The buffered value is visible inside the txn — even though
        // the actual keystore hasn't been written yet.
        expect((await txn.get('public:tmp@alice'))?.data, 'x');
      });
    });

    test('txn.exists() honours buffered put / remove', () async {
      await bundle.keyStore.put('public:k@alice', AtData()..data = 'v');
      await bundle.keyStore.transaction((txn) async {
        // Pre-existing key is visible.
        expect(await txn.exists('public:k@alice'), isTrue);
        // Buffer a remove → exists returns false within the txn.
        await txn.remove('public:k@alice');
        expect(await txn.exists('public:k@alice'), isFalse);
        // Buffer a put for a fresh key → exists returns true.
        await txn.put(
            'public:fresh@alice', AtData()..data = 'vf', AtMetaData());
        expect(await txn.exists('public:fresh@alice'), isTrue);
      });
      // After the transaction, the buffered ops are applied.
      expect(await bundle.keyStore.exists('public:k@alice'), isFalse);
      expect(await bundle.keyStore.exists('public:fresh@alice'), isTrue);
    });

    test('changes events fire only on commit, not on body throw', () async {
      final events = <KeyStoreChange>[];
      final sub = bundle.keyStore.changes.listen(events.add);
      try {
        await bundle.keyStore.transaction((txn) async {
          await txn.put(
              'public:roll@alice', AtData()..data = 'never', AtMetaData());
          throw StateError('rolling back');
        });
      } catch (_) {/* expected */}
      await Future.delayed(Duration.zero);
      expect(events, isEmpty,
          reason: 'rolled-back txn should fire no changes events');

      // Now a successful txn → events fire.
      await bundle.keyStore.transaction((txn) async {
        await txn.put(
            'public:ok@alice', AtData()..data = 'committed', AtMetaData());
      });
      await Future.delayed(Duration.zero);
      await sub.cancel();
      expect(events.length, 1);
      expect(events.single.key, 'public:ok@alice');
    });

    test('latest op for a given key wins (put-then-remove → remove)', () async {
      await bundle.keyStore.put('public:rw@alice', AtData()..data = 'pre');
      await bundle.keyStore.transaction((txn) async {
        await txn.put('public:rw@alice', AtData()..data = 'mid', AtMetaData());
        await txn.remove('public:rw@alice');
      });
      // Final state: removed (the put inside the txn is overridden by
      // the subsequent remove, and the pre-existing value is then
      // also gone because remove was the committed op).
      expect(await bundle.keyStore.exists('public:rw@alice'), isFalse);
    });

    test('returns the body\'s value', () async {
      final n = await bundle.keyStore.transaction<int>((txn) async {
        await txn.put('public:n@alice', AtData()..data = 'one', AtMetaData());
        return 42;
      });
      expect(n, 42);
    });
  });

  group('AtNotificationKeystore.transaction()', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('txn_notif_');
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

    test('successful body applies notification put + remove', () async {
      final notif = bundle.notificationKeystore!;
      final n = (AtNotificationBuilder()
            ..fromAtSign = '@alice'
            ..toAtSign = '@bob'
            ..notification = 'phone@bob')
          .build();
      await notif.put(n.id!, n);

      final m = (AtNotificationBuilder()
            ..fromAtSign = '@alice'
            ..toAtSign = '@charlie'
            ..notification = 'email@charlie')
          .build();

      await notif.transaction((txn) async {
        await txn.put(m.id, m, null);
        await txn.remove(n.id!);
      });
      expect(await notif.exists(m.id!), isTrue);
      expect(await notif.exists(n.id!), isFalse);
    });
  });
}
