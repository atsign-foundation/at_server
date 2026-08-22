import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/dual.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:test/test.dart';

/// Drives a realistic operation sequence through the dual-write bundle
/// (Hive primary + SQLite secondary) and asserts the two underlying DB sets
/// end up byte-identical — the property the functional-pack run relies on.
void main() {
  const atSign = '@dual_alice';
  final root = '${Directory.current.path}/test/dual_tmp';

  late DualWriteAtPersistenceFactory factory;
  late DualWriteBundle bundle;

  setUp(() async {
    factory = DualWriteAtPersistenceFactory(
        HiveAtPersistenceFactory(), SqliteAtPersistenceFactory());
    bundle = await factory.initialize(
        atSign,
        DualWritePersistenceConfig(
          primary: HivePersistenceConfig.serverDefaults(
            storagePath: '$root/hive',
            commitLogPath: '$root/commitLog',
            accessLogPath: '$root/accessLog',
            notificationStoragePath: '$root/notif',
          ),
          secondary: SqlitePersistenceConfig.serverDefaults(
              storagePath: '$root/sqlite'),
        )) as DualWriteBundle;
  });

  tearDown(() async {
    await factory.close();
    final dir = Directory(root);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AtData d(String v, [AtMetaData? m]) => AtData()
    ..data = v
    ..metaData = m;

  test('every write is mirrored byte-exactly; the two DB sets are identical',
      () async {
    final ks = bundle.keyValueStore;

    // Value writes (the metadata builder stamps createdAt/updatedAt — the
    // mirror must copy the primary's stamps, not let sqlite stamp its own).
    await ks.create('phone.wavi$atSign', d('111'));
    await ks.put('phone.wavi$atSign', d('222')); // update → version bump
    await ks.create(
        'email.wavi$atSign', d('a@b', AtMetaData()..isEncrypted = true));
    await ks.putMeta('email.wavi$atSign', AtMetaData()..ttr = 3600);

    // Shared + elided + public:__ keys.
    await ks.create('@bob:loc.wavi$atSign', d('enc'));
    await ks.create('private:secret.wavi$atSign', d('hush'));
    await ks.create('public:__vis.wavi$atSign', d('shown'));

    // Delete (leaves a `-` commit entry).
    await ks.create('bye.wavi$atSign', d('later'));
    await ks.remove('bye.wavi$atSign');

    // Caller-asserted timestamps and opTimes must mirror byte-exactly.
    await ks.create('faithful.wavi$atSign', d('x'),
        assertedTimestamps: AtAssertedTimestamps(
            createdAt: DateTime.utc(2020, 1, 2, 3, 4, 5, 678),
            updatedAt: DateTime.utc(2021, 2, 3, 4, 5, 6, 789),
            expiresAt: DateTime.utc(2030, 1, 1)));
    await ks.create('dat.wavi$atSign', d('y'));
    await ks.remove('dat.wavi$atSign',
        deletedAt: DateTime.utc(2023, 5, 5, 11, 59, 44, 123));

    // A skipCommit write purges the key's commit entry while the key lives
    // on (the update:nc shape); the mirror must purge the secondary's stale
    // entry too — "same commit entry, or same absence".
    await ks.create('quiet.wavi$atSign', d('v1'));
    await ks.put('quiet.wavi$atSign', d('v2'), skipCommit: true);
    expect(
        bundle.secondary.keyValueStore.commitLog!
            .getLatestCommitEntry('quiet.wavi$atSign'),
        isNull,
        reason: 'a skipCommit write purged the primary\'s commit entry; a '
            'stale secondary entry would resurface in sync after a '
            'backend switch');

    // Expired TTL key swept via deleteExpiredKeys.
    await ks.restore(
        'exp.wavi$atSign',
        d(
            'gone',
            AtMetaData()
              ..createdAt = DateTime.utc(2020)
              ..updatedAt = DateTime.utc(2020)
              ..version = 0
              ..ttl = 1
              ..expiresAt = DateTime.utc(2020, 1, 1, 0, 0, 1)));
    await ks.deleteExpiredKeys();

    // Notifications — including one whose embedded metadata has null
    // createdAt/updatedAt/version (as real wire notifications do), which the
    // SQLite codec must round-trip exactly as Hive's binary adapter does.
    final n = (AtNotificationBuilder()
          ..id = 'notif-1'
          ..fromAtSign = '@bob'
          ..toAtSign = atSign
          ..notification = 'phone.wavi$atSign'
          ..type = NotificationType.received
          ..notificationStatus = NotificationStatus.delivered
          ..atMetaData = (AtMetaData()
            ..createdBy = atSign
            ..isEncrypted = true
            ..ttl = 0)) // no createdAt / updatedAt / version set
        .build();
    await bundle.notificationKeystore!.put(n.id!, n);

    // Access log.
    await bundle.accessLog!
        .insert('@bob', 'lookup', lookupKey: 'phone.wavi$atSign');
    await bundle.accessLog!.insert(atSign, 'pkam');

    // The two underlying DB sets must be byte-identical.
    final primarySnap = await PersistenceSnapshot.capture(bundle.primary);
    final secondarySnap = await PersistenceSnapshot.capture(bundle.secondary);
    final diffs = primarySnap.differencesFrom(secondarySnap);
    expect(diffs, isEmpty, reason: diffs.join('\n'));

    // Sanity: the data actually landed (reads come from primary).
    expect((await ks.get('phone.wavi$atSign'))!.data, '222');
    expect(await ks.exists('exp.wavi$atSign'), false);
  });
}
