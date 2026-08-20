import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:test/test.dart';

/// Caller-asserted timestamps ([AtAssertedTimestamps]) through the metadata
/// builder and both keystore backends: an asserted value is stored
/// faithfully; an absent one leaves every derivation exactly as it was.
void main() {
  final cAt = DateTime.utc(2020, 1, 2, 3, 4, 5, 678);
  final uAt = DateTime.utc(2021, 2, 3, 4, 5, 6, 789);
  final aAt = DateTime.utc(2022, 3, 4, 5, 6, 7, 890);

  group('AtMetadataBuilder with asserted timestamps', () {
    test('asserted createdAt wins over an existing record\'s createdAt', () {
      final existing = AtMetaData()..createdAt = DateTime.utc(2019, 6, 1);
      final built = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData(),
        existingMetaData: existing,
        asserted: AtAssertedTimestamps(createdAt: cAt),
      ).build();
      expect(built.createdAt, cAt,
          reason: 'an explicit cAt assertion overwrites stored createdAt');
    });

    test('without an assertion, existing createdAt is preserved', () {
      final existing = AtMetaData()..createdAt = DateTime.utc(2019, 6, 1);
      final built = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData(),
        existingMetaData: existing,
      ).build();
      expect(built.createdAt, DateTime.utc(2019, 6, 1));
    });

    test('asserted updatedAt wins; absent means stamped now', () {
      final before = DateTime.now().toUtcMillisecondsPrecision();
      final asserted = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData(),
        asserted: AtAssertedTimestamps(updatedAt: uAt),
      ).build();
      expect(asserted.updatedAt, uAt);

      final stamped = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData(),
      ).build();
      final after = DateTime.now().toUtcMillisecondsPrecision();
      expect(stamped.updatedAt!.isBefore(before), isFalse);
      expect(stamped.updatedAt!.isAfter(after), isFalse);
    });

    test('asserted expiresAt suppresses the ttl derivation at this write', () {
      final eAt = DateTime.utc(2030, 1, 1);
      final built = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData()..ttl = 60000,
        asserted: AtAssertedTimestamps(expiresAt: eAt),
      ).build();
      expect(built.expiresAt, eAt,
          reason: 'derivation from ttl would restart the expiry clock, which '
              'is exactly what a faithful transfer must avoid');
      expect(built.ttl, 60000, reason: 'ttl itself is still stored');
    });

    test('asserted expiresAt survives ttl:0 (which otherwise clears expiry)',
        () {
      final eAt = DateTime.utc(2030, 1, 1);
      final built = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData()..ttl = 0,
        asserted: AtAssertedTimestamps(expiresAt: eAt),
      ).build();
      expect(built.expiresAt, eAt);

      final cleared = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData()..ttl = 0,
      ).build();
      expect(cleared.expiresAt, isNull,
          reason: 'without an assertion ttl:0 still clears expiry');
    });

    test('asserted availableAt suppresses the ttb derivation at this write',
        () {
      final built = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData()..ttb = 60000,
        asserted: AtAssertedTimestamps(availableAt: aAt),
      ).build();
      expect(built.availableAt, aAt);
      expect(built.ttb, 60000);
    });

    test('assertions are truncated to millisecond precision', () {
      final micros = DateTime.utc(2020, 1, 2, 3, 4, 5, 678, 901);
      final t = AtAssertedTimestamps(
          createdAt: micros,
          updatedAt: micros,
          expiresAt: micros,
          availableAt: micros);
      final expected = DateTime.utc(2020, 1, 2, 3, 4, 5, 678);
      expect(t.createdAt, expected);
      expect(t.updatedAt, expected);
      expect(t.expiresAt, expected);
      expect(t.availableAt, expected);
    });
  });

  for (final backend in ['hive', 'sqlite']) {
    group('$backend keystore with asserted timestamps', () {
      late Directory tempDir;
      late AtPersistenceFactory factory;
      late AtKeyValueStore<String, AtData, AtMetaData?> keyStore;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('asserted_ts_');
        final AtPersistenceBundle bundle;
        if (backend == 'hive') {
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
        } else {
          factory = SqliteAtPersistenceFactory();
          bundle = await factory.initialize(
            '@alice',
            SqlitePersistenceConfig.serverDefaults(
                storagePath: '${tempDir.path}/sqlite'),
          );
        }
        keyStore = bundle.keyValueStore;
      });

      tearDown(() async {
        await factory.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      test('put stores asserted createdAt/updatedAt faithfully', () async {
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1',
            assertedTimestamps:
                AtAssertedTimestamps(createdAt: cAt, updatedAt: uAt));
        final meta = await keyStore.getMeta('phone.wavi@alice');
        expect(meta!.createdAt, cAt);
        expect(meta.updatedAt, uAt);
      });

      test('asserted createdAt overwrites an existing record\'s createdAt',
          () async {
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1');
        final original = (await keyStore.getMeta('phone.wavi@alice'))!;
        expect(original.createdAt, isNot(cAt));

        await keyStore.put('phone.wavi@alice', AtData()..data = 'v2',
            assertedTimestamps: AtAssertedTimestamps(createdAt: cAt));
        final meta = (await keyStore.getMeta('phone.wavi@alice'))!;
        expect(meta.createdAt, cAt);
      });

      test('without assertions an update keeps createdAt and re-stamps '
          'updatedAt', () async {
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1',
            assertedTimestamps:
                AtAssertedTimestamps(createdAt: cAt, updatedAt: uAt));
        final before = DateTime.now().toUtcMillisecondsPrecision();
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v2');
        final meta = (await keyStore.getMeta('phone.wavi@alice'))!;
        expect(meta.createdAt, cAt,
            reason: 'createdAt is preserved from the existing record');
        expect(meta.updatedAt!.isBefore(before), isFalse,
            reason: 'updatedAt is re-stamped when not asserted');
      });

      test('asserted expiresAt beats ttl derivation; a later ttl write '
          're-derives', () async {
        final eAt = DateTime.now()
            .add(Duration(days: 30))
            .toUtcMillisecondsPrecision();
        await keyStore.put(
            'phone.wavi@alice', AtData()..data = 'v1'..metaData = (AtMetaData()..ttl = 86400000),
            assertedTimestamps: AtAssertedTimestamps(expiresAt: eAt));
        var meta = (await keyStore.getMeta('phone.wavi@alice'))!;
        expect(meta.expiresAt, eAt);
        expect(meta.ttl, 86400000);

        // A later write that supplies ttl WITHOUT an assertion derives
        // from now as always.
        final before = DateTime.now().toUtcMillisecondsPrecision();
        await keyStore.put('phone.wavi@alice',
            AtData()..data = 'v2'..metaData = (AtMetaData()..ttl = 86400000));
        meta = (await keyStore.getMeta('phone.wavi@alice'))!;
        expect(meta.expiresAt, isNot(eAt));
        expect(meta.expiresAt!.isAfter(before), isTrue);
      });

      test('a record with asserted expiresAt and no ttl actually expires',
          () async {
        final eAt = DateTime.now().add(Duration(milliseconds: 150));
        await keyStore.put('otp.wavi@alice', AtData()..data = 'v1',
            assertedTimestamps: AtAssertedTimestamps(expiresAt: eAt));
        expect(await keyStore.exists('otp.wavi@alice'), isTrue);
        expect(await keyStore.nextExpiresAt(), isNotNull,
            reason: 'the expiry machinery must see an asserted expiresAt '
                'even though no ttl is set — otherwise the key is immortal');

        await Future.delayed(Duration(milliseconds: 300));
        final expired = await (await keyStore.getExpiredKeys()).toList();
        expect(expired, contains('otp.wavi@alice'),
            reason: 'the expiry sweep must include a key whose only expiry '
                'signal is an asserted expiresAt');
        await keyStore.deleteExpiredKeys();
        expect(await keyStore.exists('otp.wavi@alice'), isFalse);
      });

      test('asserted availableAt is stored faithfully', () async {
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1',
            assertedTimestamps: AtAssertedTimestamps(availableAt: aAt));
        final meta = (await keyStore.getMeta('phone.wavi@alice'))!;
        expect(meta.availableAt, aAt);
      });

      test('putMeta stores asserted timestamps faithfully', () async {
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1');
        await keyStore.putMeta('phone.wavi@alice', AtMetaData(),
            assertedTimestamps:
                AtAssertedTimestamps(createdAt: cAt, updatedAt: uAt));
        final meta = (await keyStore.getMeta('phone.wavi@alice'))!;
        expect(meta.createdAt, cAt);
        expect(meta.updatedAt, uAt);
      });

      test('create stores asserted timestamps faithfully', () async {
        await keyStore.create('phone.wavi@alice', AtData()..data = 'v1',
            assertedTimestamps:
                AtAssertedTimestamps(createdAt: cAt, updatedAt: uAt));
        final meta = (await keyStore.getMeta('phone.wavi@alice'))!;
        expect(meta.createdAt, cAt);
        expect(meta.updatedAt, uAt);
      });
    });
  }
}
