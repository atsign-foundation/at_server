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
      expect(built.ttl, 0,
          reason: 'without deriveTtl the builder must not touch the '
              'metadata\'s ttl — deciding that a 0 means "unsupplied" is '
              'the request layer\'s call, made via the deriveTtl flag');

      final derived = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData()..ttl = 0,
        asserted: AtAssertedTimestamps(expiresAt: eAt, deriveTtl: true),
      ).build();
      expect(derived.ttl, eAt.difference(derived.updatedAt!).inMilliseconds,
          reason: 'with deriveTtl (set by the request layer when the json '
              'path\'s coerced ttl:0 accompanies an asserted expiry) the '
              'implied ttl replaces the 0');

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

    test('an asserted expiresAt with deriveTtl derives and stores the ttl '
        'it implies', () {
      final eAt = DateTime.utc(2030, 1, 1);
      final built = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData(),
        asserted: AtAssertedTimestamps(
            updatedAt: uAt, expiresAt: eAt, deriveTtl: true),
      ).build();
      expect(built.expiresAt, eAt);
      expect(built.ttl, eAt.difference(uAt).inMilliseconds,
          reason: 'a record with an absolute expiry also carries the ttl it '
              'implies — measured from the stored updatedAt, so every server '
              'derives the same value from the same assertions');
    });

    test('deriveTtl replaces a ttl the write\'s metadata carries', () {
      // The metadata's ttl may be a stale value the verb layer retained
      // from the stored record; the caller set deriveTtl because its own
      // request supplied no ttl, and the derivation must win.
      final eAt = DateTime.utc(2030, 1, 1);
      final built = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData()..ttl = 86400000,
        asserted: AtAssertedTimestamps(
            updatedAt: uAt, expiresAt: eAt, deriveTtl: true),
      ).build();
      expect(built.ttl, eAt.difference(uAt).inMilliseconds,
          reason: 'a stale retained ttl stored beside a fresh asserted '
              'expiresAt would contradict it, and any consumer re-deriving '
              'expiry from that ttl would restart the expiry clock');
    });

    test('an asserted availableAt with deriveTtb derives and stores the ttb '
        'it implies', () {
      final built = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData(),
        asserted: AtAssertedTimestamps(
            updatedAt: uAt, availableAt: aAt, deriveTtb: true),
      ).build();
      expect(built.availableAt, aAt);
      expect(built.ttb, aAt.difference(uAt).inMilliseconds);
    });

    test('with availableAt and expiresAt both asserted, ttl spans '
        'birth-to-expiry', () {
      final eAt = DateTime.utc(2030, 1, 1);
      final built = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData(),
        asserted: AtAssertedTimestamps(
            updatedAt: uAt,
            availableAt: aAt,
            expiresAt: eAt,
            deriveTtl: true,
            deriveTtb: true),
      ).build();
      expect(built.ttb, aAt.difference(uAt).inMilliseconds);
      expect(built.ttl, eAt.difference(aAt).inMilliseconds,
          reason: 'forward, expiresAt = now + ttb + ttl — a record lives '
              'ttl ms from when it becomes available — so the inverse '
              'measures ttl from availableAt');
    });

    test('the derivation ignores an availableAt that setTTB(0) manufactured',
        () {
      // A coerced ttb:0 (how "no ttb" arrives from update:json and from
      // the notify wire layer) makes setTTB stamp availableAt to this
      // server's clock. That manufactured availableAt is NOT an asserted
      // birth: it must neither become the base of the ttl derivation
      // (which would store expiresAt - arrival-time instead of the
      // reproducible expiresAt - updatedAt) nor spawn a fabricated ttb.
      final eAt = DateTime.utc(2030, 1, 1);
      final built = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData()..ttb = 0,
        asserted: AtAssertedTimestamps(
            updatedAt: uAt, expiresAt: eAt, deriveTtl: true),
      ).build();
      expect(built.ttl, eAt.difference(uAt).inMilliseconds,
          reason: 'the ttl derivation must measure from the asserted '
              'updatedAt, not from the availableAt setTTB(0) stamped from '
              'this server\'s clock');
      expect(built.ttb, 0,
          reason: 'no aAt was asserted and deriveTtb was not requested, so '
              'the ttb must stay exactly as the metadata carried it — a '
              'positive ttb here would be fabricated from transfer latency');
    });

    test('a non-positive derived ttl/ttb clears the relative', () {
      // updatedAt asserted at-or-after the absolutes — e.g. a transfer
      // from a server whose clock runs ahead. The absolutes are stored
      // faithfully; the implied relatives are non-positive, and a ttl of 0
      // would mean "never expires", so the relatives are cleared to null
      // (a retained value would contradict the asserted absolute).
      final past = DateTime.utc(2019, 1, 1);
      final built = AtMetadataBuilder(
        atSign: '@alice',
        newAtMetaData: AtMetaData()..ttl = 86400000,
        asserted: AtAssertedTimestamps(
            updatedAt: uAt,
            availableAt: past,
            expiresAt: past,
            deriveTtl: true,
            deriveTtb: true),
      ).build();
      expect(built.expiresAt, past);
      expect(built.availableAt, past);
      expect(built.ttl, isNull);
      expect(built.ttb, isNull);
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

      test('put with asserted expiresAt and deriveTtl stores the derived ttl',
          () async {
        final eAt = DateTime.utc(2030, 1, 1);
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1',
            assertedTimestamps: AtAssertedTimestamps(
                updatedAt: uAt, expiresAt: eAt, deriveTtl: true));
        final meta = (await keyStore.getMeta('phone.wavi@alice'))!;
        expect(meta.expiresAt, eAt);
        expect(meta.ttl, eAt.difference(uAt).inMilliseconds);
      });

      test('a record with asserted expiresAt and no ttl actually expires',
          () async {
        // The only reachable expiresAt-without-ttl state: the implied ttl
        // is non-positive (updatedAt asserted at-or-after expiresAt — a
        // transfer from a clock that runs ahead), so the derivation clears
        // it. The expiry machinery must still see such a record —
        // otherwise it is immortal.
        final eAt = DateTime.now().add(Duration(milliseconds: 150));
        await keyStore.put('otp.wavi@alice', AtData()..data = 'v1',
            assertedTimestamps: AtAssertedTimestamps(
                updatedAt: DateTime.now().add(Duration(seconds: 10)),
                expiresAt: eAt,
                deriveTtl: true));
        final meta = (await keyStore.getMeta('otp.wavi@alice'))!;
        expect(meta.ttl, isNull,
            reason: 'this test exists to cover the expiresAt-without-ttl '
                'state; if a ttl were derived here, the expiry cache could '
                'be seeing the ttl rather than the asserted expiresAt');
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
