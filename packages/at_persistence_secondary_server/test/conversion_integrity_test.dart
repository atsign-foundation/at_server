import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:test/test.dart';

/// The conversion-integrity gate:
///
///   hive1 → sqlite1 → hive2 → sqlite2 → hive3 → sqlite3
///
/// asserting all three Hive snapshots are identical, and all three SQLite
/// snapshots are identical. Because the migrator uses verbatim primitives
/// (no metadata builder, preserved commit ids), a lossless backend
/// round-trips a rich fixture unchanged; any lossy field would surface as
/// a snapshot difference.
void main() {
  const atSign = '@alice';
  final root = '${Directory.current.path}/test/conversion_tmp';

  final hiveFactory = HiveAtPersistenceFactory();
  final sqliteFactory = SqliteAtPersistenceFactory();

  tearDown(() async {
    await hiveFactory.close();
    await sqliteFactory.close();
    final dir = Directory(root);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<AtPersistenceBundle> hiveBundle(String name) => hiveFactory.initialize(
      '$atSign-$name-key', // distinct atSign so boxes don't collide in-process
      HivePersistenceConfig.serverDefaults(
        storagePath: '$root/hive/$name',
        commitLogPath: '$root/hive/$name',
        accessLogPath: '$root/hive/$name',
        notificationStoragePath: '$root/hive/$name',
      ));

  Future<AtPersistenceBundle> sqliteBundle(String name) =>
      sqliteFactory.initialize(
          '$atSign-$name-key',
          SqlitePersistenceConfig.serverDefaults(
              storagePath: '$root/sqlite/$name'));

  AtData atData(String? v, AtMetaData m) => AtData()
    ..data = v
    ..metaData = m;

  // ms-precision so Hive's ms-truncation and SQLite's JSON string form agree.
  DateTime t(int y, [int mo = 1, int d = 1, int h = 0, int mi = 0, int s = 0, int ms = 0]) =>
      DateTime.utc(y, mo, d, h, mi, s, ms);

  /// Seeds a bundle with a fixture exercising every field/edge the round
  /// trip must preserve.
  Future<void> seed(AtPersistenceBundle b) async {
    final ks = b.keyValueStore;
    final owner = b.atSign;

    // 1. A fully-populated metadata record (via verbatim restore so the
    //    audit fields are fixed and comparable).
    await ks.restore('public:publickey$owner', atData('RSA_PUB', AtMetaData()
      ..createdBy = owner
      ..updatedBy = owner
      ..createdAt = t(2021, 1, 2, 3, 4, 5, 678)
      ..updatedAt = t(2021, 1, 2, 3, 4, 5, 678)
      ..version = 0
      ..ttr = -1
      ..isBinary = false
      ..isEncrypted = false
      ..dataSignature = 'sig-data'
      ..sharedKeyEnc = 'shared-enc'
      ..pubKeyCS = 'cs123'
      ..encoding = 'base64'
      ..encKeyName = 'ek'
      ..encAlgo = 'AES/GCM'
      ..ivNonce = 'iv123'
      ..skeEncKeyName = 'ske'
      ..skeEncAlgo = 'RSA'));

    // 2. A normal write (goes through the builder → commit entry).
    await ks.create('phone.wavi$owner', atData('+1234', AtMetaData()));

    // 3. A shared key.
    await ks.create('@bob:location.wavi$owner',
        atData('encrypted-loc', AtMetaData()..isEncrypted = true));

    // 4. A TTL key already expired. (version is always set on real
    //    stored data — the builder stamps it — so the fixture sets it too;
    //    AtMetaData.fromJson coerces a null version to 0, which would
    //    otherwise diverge from Hive's binary adapter that preserves null.)
    await ks.restore('temp.wavi$owner', atData('gone', AtMetaData()
      ..createdAt = t(2020)
      ..updatedAt = t(2020)
      ..version = 3
      ..ttl = 1000
      ..expiresAt = t(2020, 1, 1, 0, 0, 1)));

    // 5. A TTB key not yet born.
    await ks.restore('future.wavi$owner', atData('later', AtMetaData()
      ..createdAt = t(2021)
      ..updatedAt = t(2021)
      ..version = 0
      ..ttb = 999999999
      ..availableAt = t(2099)));

    // 6. An elided key (no commit entry).
    await ks.create('private:secret.wavi$owner', atData('hush', AtMetaData()));

    // 7. A public:__ (double underscore) key — IS synced.
    await ks.create('public:__internal.wavi$owner', atData('vis', AtMetaData()));

    // 8. A unicode atKey.
    await ks.create('emoji.wavi$owner', atData('🎉', AtMetaData()));

    // 9. A create-then-delete (leaves a `-` commit entry, no at_data row).
    await ks.create('goodbye.wavi$owner', atData('bye', AtMetaData()));
    await ks.remove('goodbye.wavi$owner');

    // Access log.
    await b.accessLog!.replay(
        AccessLogEntry(owner, t(2022, 5, 5, 1, 2, 3), 'pkam', null));
    await b.accessLog!
        .replay(AccessLogEntry('@bob', t(2022, 5, 5, 1, 2, 4), 'lookup', 'phone.wavi$owner'));
    await b.accessLog!
        .replay(AccessLogEntry('@bob', t(2022, 5, 5, 1, 2, 5), 'pol', null));

    // Notifications in different statuses.
    for (final status in NotificationStatus.values) {
      final n = (AtNotificationBuilder()
            ..id = 'notif-${status.name}'
            ..fromAtSign = '@bob'
            ..toAtSign = owner
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..notification = 'phone.wavi$owner'
            ..notificationStatus = status
            ..notificationDateTime = t(2022, 6, 6, 7, 8, 9)
            ..expiresAt = t(2099, 1, 1)
            ..ttl = 3600000
            ..atValue = 'payload-${status.name}')
          .build();
      await b.notificationKeystore!.put(n.id!, n);
    }
  }

  test('hive1 → sqlite1 → hive2 → sqlite2 → hive3 → sqlite3 are identical',
      () async {
    final hive1 = await hiveBundle('h1');
    await seed(hive1);

    final sqlite1 = await sqliteBundle('s1');
    final r1 = await PersistenceMigrator.migrate(hive1, sqlite1);

    final hive2 = await hiveBundle('h2');
    await PersistenceMigrator.migrate(sqlite1, hive2);

    final sqlite2 = await sqliteBundle('s2');
    await PersistenceMigrator.migrate(hive2, sqlite2);

    final hive3 = await hiveBundle('h3');
    await PersistenceMigrator.migrate(sqlite2, hive3);

    final sqlite3 = await sqliteBundle('s3');
    await PersistenceMigrator.migrate(hive3, sqlite3);

    // Migration actually moved data.
    expect(r1.keys, greaterThan(5));
    expect(r1.commitEntries, greaterThan(3));
    expect(r1.accessEntries, 3);
    expect(r1.notifications, NotificationStatus.values.length);

    final snapH1 = await PersistenceSnapshot.capture(hive1);
    final snapH2 = await PersistenceSnapshot.capture(hive2);
    final snapH3 = await PersistenceSnapshot.capture(hive3);
    final snapS1 = await PersistenceSnapshot.capture(sqlite1);
    final snapS2 = await PersistenceSnapshot.capture(sqlite2);
    final snapS3 = await PersistenceSnapshot.capture(sqlite3);

    expect(snapH1.describeDifferenceFrom(snapH2), isNull,
        reason: 'hive1 vs hive2');
    expect(snapH1.describeDifferenceFrom(snapH3), isNull,
        reason: 'hive1 vs hive3');
    expect(snapS1.describeDifferenceFrom(snapS2), isNull,
        reason: 'sqlite1 vs sqlite2');
    expect(snapS1.describeDifferenceFrom(snapS3), isNull,
        reason: 'sqlite1 vs sqlite3');

    // And the two backends agree with each other (the interchange goal).
    expect(snapH1.describeDifferenceFrom(snapS1), isNull,
        reason: 'hive1 vs sqlite1');
  });
}
