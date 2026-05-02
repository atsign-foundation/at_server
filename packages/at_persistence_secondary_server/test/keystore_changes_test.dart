import 'dart:async';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() {
  group('SecondaryKeyStore.changes', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('changes_');
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

    /// Listen to `changes` and capture events emitted while [op] runs,
    /// then return them in order.
    Future<List<KeyStoreChange>> capture(
        Future<void> Function() op) async {
      final events = <KeyStoreChange>[];
      final sub = bundle.keyStore.changes.listen(events.add);
      await op();
      // Give the broadcast a microtask to flush.
      await Future.delayed(Duration.zero);
      await sub.cancel();
      return events;
    }

    test('first put on a key emits KeyAdded', () async {
      final events = await capture(() async {
        await bundle.keyStore.put('public:phone@alice', AtData()..data = 'v');
      });
      expect(events.length, 1);
      expect(events.single, isA<KeyAdded>());
      expect(events.single.key, 'public:phone@alice');
    });

    test('put on an existing key emits KeyUpdated', () async {
      await bundle.keyStore.put('public:phone@alice', AtData()..data = 'v1');
      final events = await capture(() async {
        await bundle.keyStore.put('public:phone@alice', AtData()..data = 'v2');
      });
      expect(events.length, 1);
      expect(events.single, isA<KeyUpdated>());
    });

    test('remove on a present key emits KeyRemoved', () async {
      await bundle.keyStore.put('public:gone@alice', AtData()..data = 'v');
      final events = await capture(() async {
        await bundle.keyStore.remove('public:gone@alice');
      });
      expect(events.length, 1);
      expect(events.single, isA<KeyRemoved>());
      expect(events.single.key, 'public:gone@alice');
    });

    test('removeMany emits one KeyRemoved per actually-removed key',
        () async {
      await bundle.keyStore.put('public:a@alice', AtData()..data = 'v');
      await bundle.keyStore.put('public:b@alice', AtData()..data = 'v');
      final events = await capture(() async {
        await bundle.keyStore.removeMany([
          'public:a@alice',
          'public:b@alice',
          'public:absent@alice',
        ]);
      });
      // Two KeyRemoveds (for a and b); the absent key gets nothing.
      expect(events.length, 2);
      expect(events.every((e) => e is KeyRemoved), isTrue);
      expect(events.map((e) => e.key).toSet(),
          {'public:a@alice', 'public:b@alice'});
    });

    test('multiple subscribers each receive every event independently',
        () async {
      final eventsA = <KeyStoreChange>[];
      final eventsB = <KeyStoreChange>[];
      final subA = bundle.keyStore.changes.listen(eventsA.add);
      final subB = bundle.keyStore.changes.listen(eventsB.add);

      await bundle.keyStore.put('public:multi@alice', AtData()..data = 'v');
      await bundle.keyStore.remove('public:multi@alice');
      await Future.delayed(Duration.zero);

      await subA.cancel();
      await subB.cancel();

      expect(eventsA.length, 2);
      expect(eventsB.length, 2);
      expect(eventsA.first, isA<KeyAdded>());
      expect(eventsA.last, isA<KeyRemoved>());
    });

    test('late subscribers do not see prior events (broadcast semantics)',
        () async {
      // Mutate before any subscriber attaches.
      await bundle.keyStore.put('public:early@alice', AtData()..data = 'v');

      final events = await capture(() async {
        // Fresh subscription; no event seen for the prior put.
        await bundle.keyStore.put('public:late@alice', AtData()..data = 'v');
      });
      expect(events.length, 1);
      expect(events.single.key, 'public:late@alice');
    });
  });

  group('AtNotificationKeystore.changes', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('changes_notif_');
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

    test('put / remove cycle emits the right events', () async {
      final notif = bundle.notificationKeystore!;
      final events = <KeyStoreChange>[];
      final sub = notif.changes.listen(events.add);

      final n = (AtNotificationBuilder()
            ..fromAtSign = '@alice'
            ..toAtSign = '@bob'
            ..notification = 'phone@bob')
          .build();
      await notif.put(n.id!, n);
      await notif.remove(n.id!);
      await Future.delayed(Duration.zero);
      await sub.cancel();

      expect(events.length, 2);
      expect(events.first, isA<KeyAdded>());
      expect(events.last, isA<KeyRemoved>());
    });
  });
}
