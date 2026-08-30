import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:test/test.dart';

/// The restart cycle, at the persistence layer.
///
/// `AtCertificateValidationJob` restarts the atServer **in process** when the
/// TLS certificates on disk are replaced: `AtSecondaryServerImpl.stop()`, which
/// closes persistence through `persistenceFactory.close()`, and then `start()`
/// again on the same singleton, which calls `initialize` on the same factory
/// with a config rebuilt from the same static settings. That happens twice a
/// day on a live server, unattended, and nothing in the unit tree exercised it.
///
/// What must hold across it: the second `initialize` returns a working store
/// rooted at the SAME place, so records written before the restart are still
/// there afterwards, and the commit log carries on rather than starting again.
/// A defect that re-roots storage — an empty path resolving to the process
/// working directory, a stale cache entry answering with another location —
/// does not throw. It produces a server that comes back up looking healthy and
/// serving an empty or wrong store, which is why this is asserted by VALUE
/// rather than by "the store opened".
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('restart_cycle'));
  tearDown(() async {
    await HiveInstances.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String dir(String name) =>
      (Directory('${root.path}/$name')..createSync(recursive: true)).path;

  AtData data(String v) => AtData()..data = v;

  /// One config, rebuilt each time — the server does not reuse the object
  /// either; `PersistenceBackendManager.configFor` builds a fresh one per
  /// start from the same static settings.
  HivePersistenceConfig hiveConfig(String d) => HivePersistenceConfig(
      storagePath: '$d/hive',
      commitLogPath: '$d/commitLog',
      accessLogPath: '$d/accessLog',
      notificationStoragePath: '$d/notificationLog');

  group('a restart keeps the same storage', () {
    test('hive: records written before a restart survive it', () async {
      const atSign = '@alice';
      final storage = dir('hive_survives');
      final factory = HiveAtPersistenceFactory();

      // ---- first start ----
      var bundle = await factory.initialize(atSign, hiveConfig(storage));
      await bundle.keyValueStore.put('before@alice', data('written-before'));
      final notification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = atSign
            ..id = 'notification-before')
          .build();
      await bundle.notificationKeystore!.put(notification.id!, notification);
      final commitIdBefore =
          bundle.keyValueStore.commitLog!.lastCommittedSequenceNumber();
      expect(commitIdBefore, greaterThanOrEqualTo(0),
          reason: 'the write above must have reached the commit log, or the '
              'commit-log half of this test is asserting nothing');

      // ---- the restart: exactly what AtSecondaryServerImpl.stop() does ----
      await factory.close();
      // Deliberately NOT asserting `factory.bundleFor(atSign) == null` here.
      // It is null either way: bundleFor drops a CLOSED bundle from its map and
      // returns null regardless of whether close() cleared it, so the
      // assertion passes under a close() that clears nothing. Verified by
      // mutation — it stayed green. What close() must actually achieve is
      // observable further down: the next initialize returns a live store at
      // the same location.

      // ---- second start, same factory, config rebuilt ----
      bundle = await factory.initialize(atSign, hiveConfig(storage));

      expect((await bundle.keyValueStore.get('before@alice'))?.data,
          'written-before',
          reason: 'the keystore record written before the restart must still '
              'be there. If storage were re-rooted — an empty path resolving '
              'to the CWD, a cached bundle answering for another location — '
              'nothing throws and this is the only thing that notices');
      expect(
          (await bundle.notificationKeystore!.get('notification-before'))?.id,
          'notification-before',
          reason: 'the notification keystore is a separate box under a '
              'separate path, so it can be re-rooted independently of the '
              'keystore');
      expect(bundle.keyValueStore.commitLog!.lastCommittedSequenceNumber(),
          greaterThanOrEqualTo(commitIdBefore!),
          reason: 'the commit log must carry on, not start again — a sequence '
              'that reset would resend the whole store to every client');

      // The control. Without it, "the record is there" could be satisfied by a
      // store that was never closed at all, and the test would pass for a
      // factory whose close() did nothing.
      await bundle.keyValueStore.put('after@alice', data('written-after'));
      expect((await bundle.keyValueStore.get('after@alice'))?.data,
          'written-after',
          reason: 'the store must be live after the restart, not merely '
              'readable');

      await factory.close();
    });

    test('sqlite: records written before a restart survive it', () async {
      const atSign = '@alice';
      final storage = dir('sqlite_survives');
      final factory = SqliteAtPersistenceFactory();
      final config = SqlitePersistenceConfig(storagePath: storage);

      var bundle = await factory.initialize(atSign, config);
      await bundle.keyValueStore.put('before@alice', data('written-before'));
      await factory.close();

      bundle = await factory.initialize(
          atSign, SqlitePersistenceConfig(storagePath: storage));
      expect((await bundle.keyValueStore.get('before@alice'))?.data,
          'written-before',
          reason: 'the sqlite backend is reached by the same restart path and '
              'must hold the same guarantee');
      await factory.close();
    });

    test('the storage-conflict guard stays inert across restarts', () async {
      // The guard added to initialize() throws when a factory already holds an
      // open bundle for an atSign rooted somewhere else. A restart re-enters
      // initialize() on the SAME factory instance, so if close() failed to
      // clear what it holds, the second start would throw — and because
      // restartServer does not await start(), that throw reaches the
      // bootstrapper's zone handler and exits the process with status 0.
      const atSign = '@alice';
      final storage = dir('guard_inert');
      final factory = HiveAtPersistenceFactory();

      for (var restart = 0; restart < 3; restart++) {
        final bundle = await factory.initialize(atSign, hiveConfig(storage));
        await bundle.keyValueStore
            .put('cycle$restart@alice', data('cycle-$restart'));
        await factory.close();
      }

      final bundle = await factory.initialize(atSign, hiveConfig(storage));
      for (var restart = 0; restart < 3; restart++) {
        expect((await bundle.keyValueStore.get('cycle$restart@alice'))?.data,
            'cycle-$restart',
            reason: 'every cycle wrote to the same store, so every cycle\'s '
                'record must still be readable from the last one');
      }
      await factory.close();
    });

    test('restarting does not accumulate Hive instances', () async {
      // `HiveInstances._byPath` is static and outlives a restart by design.
      // If a restart added instances rather than reusing them, a long-lived
      // server would accrue one set per certificate rotation, each holding its
      // own view of the same files — the divergence the per-path instances
      // exist to prevent, arriving through the back door.
      const atSign = '@alice';
      final storage = dir('no_accumulate');
      final factory = HiveAtPersistenceFactory();

      await factory.initialize(atSign, hiveConfig(storage));
      final afterFirstStart = HiveInstances.instanceCount;
      // Identity, not just the count: a count cannot see an instance being
      // REPLACED at the same key, and a replacement is the dangerous case —
      // two live HiveImpl over one directory, each with its own in-memory view
      // of the same files. Verified by mutation: a `_byPath[key] = HiveImpl()`
      // that overwrites keeps the count identical and passes a count-only
      // assertion.
      final instanceForStorage = HiveInstances.forPath('$storage/hive');
      await factory.close();

      for (var restart = 0; restart < 3; restart++) {
        await factory.initialize(atSign, hiveConfig(storage));
        await factory.close();
      }
      expect(
          identical(HiveInstances.forPath('$storage/hive'), instanceForStorage),
          isTrue,
          reason: 'one path means one instance, across a restart as much as '
              'within a start — a replacement puts two views over one set of '
              'files, which is the divergence per-path instances exist to '
              'prevent');
      expect(HiveInstances.instanceCount, afterFirstStart,
          reason: 'and no path gained an instance either: a server that added '
              'a set per certificate rotation would accrue them for as long as '
              'it runs');
      expect(afterFirstStart, greaterThan(0),
          reason: 'the count must be non-zero, or the assertion above holds '
              'trivially for a run that never opened anything');
    });
  });
}
