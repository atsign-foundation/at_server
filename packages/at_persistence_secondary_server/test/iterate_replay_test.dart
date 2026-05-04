import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() {
  group('HiveAtCommitLog iterate / replay', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('iter_replay_');
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

    test('iterate yields every commit entry in commitId order', () async {
      // Insert three entries via the normal commit() path so they get
      // monotonically-increasing commitIds.
      await bundle.commitLog.commit('public:foo@alice', CommitOp.UPDATE);
      await bundle.commitLog.commit('public:bar@alice', CommitOp.UPDATE);
      await bundle.commitLog.commit('public:baz@alice', CommitOp.DELETE);

      final entries = await bundle.commitLog.iterate().toList();
      expect(entries.length, 3);
      // Commit IDs are monotonic.
      expect(entries[0].commitId! <= entries[1].commitId!, isTrue);
      expect(entries[1].commitId! <= entries[2].commitId!, isTrue);
      // Values round-trip.
      expect(entries.map((e) => e.atKey).toSet(),
          {'public:foo@alice', 'public:bar@alice', 'public:baz@alice'});
    });

    test('iterate honours fromCommitId', () async {
      await bundle.commitLog.commit('public:a@alice', CommitOp.UPDATE);
      await bundle.commitLog.commit('public:b@alice', CommitOp.UPDATE);
      await bundle.commitLog.commit('public:c@alice', CommitOp.UPDATE);

      final all = await bundle.commitLog.iterate().toList();
      // Skip the first; keep the last two.
      final cutoff = all[1].commitId!;
      final partial =
          await bundle.commitLog.iterate(fromCommitId: cutoff).toList();
      expect(partial.length, 2);
      expect(partial.first.commitId, cutoff);
    });

    test('replay preserves the supplied commitId', () async {
      // Build an entry that names its own commitId — typical of a
      // migration source where IDs were already assigned.
      final entry = CommitEntry(
          'public:replayed@alice', CommitOp.UPDATE, DateTime.now().toUtc())
        ..commitId = 9001;
      await bundle.commitLog.replay(entry);

      final fetched = await bundle.commitLog.iterate().toList();
      expect(fetched.length, 1);
      expect(fetched.single.commitId, 9001);
      expect(fetched.single.atKey, 'public:replayed@alice');
    });

    test('replay is idempotent on the same (commitId, atKey, op)', () async {
      final entry = CommitEntry(
          'public:idem@alice', CommitOp.UPDATE, DateTime.now().toUtc())
        ..commitId = 4242;
      await bundle.commitLog.replay(entry);
      await bundle.commitLog.replay(entry); // second call is a no-op overwrite.

      final fetched = await bundle.commitLog.iterate().toList();
      expect(fetched.length, 1);
      expect(fetched.single.commitId, 4242);
    });

    test('replay rejects a CommitEntry without a commitId', () {
      final entry = CommitEntry('public:nocommitid@alice', CommitOp.UPDATE,
          DateTime.now().toUtc()); // no commitId set
      expect(
          () => bundle.commitLog.replay(entry), throwsA(isA<ArgumentError>()));
    });

    test('iterate over an empty log yields nothing', () async {
      final entries = await bundle.commitLog.iterate().toList();
      expect(entries, isEmpty);
    });

    test('iterate with where filter skips non-matching entries', () async {
      await bundle.commitLog.commit('public:alpha@alice', CommitOp.UPDATE);
      await bundle.commitLog.commit('public:beta@alice', CommitOp.UPDATE);
      await bundle.commitLog.commit('public:gamma@alice', CommitOp.UPDATE);

      final filtered = await bundle.commitLog
          .iterate(where: (e) => e.atKey == 'public:beta@alice')
          .toList();
      expect(filtered.length, 1);
      expect(filtered.single.atKey, 'public:beta@alice');
    });

    test('iterate where filter combines with fromCommitId', () async {
      await bundle.commitLog.commit('public:a@alice', CommitOp.UPDATE);
      await bundle.commitLog.commit('public:b@alice', CommitOp.UPDATE);
      await bundle.commitLog.commit('public:c@alice', CommitOp.UPDATE);

      final all = await bundle.commitLog.iterate().toList();
      final cutoff = all[1].commitId!;
      final filtered = await bundle.commitLog
          .iterate(
              fromCommitId: cutoff,
              where: (e) => e.operation == CommitOp.UPDATE)
          .toList();
      // From cutoff: 2 entries; both UPDATE; both pass.
      expect(filtered.length, 2);
    });

    test(
        'iterate yields one entry per atKey under stream of commits to same atKey',
        () async {
      // Phase 3.5a's invariant in action: even after multiple commits to
      // the same atKey, iterate yields exactly one entry (the latest).
      for (int i = 0; i < 10; i++) {
        await bundle.commitLog.commit('public:hot@alice', CommitOp.UPDATE);
      }
      final entries = await bundle.commitLog.iterate().toList();
      expect(entries.length, 1);
      expect(entries.single.atKey, 'public:hot@alice');
    });
  });

  group('HiveAtAccessLog iterate', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('iter_access_');
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

    test('iterate yields every access-log entry in insertion order', () async {
      final accessLog = bundle.accessLog!;
      await accessLog.insert('@bob', 'lookup', lookupKey: 'phone@alice');
      await accessLog.insert('@charlie', 'plookup');
      await accessLog.insert('@dave', 'pkam');

      final entries = await accessLog.iterate().toList();
      expect(entries.length, 3);
      expect(entries.map((e) => e.fromAtSign).toList(),
          ['@bob', '@charlie', '@dave']);
    });
  });

  group('HiveAtNotificationKeystore iterate', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('iter_notif_');
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

    test('iterate yields every notification entry', () async {
      final notif = bundle.notificationKeystore!;
      final n1 = (AtNotificationBuilder()
            ..fromAtSign = '@alice'
            ..toAtSign = '@bob'
            ..notification = 'phone@bob')
          .build();
      final n2 = (AtNotificationBuilder()
            ..fromAtSign = '@alice'
            ..toAtSign = '@charlie'
            ..notification = 'email@charlie')
          .build();
      await notif.put(n1.id, n1);
      await notif.put(n2.id, n2);

      final entries = await notif.iterate().toList();
      expect(entries.length, 2);
      expect(entries.map((e) => e.toAtSign).toSet(), {'@bob', '@charlie'});
    });
  });

  group('Bundle clear', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;
    late AtPersistenceBundle bundle;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('clear_');
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

    test('clear empties every store but keeps the bundle usable', () async {
      // Populate every store.
      await bundle.commitLog.commit('public:before@alice', CommitOp.UPDATE);
      await bundle.accessLog!.insert('@bob', 'lookup');
      final n = (AtNotificationBuilder()
            ..fromAtSign = '@alice'
            ..toAtSign = '@bob'
            ..notification = 'phone@bob')
          .build();
      await bundle.notificationKeystore!.put(n.id, n);

      expect(bundle.commitLog.entriesCount(), greaterThan(0));
      expect(bundle.accessLog!.entriesCount(), greaterThan(0));
      expect(bundle.notificationKeystore!.entriesCount(), greaterThan(0));

      await bundle.clear();

      expect(bundle.commitLog.entriesCount(), 0);
      expect(bundle.accessLog!.entriesCount(), 0);
      expect(bundle.notificationKeystore!.entriesCount(), 0);

      // Bundle remains usable: writes still work afterwards.
      await bundle.commitLog.commit('public:after@alice', CommitOp.UPDATE);
      expect(bundle.commitLog.entriesCount(), 1);
    });

    test('clear after close throws StateError', () async {
      await factory.close();
      // factory.close() closes the bundle; subsequent clear should throw.
      expect(() => bundle.clear(), throwsA(isA<StateError>()));
    });
  });

  group('Bundle slimming', () {
    late Directory tempDir;
    late HiveAtPersistenceFactory factory;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('slim_');
      factory = HiveAtPersistenceFactory();
    });

    tearDown(() async {
      await factory.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('clientDefaults skips access log + notification keystore', () async {
      final bundle = await factory.initialize(
        '@alice',
        HivePersistenceConfig.clientDefaults(
          storagePath: '${tempDir.path}/hive',
          commitLogPath: '${tempDir.path}/commitLog',
        ),
      );
      expect(bundle.accessLog, isNull);
      expect(bundle.notificationKeystore, isNull);
      // Core capabilities are still populated.
      expect(bundle.commitLog, isNotNull);
      expect(bundle.keyStore, isNotNull);
    });

    test('serverDefaults populates every optional capability', () async {
      final bundle = await factory.initialize(
        '@alice',
        HivePersistenceConfig.serverDefaults(
          storagePath: '${tempDir.path}/hive',
          commitLogPath: '${tempDir.path}/commitLog',
          accessLogPath: '${tempDir.path}/accessLog',
          notificationStoragePath: '${tempDir.path}/notification',
        ),
      );
      expect(bundle.accessLog, isNotNull);
      expect(bundle.notificationKeystore, isNotNull);
    });
  });
}
