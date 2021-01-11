import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/at_commit_log.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:hive/hive.dart';
import 'package:test/test.dart';
import 'dart:io';

void main() async {
  var storageDir = Directory.current.path + '/test/hive/';
  setUp(() async => await setUpFunc(storageDir));

  group('A group of commit log test', () {
    test('test single insert', () async {
      var commitLogInstance = AtCommitLog.getInstance();
      var hiveKey =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      //expect(commitLogInstance.lastCommittedSequenceNumber(), 0);
      var committedEntry = await commitLogInstance.getEntry(hiveKey);
      expect(committedEntry.key, hiveKey);
      expect(committedEntry.atKey, 'location@alice');
      expect(committedEntry.operation, CommitOp.UPDATE);
      commitLogInstance = null;
    });
    test('test multiple insert', () async {
      var commitLogInstance = AtCommitLog.getInstance();

      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var key_2 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);

      await commitLogInstance.commit('location@alice', CommitOp.DELETE);
      expect(commitLogInstance.lastCommittedSequenceNumber(), 2);
      var committedEntry = await commitLogInstance.getEntry(key_2);
      expect(committedEntry.atKey, 'location@alice');
      expect(committedEntry.operation, CommitOp.UPDATE);
    });

    test('test get entry ', () async {
      var commitLogInstance = AtCommitLog.getInstance();
      var key_1 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var committedEntry = await commitLogInstance.getEntry(key_1);
      expect(committedEntry.atKey, 'location@alice');
      expect(committedEntry.operation, CommitOp.UPDATE);
      expect(committedEntry.opTime, isNotNull);
      expect(committedEntry.commitId, isNotNull);
    });

    test('test entries since commit Id', () async {
      var commitLogInstance = AtCommitLog.getInstance();

      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var key_2 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);

      await commitLogInstance.commit('location@alice', CommitOp.DELETE);
      await commitLogInstance.commit('phone@bob', CommitOp.UPDATE);

      await commitLogInstance.commit('email@charlie', CommitOp.UPDATE);
      expect(commitLogInstance.lastCommittedSequenceNumber(), 4);
      var changes = commitLogInstance.getChanges(key_2,'');
      expect(changes.length, 3);
      expect(changes[0].atKey, 'location@alice');
      expect(changes[1].atKey, 'phone@bob');
      expect(changes[2].atKey, 'email@charlie');
    });

    test('test last sequence number called once', () async {
      var commitLogInstance = AtCommitLog.getInstance();

      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);

      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      expect(commitLogInstance.lastCommittedSequenceNumber(), 1);
    });

    test('test last sequence number called multiple times', () async {
      var commitLogInstance = AtCommitLog.getInstance();

      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);

      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      expect(commitLogInstance.lastCommittedSequenceNumber(), 1);
      expect(commitLogInstance.lastCommittedSequenceNumber(), 1);
    });

    test('test commit - box not available', () async {
      var commitLogInstance = AtCommitLog.getInstance();
      await Hive.close();
      expect(
          () async =>
              await commitLogInstance.commit('location@alice', CommitOp.UPDATE),
          throwsA(predicate((e) => e is DataStoreException)));
    });

    test('test get entry - box not available', () async {
      var commitLogInstance = AtCommitLog.getInstance();
      var key_1 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      await Hive.close();
      expect(() async => await commitLogInstance.getEntry(key_1),
          throwsA(predicate((e) => e is DataStoreException)));
    });

    test('test entries since commit Id - box not available', () async {
      var commitLogInstance = AtCommitLog.getInstance();

      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var key_2 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      await Hive.close();
      expect(() async => await commitLogInstance.getEntry(key_2),
          throwsA(predicate((e) => e is DataStoreException)));
    });
  });

  tearDown(() async => tearDownFunc(storageDir));
}

void setUpFunc(storageDir) async {
  await CommitLogKeyStore.getInstance().init('@alice', storageDir);
}

Future<void> tearDownFunc(String storagePath) async {
  await Hive.deleteBoxFromDisk('@alice');
  var isExists = await Directory(storagePath).exists();
  if(isExists){
    await Directory(storagePath).deleteSync(recursive: true);
  }
}
