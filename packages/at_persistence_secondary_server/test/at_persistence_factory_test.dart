import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:test/test.dart';

/// Builds a fresh [HivePersistenceConfig] under a unique tmp dir so each
/// test starts with empty backend storage.
Future<({HivePersistenceConfig config, Directory tmp})> _newConfig(
    String testName) async {
  final tmp =
      await Directory.systemTemp.createTemp('at_persistence_factory_test_');
  final config = HivePersistenceConfig(
    storagePath: '${tmp.path}/hive',
    commitLogPath: '${tmp.path}/commitLog',
    accessLogPath: '${tmp.path}/accessLog',
    notificationStoragePath: '${tmp.path}/notificationLog',
  );
  return (config: config, tmp: tmp);
}

void main() {
  group('HiveAtPersistenceFactory', () {
    test('initialize wires every store', () async {
      final cfg = await _newConfig('init');
      final factory = HiveAtPersistenceFactory();
      try {
        final bundle = await factory.initialize('@alice', cfg.config);

        expect(bundle.atSign, '@alice');
        expect(bundle.backendId, AtPersistenceBackendId.hive);
        expect(bundle.keyValueStore, isNotNull);
        expect(bundle.keyValueStore.commitLog!, isNotNull);
        expect(bundle.accessLog, isNotNull);
        expect(bundle.notificationKeystore, isNotNull);

        // Round-trip a key through the keystore to prove it's actually open.
        final atData = AtData()..data = 'hello';
        final commitId =
            await bundle.keyValueStore.put('public:greet@alice', atData);
        expect(commitId, isNotNull);
        final fetched = await bundle.keyValueStore.get('public:greet@alice');
        expect(fetched?.data, 'hello');
      } finally {
        await factory.close();
        await cfg.tmp.delete(recursive: true);
      }
    });

    test('initialize is idempotent for the same atSign', () async {
      final cfg = await _newConfig('idempotent');
      final factory = HiveAtPersistenceFactory();
      try {
        final a = await factory.initialize('@alice', cfg.config);
        final b = await factory.initialize('@alice', cfg.config);
        expect(identical(a, b), isTrue);
        expect(factory.bundleFor('@alice'), same(a));
      } finally {
        await factory.close();
        await cfg.tmp.delete(recursive: true);
      }
    });

    test('bundleFor returns null before initialize, the bundle after',
        () async {
      final cfg = await _newConfig('bundleFor');
      final factory = HiveAtPersistenceFactory();
      try {
        expect(factory.bundleFor('@alice'), isNull);
        final bundle = await factory.initialize('@alice', cfg.config);
        expect(factory.bundleFor('@alice'), same(bundle));
        expect(factory.bundleFor('@bob'), isNull);
      } finally {
        await factory.close();
        await cfg.tmp.delete(recursive: true);
      }
    });

    test('two atSigns get independent bundles with independent stores',
        () async {
      final aliceCfg = await _newConfig('alice');
      final bobCfg = await _newConfig('bob');
      final factory = HiveAtPersistenceFactory();
      try {
        final alice = await factory.initialize('@alice', aliceCfg.config);
        final bob = await factory.initialize('@bob', bobCfg.config);

        expect(alice.atSign, '@alice');
        expect(bob.atSign, '@bob');
        expect(identical(alice.keyValueStore, bob.keyValueStore), isFalse);
        expect(
            identical(
                alice.keyValueStore.commitLog, bob.keyValueStore.commitLog),
            isFalse);
        expect(identical(alice.accessLog, bob.accessLog), isFalse);
        expect(identical(alice.notificationKeystore, bob.notificationKeystore),
            isFalse);

        // Writing into alice's keystore must not affect bob's.
        await alice.keyValueStore
            .put('public:k@alice', AtData()..data = 'a-value');
        expect(() => bob.keyValueStore.get('public:k@alice'),
            throwsA(isA<KeyNotFoundException>()));
      } finally {
        await factory.close();
        await aliceCfg.tmp.delete(recursive: true);
        await bobCfg.tmp.delete(recursive: true);
      }
    });

    test('two factory instances coexist when initialised for different atSigns',
        () async {
      // A backend-migration scenario keeps a "source" factory (e.g.
      // hive) and a "destination" factory (e.g. postgres) alive
      // concurrently. Factory-level lifecycle is independent — we
      // exercise that with two factory instances over two different
      // atSigns, even though only the Hive backend ships today.
      // (Two factories sharing the same atSign with Hive specifically
      // can't be independent because Hive boxes are keyed by
      // sha(atSign) globally — a Hive constraint, not a factory
      // constraint; a real migration uses different backends so
      // they don't collide.)
      final aliceCfg = await _newConfig('coexist-alice');
      final bobCfg = await _newConfig('coexist-bob');
      final factoryA = HiveAtPersistenceFactory();
      final factoryB = HiveAtPersistenceFactory();
      try {
        final alice = await factoryA.initialize('@alice', aliceCfg.config);
        final bob = await factoryB.initialize('@bob', bobCfg.config);

        expect(identical(alice, bob), isFalse);
        expect(identical(alice.keyValueStore, bob.keyValueStore), isFalse);

        // Each factory only knows about its own atSign.
        expect(factoryA.bundleFor('@alice'), same(alice));
        expect(factoryA.bundleFor('@bob'), isNull);
        expect(factoryB.bundleFor('@bob'), same(bob));
        expect(factoryB.bundleFor('@alice'), isNull);

        // Closing one factory does not affect the other.
        await factoryA.close();
        expect(factoryA.bundleFor('@alice'), isNull);
        expect(factoryB.bundleFor('@bob'), same(bob));
      } finally {
        await factoryA.close();
        await factoryB.close();
        await aliceCfg.tmp.delete(recursive: true);
        await bobCfg.tmp.delete(recursive: true);
      }
    });

    test('close is idempotent and a fresh initialize works after close',
        () async {
      final cfg = await _newConfig('rerun');
      final factory = HiveAtPersistenceFactory();
      try {
        final first = await factory.initialize('@alice', cfg.config);
        expect(factory.bundleFor('@alice'), same(first));
        await factory.close();
        await factory.close(); // second close — must not throw
        expect(factory.bundleFor('@alice'), isNull);

        final second = await factory.initialize('@alice', cfg.config);
        expect(identical(first, second), isFalse);
        expect(second.atSign, '@alice');
      } finally {
        await factory.close();
        await cfg.tmp.delete(recursive: true);
      }
    });

    test('initialize rejects a config that does not match backendId', () async {
      final factory = HiveAtPersistenceFactory();
      expect(() => factory.initialize('@alice', _NotHiveConfig()),
          throwsA(isA<ArgumentError>()));
    });

    test('closing a bundle directly removes it from factory bookkeeping',
        () async {
      final cfg = await _newConfig('direct-close');
      final factory = HiveAtPersistenceFactory();
      try {
        final first = await factory.initialize('@alice', cfg.config);
        expect(first.isClosed, isFalse);
        expect(factory.bundleFor('@alice'), same(first));

        // Caller closes the bundle directly, bypassing factory.close /
        // factory.closeFor. The factory must not keep handing out the
        // closed reference, and initialize must rebuild.
        await first.close();
        expect(first.isClosed, isTrue);
        expect(factory.bundleFor('@alice'), isNull);

        final second = await factory.initialize('@alice', cfg.config);
        expect(identical(first, second), isFalse);
        expect(second.isClosed, isFalse);
      } finally {
        await factory.close();
        await cfg.tmp.delete(recursive: true);
      }
    });

    test('closeFor closes a single bundle and drops the reference', () async {
      final cfgA = await _newConfig('closeFor-alice');
      final cfgB = await _newConfig('closeFor-bob');
      final factory = HiveAtPersistenceFactory();
      try {
        final alice = await factory.initialize('@alice', cfgA.config);
        final bob = await factory.initialize('@bob', cfgB.config);

        await factory.closeFor('@alice');
        expect(alice.isClosed, isTrue);
        expect(factory.bundleFor('@alice'), isNull);
        // Bob is untouched.
        expect(bob.isClosed, isFalse);
        expect(factory.bundleFor('@bob'), same(bob));

        // closeFor on an unknown atSign is a no-op.
        await factory.closeFor('@nobody');
      } finally {
        await factory.close();
        await cfgA.tmp.delete(recursive: true);
        await cfgB.tmp.delete(recursive: true);
      }
    });
  });

  group('HivePersistenceConfig', () {
    test('reports backendId == hive', () {
      final c = HivePersistenceConfig(
        storagePath: '/x/hive',
        commitLogPath: '/x/commitLog',
        accessLogPath: '/x/accessLog',
        notificationStoragePath: '/x/notificationLog',
      );
      expect(c.backend, AtPersistenceBackendId.hive);
    });

    test('backendMarkerPath defaults next to storagePath', () {
      final c = HivePersistenceConfig(
        storagePath: '/x/hive',
        commitLogPath: '/x/commitLog',
        accessLogPath: '/x/accessLog',
        notificationStoragePath: '/x/notificationLog',
      );
      expect(c.backendMarkerPath, '/x/hive/.persistence_backend');
    });

    test('backendMarkerPath honoured when explicit', () {
      final c = HivePersistenceConfig(
        storagePath: '/x/hive',
        commitLogPath: '/x/commitLog',
        accessLogPath: '/x/accessLog',
        notificationStoragePath: '/x/notificationLog',
        backendMarkerPath: '/elsewhere/marker',
      );
      expect(c.backendMarkerPath, '/elsewhere/marker');
    });
  });
}

class _NotHiveConfig implements AtPersistenceConfig {
  @override
  AtPersistenceBackendId get backend => throw UnimplementedError(); // not Hive
  @override
  String get storagePath => '/tmp';
  @override
  String get commitLogPath => '/tmp';
  @override
  String get accessLogPath => '/tmp';
  @override
  String get notificationStoragePath => '/tmp';
  @override
  String get backendMarkerPath => '/tmp/marker';
  @override
  bool get enableAccessLog => true;
  @override
  bool get enableNotificationKeystore => true;
  @override
  bool get enableCommitLog => true;
}
