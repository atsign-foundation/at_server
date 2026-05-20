import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() {
  group('AtKeyValueStore.getMany()', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('get_many_');
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
      Future<void> put(String k, String v) =>
          bundle.keyValueStore.put(k, AtData()..data = v);
      await put('public:phone.wavi@alice', '+1 555-0100');
      await put('public:email.wavi@alice', 'alice@example.com');
      await put('@bob:secret.wavi@alice', 'shhh');
    });

    tearDown(() async {
      await factory.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('returns values for every present key', () async {
      final result = await bundle.keyValueStore.getMany([
        'public:phone.wavi@alice',
        'public:email.wavi@alice',
        '@bob:secret.wavi@alice',
      ]);
      expect(result.length, 3);
      expect(result['public:phone.wavi@alice']?.data, '+1 555-0100');
      expect(result['public:email.wavi@alice']?.data, 'alice@example.com');
      expect(result['@bob:secret.wavi@alice']?.data, 'shhh');
    });

    test('absent keys are NOT in the result map', () async {
      final result = await bundle.keyValueStore.getMany([
        'public:phone.wavi@alice',
        'public:does_not_exist@alice',
      ]);
      expect(result.length, 1);
      expect(result.containsKey('public:phone.wavi@alice'), isTrue);
      expect(result.containsKey('public:does_not_exist@alice'), isFalse);
    });

    test('all-absent input yields empty map', () async {
      final result = await bundle.keyValueStore.getMany([
        'public:nope_a@alice',
        'public:nope_b@alice',
      ]);
      expect(result, isEmpty);
    });

    test('empty input yields empty map', () async {
      final result = await bundle.keyValueStore.getMany(<String>[]);
      expect(result, isEmpty);
    });

    test('case-insensitive lookup (matches get() behaviour)', () async {
      // Underlying storage is lowercased; mixed-case input still hits.
      final result = await bundle.keyValueStore.getMany([
        'PUBLIC:Phone.Wavi@alice',
      ]);
      expect(result.length, 1);
      expect(result.values.first.data, '+1 555-0100');
    });

    test('duplicate input keys are de-duplicated (Map semantics)', () async {
      // Two identical input keys → one map entry.
      final result = await bundle.keyValueStore.getMany([
        'public:phone.wavi@alice',
        'public:phone.wavi@alice',
      ]);
      expect(result.length, 1);
      expect(result.values.first.data, '+1 555-0100');
    });

    test('cheaper-than-N-individual-gets is observable as a single batch',
        () async {
      // Behavioural rather than perf — check getMany returns the same
      // values as N individual get() calls.
      final keys = [
        'public:phone.wavi@alice',
        'public:email.wavi@alice',
        '@bob:secret.wavi@alice',
      ];
      final viaMany = await bundle.keyValueStore.getMany(keys);
      final viaSingles = <String, AtData?>{};
      for (final k in keys) {
        try {
          viaSingles[k.toLowerCase()] = await bundle.keyValueStore.get(k);
        } on KeyNotFoundException {
          // skip
        }
      }
      expect(viaMany.length, viaSingles.length);
      for (final entry in viaMany.entries) {
        expect(viaSingles[entry.key]?.data, entry.value.data);
      }
    });
  });
}
