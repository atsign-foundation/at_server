import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_secondary/src/config/at_config.dart';
import 'package:test/test.dart';

var storageDir = '${Directory.current.path}/test/hive';
late AtKeyValueStore<String, AtData, AtMetaData?> keyValueStore;
void main() async {
  group('Verify blocklist configuration behaviour', () {
    setUp(() async => await setUpFunc(storageDir));

    test('test for adding data to blocklist', () async {
      var atsignsToBeBlocked = {'@alice', '@bob'};
      var atConfigInstance = AtConfig(keyValueStore, '@test_user_1');
      var result = await atConfigInstance.addToBlockList(atsignsToBeBlocked);
      expect(result, 'success');
    });

    test('test for fetching blocklist', () async {
      var atConfigInstance = AtConfig(keyValueStore, '@test_user_1');
      var atsignsToBeBlocked = {'@alice', '@bob'};
      await atConfigInstance.addToBlockList(atsignsToBeBlocked);
      var result = await atConfigInstance.getBlockList();
      expect(result, atsignsToBeBlocked);
    });

    test('test for removing blocklist data', () async {
      var atConfigInstance = AtConfig(keyValueStore, '@test_user_1');
      var atsignsToBeBlocked = {'@alice', '@bob', '@charlie'};
      await atConfigInstance.addToBlockList(atsignsToBeBlocked);
      var atsignsToBeUnblocked = {'@alice'.toAtsign(), '@bob'.toAtsign()};
      var result =
          await atConfigInstance.removeFromBlockList(atsignsToBeUnblocked);
      expect(result, 'success');
      // get block list
      var blockList = await atConfigInstance.getBlockList();
      expect(blockList, {'@charlie'});
    });

    test('test for removing non existing data from blocklist', () async {
      var data = {'@alice', '@bob'};
      var atConfigInstance = AtConfig(keyValueStore, '@test_user_1');
      await atConfigInstance.addToBlockList(data);
      var removeData = {'@colin'.toAtsign()};
      var result = await atConfigInstance.removeFromBlockList(removeData);
      expect(result, 'success');
    });

    test('test for removing empty data', () async {
      var removeData = <Atsign>{};
      var atConfigInstance = AtConfig(keyValueStore, '@test_user_1');
      expect(() async => await atConfigInstance.removeFromBlockList(removeData),
          throwsA(predicate((dynamic e) => e is IllegalArgumentException)));
    });

    test('test for removing null data', () async {
      var atConfigInstance = AtConfig(keyValueStore, '@test_user_1');
      expect(() async => await atConfigInstance.removeFromBlockList({}),
          throwsA(predicate((dynamic e) => e is IllegalArgumentException)));
    });

    tearDown(() async => await tearDownFunc());
  });

  group('Given blocklist entries stored as they were typed', () {
    late AtConfig atConfig;

    setUp(() async {
      await setUpFunc(storageDir);
      atConfig = AtConfig(keyValueStore, '@test_user_1');
      await atConfig.addToBlockList({'@Dave', '@e.rin', 'frank'});
    });
    tearDown(() async => await tearDownFunc());

    test('when each one\'s canonical atSign is checked, then it is blocked',
        () async {
      for (final atSign in ['@dave', '@erin', '@frank']) {
        expect(await atConfig.checkInBlockList(atSign.toAtsign()), isTrue,
            reason: atSign);
      }
      expect(await atConfig.checkInBlockList('@grace'.toAtsign()), isFalse);
    });
  });

  group('Given a blocklist entry that is not an atSign', () {
    late AtConfig atConfig;

    setUp(() async {
      await setUpFunc(storageDir);
      atConfig = AtConfig(keyValueStore, '@test_user_1');
      await atConfig.addToBlockList({'@a!b', '@carol'});
    });
    tearDown(() async => await tearDownFunc());

    test('when an atSign is checked, then that entry is passed over', () async {
      expect(await atConfig.checkInBlockList('@carol'.toAtsign()), isTrue);
      expect(await atConfig.checkInBlockList('@dave'.toAtsign()), isFalse);
    });

    test('when another atSign is removed, then that entry is kept', () async {
      await atConfig.removeFromBlockList({'@carol'.toAtsign()});
      expect(await atConfig.getBlockList(), {'@a!b'});
    });
  });
}

late HiveAtPersistenceFactory _atConfigTestFactory;

Future<void> setUpFunc(String storageDir) async {
  _atConfigTestFactory = HiveAtPersistenceFactory();
  final bundle = await _atConfigTestFactory.initialize(
    '@test_user_1',
    HivePersistenceConfig(
      storagePath: storageDir,
      commitLogPath: storageDir,
      accessLogPath: storageDir,
      notificationStoragePath: storageDir,
    ),
  );
  keyValueStore = bundle.keyValueStore;
}

Future<void> tearDownFunc() async {
  await _atConfigTestFactory.close();
  var dir = Directory('test/hive/');
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}
