import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Tests for the migrator-only verbatim primitives added in the SQLite
/// backend work: [AtKeyValueStore.restore] and [AtAccessLog.replay].
/// The defining property is that they do NOT run the metadata builder /
/// timestamp stamping that the normal write paths do.
void main() {
  final storageDir = '${Directory.current.path}/test/hive/verbatim';
  const atSign = '@verbatim_user';

  group('AtKeyValueStore.restore writes verbatim', () {
    setUp(() async => await setUpTestKeyStore(atSign, storageDir: storageDir));
    tearDown(() async => await tearDownTestPersistence(storageDir: storageDir));

    // A fully-populated metadata with deliberately "old" audit fields,
    // as a migrated record would carry.
    AtMetaData sourceMetadata() => AtMetaData()
      ..createdBy = '@someone_else'
      ..updatedBy = '@someone_else'
      ..createdAt = DateTime.utc(2020, 1, 2, 3, 4, 5, 678)
      ..updatedAt = DateTime.utc(2021, 6, 7, 8, 9, 10, 111)
      ..version = 99
      ..ttl = 0
      ..ttr = -1
      ..isEncrypted = true
      ..dataSignature = 'sig'
      ..encoding = 'base64';

    test('preserves version/createdAt/updatedAt exactly (no builder run)',
        () async {
      final ks = testKeyStoreFor(atSign);
      const key = 'phone.wavi@verbatim_user';

      final restored = AtData()
        ..data = 'the-value'
        ..metaData = sourceMetadata();
      await ks.restore(key, restored);

      final got = await ks.get(key);
      expect(got!.data, 'the-value');
      // The metadata oracle: == compares all 27 fields. A normal put()
      // would have bumped version to 0/1 and set updatedAt to now.
      expect(got.metaData, equals(restored.metaData));
      expect(got.metaData!.version, 99);
      expect(got.metaData!.createdAt, DateTime.utc(2020, 1, 2, 3, 4, 5, 678));
      expect(got.metaData!.updatedAt, DateTime.utc(2021, 6, 7, 8, 9, 10, 111));
      expect(got.metaData!.createdBy, '@someone_else');
    });

    test('does not append to the commit log', () async {
      final ks = testKeyStoreFor(atSign);
      // Seed one committed key so the log is non-empty.
      await ks.create('seed.wavi@verbatim_user', AtData()..data = 'x');
      final before = ks.commitLog!.lastCommittedSequenceNumber();

      await ks.restore(
          'phone.wavi@verbatim_user',
          AtData()
            ..data = 'v'
            ..metaData = sourceMetadata());

      expect(ks.commitLog!.lastCommittedSequenceNumber(), before,
          reason: 'restore must not advance the commit id');
      expect(ks.commitLog!.getLatestCommitEntry('phone.wavi@verbatim_user'),
          isNull,
          reason: 'restore must not create a commit entry');
    });

    test('is idempotent', () async {
      final ks = testKeyStoreFor(atSign);
      const key = 'phone.wavi@verbatim_user';
      final atData = AtData()
        ..data = 'v'
        ..metaData = sourceMetadata();

      await ks.restore(key, atData);
      final first = await ks.get(key);
      await ks.restore(key, atData);
      final second = await ks.get(key);

      expect(second!.data, first!.data);
      expect(second.metaData, equals(first.metaData));
    });
  });

  group('AtAccessLog.replay preserves the entry timestamp', () {
    setUp(
        () async => await testAccessLogFor(atSign, accessLogPath: storageDir));
    tearDown(() async => await tearDownTestPersistence(storageDir: storageDir));

    test('replay keeps requestDateTime; insert would stamp now', () async {
      final log = await testAccessLogFor(atSign);
      final past = DateTime.utc(2019, 3, 4, 5, 6, 7, 8);
      await log.replay(AccessLogEntry(atSign, past, 'lookup', 'phone@x'));

      final last = await log.getLastAccessLogEntry();
      expect(last.requestDateTime, past);
      expect(last.verbName, 'lookup');
      expect(last.fromAtSign, atSign);
      expect(last.lookupKey, 'phone@x');
    });
  });
}
