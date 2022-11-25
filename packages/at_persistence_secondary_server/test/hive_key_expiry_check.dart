import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/server/at_server_commit_log.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/server/at_server_commit_log_keystore.dart';
import 'package:test/expect.dart';

void main() async {
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@test_user_1')!;
  var manager = secondaryPersistenceStore.getHivePersistenceManager()!;
  await manager.init('test/hive');
  manager.scheduleKeyExpireTask(1);

  var keyStoreManager =
      secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
  var keyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
  var commitLogKeyStore = AtServerCommitLogKeyStore('@test_user_1');
  await commitLogKeyStore.init('test/hive/commit');
  keyStore.commitLog = AtServerCommitLog(commitLogKeyStore);
  keyStoreManager.keyStore = keyStore;
  var atData = AtData();
  atData.data = 'abc';
  await keyStoreManager
      .getKeyStore()
      .put('phone.wavi@test_user_1', atData, time_to_live: 2000);
  var atDataResponse =
      await keyStoreManager.getKeyStore().get('phone.wavi@test_user_1');
  print(atDataResponse?.data);
  assert(atDataResponse?.data == 'abc');
  await Future.delayed(Duration(seconds: 60));
  expect(
      () async =>
          await keyStoreManager.getKeyStore().get('phone.wavi@test_user_1'),
      throwsA(predicate((dynamic e) => e is KeyNotFoundException)));
}
