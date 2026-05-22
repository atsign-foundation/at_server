import 'dart:async';
import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:test/test.dart';

/// A commit-log-free keystore is what `HivePersistenceConfig.clientDefaults`
/// produces: `enableCommitLog: false`, so the factory never wires a commit
/// log onto the keystore. Every write still succeeds — it just returns
/// `null` instead of a commit-log sequence number — and `compact()` is a
/// no-op. Isolation is per-test: each test gets a fresh factory + tmp dir.
void main() {
  group('commit-log-free keystore (clientDefaults)', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;
    late AtKeyValueStore<String, AtData, AtMetaData?> keyStore;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('commit_log_free_');
      factory = HiveAtPersistenceFactory();
      bundle = await factory.initialize(
        '@alice',
        HivePersistenceConfig.clientDefaults(
          storagePath: '${tempDir.path}/hive',
        ),
      );
      keyStore = bundle.keyValueStore;
    });

    tearDown(() async {
      await factory.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('the keystore has no commit log', () {
      expect(keyStore.commitLog, isNull);
    });

    test('create returns null and the value round-trips', () async {
      final result =
          await keyStore.create('phone.wavi@alice', AtData()..data = '123');
      expect(result, isNull);
      expect((await keyStore.get('phone.wavi@alice'))?.data, '123');
    });

    test('put (create then update) returns null and round-trips', () async {
      final created =
          await keyStore.put('city.wavi@alice', AtData()..data = 'london');
      expect(created, isNull);
      final updated =
          await keyStore.put('city.wavi@alice', AtData()..data = 'paris');
      expect(updated, isNull);
      expect((await keyStore.get('city.wavi@alice'))?.data, 'paris');
    });

    test('putAll returns null and metadata round-trips', () async {
      final result = await keyStore.putAll(
        'email.wavi@alice',
        AtData()..data = 'a@b.com',
        AtMetaData()..ttl = 60000,
      );
      expect(result, isNull);
      expect((await keyStore.getMeta('email.wavi@alice'))?.ttl, 60000);
    });

    test('putMeta returns null and updates metadata', () async {
      await keyStore.create('note.wavi@alice', AtData()..data = 'hi');
      final result =
          await keyStore.putMeta('note.wavi@alice', AtMetaData()..ttl = 30000);
      expect(result, isNull);
      expect((await keyStore.getMeta('note.wavi@alice'))?.ttl, 30000);
    });

    test('remove returns null and the key is gone', () async {
      await keyStore.create('temp.wavi@alice', AtData()..data = 'x');
      final result = await keyStore.remove('temp.wavi@alice');
      expect(result, isNull);
      expect(await keyStore.exists('temp.wavi@alice'), isFalse);
    });

    test('removeMany deletes without a commit log', () async {
      await keyStore.create('a.wavi@alice', AtData()..data = '1');
      await keyStore.create('b.wavi@alice', AtData()..data = '2');
      final removed =
          await keyStore.removeMany(['a.wavi@alice', 'b.wavi@alice']);
      expect(removed, 2);
      expect(await keyStore.exists('a.wavi@alice'), isFalse);
      expect(await keyStore.exists('b.wavi@alice'), isFalse);
    });

    test('compact yields nothing', () async {
      await keyStore.create('k.wavi@alice', AtData()..data = 'v');
      expect(await keyStore.compact(false).toList(), isEmpty);
    });

    test('changes stream still fires without a commit log', () async {
      final events = <KeyStoreChange>[];
      final sub = keyStore.changes.listen(events.add);
      await keyStore.create('watched.wavi@alice', AtData()..data = '1');
      await keyStore.put('watched.wavi@alice', AtData()..data = '2');
      await keyStore.remove('watched.wavi@alice');
      // Give the broadcast a microtask to flush.
      await Future.delayed(Duration.zero);
      await sub.cancel();
      expect(events, [isA<KeyAdded>(), isA<KeyUpdated>(), isA<KeyRemoved>()]);
    });
  });
}
