import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() {
  group('SecondaryKeyStore.queryByPath() — Hive capability', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('querybypath_');
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

    test('Hive keystore reports supportsPathQueries == false', () {
      expect(bundle.keyStore.supportsPathQueries, isFalse);
    });

    test('Hive notification keystore reports supportsPathQueries == false',
        () {
      expect(bundle.notificationKeystore!.supportsPathQueries, isFalse);
    });

    test('queryByPath throws UnsupportedError on Hive (gating contract)',
        () {
      expect(
        () => bundle.keyStore.queryByPath(
          keyPattern: KeyPattern(),
          predicate: PathEquals(['obj', 'amount'], 100),
        ).first,
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('queryByPath on the notification keystore also throws', () {
      expect(
        () => bundle.notificationKeystore!.queryByPath(
          keyPattern: KeyPattern(),
          predicate: PathEquals(['anything'], 'x'),
        ).first,
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('Predicate AST round-trip: PathEquals + And + Or composition',
        () {
      // Smoke test that the AST builds without errors.
      final p = And([
        PathEquals(['obj', 'status'], 'unpaid'),
        Or([
          PathEquals(['obj', 'amount'], 100),
          PathEquals(['obj', 'amount'], 200),
        ]),
      ]);
      expect(p, isA<Predicate>());
      expect(p, isA<And>());
      expect((p as And).children.length, 2);
      expect(p.children[1], isA<Or>());
      expect((p.children[1] as Or).children.length, 2);
    });
  });
}
