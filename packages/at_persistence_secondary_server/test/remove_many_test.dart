import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() {
  group('SecondaryKeyStore.removeMany()', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('remove_many_');
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
      Future<void> put(String k) =>
          bundle.keyStore.put(k, AtData()..data = 'v');
      await put('public:a.wavi@alice');
      await put('public:b.wavi@alice');
      await put('public:c.wavi@alice');
    });

    tearDown(() async {
      await factory.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('removes every present key, returns count', () async {
      final n = await bundle.keyStore.removeMany([
        'public:a.wavi@alice',
        'public:b.wavi@alice',
      ]);
      expect(n, 2);
      expect(await bundle.keyStore.exists('public:a.wavi@alice'), isFalse);
      expect(await bundle.keyStore.exists('public:b.wavi@alice'), isFalse);
      expect(await bundle.keyStore.exists('public:c.wavi@alice'), isTrue);
    });

    test('race-tolerant: absent keys do not contribute to the count',
        () async {
      final n = await bundle.keyStore.removeMany([
        'public:a.wavi@alice', // present
        'public:nope@alice', // absent
        'public:also_nope@alice', // absent
      ]);
      expect(n, 1);
    });

    test('all-absent input returns 0', () async {
      final n = await bundle.keyStore
          .removeMany(['public:nope_a@alice', 'public:nope_b@alice']);
      expect(n, 0);
    });

    test('empty input is a no-op that returns 0', () async {
      final n = await bundle.keyStore.removeMany(<String>[]);
      expect(n, 0);
    });

    test('emits a commit-log DELETE entry per removed key by default',
        () async {
      // Note: HiveAtCommitLog dedupes by atKey on add(), deleting the
      // prior entry for the same key. So count stays the same after
      // a put-then-delete cycle. Instead, verify the latest commit
      // entry for each removed key has CommitOp.DELETE.
      final n = await bundle.keyStore.removeMany([
        'public:a.wavi@alice',
        'public:b.wavi@alice',
      ]);
      expect(n, 2);
      expect(
        bundle.commitLog.getLatestCommitEntry('public:a.wavi@alice')?.operation,
        CommitOp.DELETE,
      );
      expect(
        bundle.commitLog.getLatestCommitEntry('public:b.wavi@alice')?.operation,
        CommitOp.DELETE,
      );
      // The untouched key still has its UPDATE entry.
      expect(
        bundle.commitLog.getLatestCommitEntry('public:c.wavi@alice')?.operation,
        CommitOp.UPDATE,
      );
    });

    test('skipCommit suppresses the commit-log entries', () async {
      // skipCommit:true scrubs prior commit entries for the deleted
      // keys (matches remove(skipCommit:)'s behaviour) AND doesn't
      // emit new DELETE entries. After scrubbing:
      //   - no commit entry for the deleted key.
      //   - other keys' commit entries are untouched.
      await bundle.keyStore
          .removeMany(['public:a.wavi@alice'], skipCommit: true);
      expect(
        bundle.commitLog.getLatestCommitEntry('public:a.wavi@alice'),
        isNull,
      );
      expect(
        bundle.commitLog.getLatestCommitEntry('public:c.wavi@alice')?.operation,
        CommitOp.UPDATE,
      );
    });

    test('duplicate input keys are de-duped (count reflects unique present)',
        () async {
      final n = await bundle.keyStore.removeMany([
        'public:a.wavi@alice',
        'public:a.wavi@alice',
        'public:a.wavi@alice',
      ]);
      expect(n, 1);
    });

    test('case-insensitive lookup (matches remove() behaviour)', () async {
      final n = await bundle.keyStore
          .removeMany(['PUBLIC:A.Wavi@alice', 'public:b.wavi@ALICE']);
      expect(n, 2);
      expect(await bundle.keyStore.exists('public:a.wavi@alice'), isFalse);
      expect(await bundle.keyStore.exists('public:b.wavi@alice'), isFalse);
    });
  });

  group('AtNotificationKeystore.removeMany()', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('remove_many_notif_');
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

    test('bulk-deletes notifications', () async {
      final notif = bundle.notificationKeystore!;
      final ids = <String>[];
      for (var i = 0; i < 3; i++) {
        final n = (AtNotificationBuilder()
              ..fromAtSign = '@alice'
              ..toAtSign = '@bob'
              ..notification = 'item-$i')
            .build();
        await notif.put(n.id!, n);
        ids.add(n.id!);
      }
      expect(notif.entriesCount(), 3);
      final n = await notif.removeMany(ids.take(2).toList());
      expect(n, 2);
      expect(notif.entriesCount(), 1);
    });
  });
}
