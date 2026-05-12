import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() {
  group('AtKeyValueStore.scanKeys() ordering + pagination', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('scan_order_');
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
      // Insert in non-alphabetical order so insertion-order vs
      // byKey-order can be told apart.
      Future<void> put(String k) =>
          bundle.keyValueStore.put(k, AtData()..data = 'v');
      await put('public:zebra@alice');
      await put('public:apple@alice');
      await put('public:mango@alice');
      await put('public:banana@alice');
    });

    tearDown(() async {
      await factory.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('default order yields every match (natural backend order)', () async {
      final keys = await bundle.keyValueStore.scanKeys(KeyPattern()).toList();
      // Hive's natural iteration order is the B-tree (key-bytes
      // ascending) — not insertion order. Verify every match is
      // present rather than asserting a specific order; the
      // byKey test below pins down the lexicographic shape.
      expect(keys.toSet(), {
        'public:apple@alice',
        'public:banana@alice',
        'public:mango@alice',
        'public:zebra@alice',
      });
    });

    test('orderBy: byKey returns lexicographic ascending', () async {
      final keys = await bundle.keyValueStore
          .scanKeys(KeyPattern(), orderBy: OrderByKey.byKey)
          .toList();
      expect(keys, [
        'public:apple@alice',
        'public:banana@alice',
        'public:mango@alice',
        'public:zebra@alice',
      ]);
    });

    test('limit caps the number of yielded keys', () async {
      final keys = await bundle.keyValueStore
          .scanKeys(KeyPattern(), orderBy: OrderByKey.byKey, limit: 2)
          .toList();
      expect(keys, ['public:apple@alice', 'public:banana@alice']);
    });

    test('skip discards the first N matching keys', () async {
      final keys = await bundle.keyValueStore
          .scanKeys(KeyPattern(), orderBy: OrderByKey.byKey, skip: 2)
          .toList();
      expect(keys, ['public:mango@alice', 'public:zebra@alice']);
    });

    test('skip + limit together yield a window', () async {
      final keys = await bundle.keyValueStore
          .scanKeys(
            KeyPattern(),
            orderBy: OrderByKey.byKey,
            skip: 1,
            limit: 2,
          )
          .toList();
      expect(keys, ['public:banana@alice', 'public:mango@alice']);
    });

    test('orderBy: byCreatedAt sorts by metadata createdAt', () async {
      // The AtMetadataBuilder always overwrites createdAt with
      // "now" on first insert (see at_metadata_builder.dart line 26)
      // — explicit values don't survive. So we pace the puts with
      // sleep-between-writes to spread createdAt across distinct
      // millisecond timestamps.
      await bundle.keyValueStore.removeMany([
        'public:apple@alice',
        'public:banana@alice',
        'public:mango@alice',
        'public:zebra@alice',
      ]);
      Future<void> spacedPut(String k) async {
        await bundle.keyValueStore.put(k, AtData()..data = 'v');
        await Future.delayed(const Duration(milliseconds: 5));
      }

      await spacedPut('public:zebra@alice'); // oldest
      await spacedPut('public:apple@alice');
      await spacedPut('public:mango@alice');
      await spacedPut('public:banana@alice'); // newest

      final keys = await bundle.keyValueStore
          .scanKeys(KeyPattern(), orderBy: OrderByKey.byCreatedAt)
          .toList();
      expect(keys, [
        'public:zebra@alice',
        'public:apple@alice',
        'public:mango@alice',
        'public:banana@alice',
      ]);
    });

    test('skip beyond match count yields empty', () async {
      final keys = await bundle.keyValueStore
          .scanKeys(KeyPattern(), orderBy: OrderByKey.byKey, skip: 100)
          .toList();
      expect(keys, isEmpty);
    });

    test('limit=0 yields empty', () async {
      final keys = await bundle.keyValueStore
          .scanKeys(KeyPattern(), orderBy: OrderByKey.byKey, limit: 0)
          .toList();
      expect(keys, isEmpty);
    });

    test('order + pattern compose: byKey filtered by namespace', () async {
      // Add a tasks-namespace key; it should sort independently.
      await bundle.keyValueStore
          .put('public:plan.tasks@alice', AtData()..data = 'v');
      final keys = await bundle.keyValueStore
          .scanKeys(
            KeyPattern(namespace: 'tasks'),
            orderBy: OrderByKey.byKey,
          )
          .toList();
      expect(keys, ['public:plan.tasks@alice']);
    });
  });
}
