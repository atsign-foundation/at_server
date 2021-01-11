import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_keystore_manager.dart';
import 'package:at_persistence_secondary_server/src/model/at_data.dart';

void main() async {
  var manager = HivePersistenceManager.getInstance();
  var directory = '${Directory.current}/hive';
  var result = await manager.init('@alice', directory);
  manager.scheduleKeyExpireTask(1);
  print(result);

  var keyStoreManager = SecondaryKeyStoreManager.getInstance();
  var commitKeyStore = CommitLogKeyStore.getInstance();
  await manager.openVault('@alice');
  await commitKeyStore.init('commitLog', directory);
  keyStoreManager.init();

  var atData = AtData();
  atData.data = 'abc';
  await keyStoreManager
      .getKeyStore()
      .put('123', atData, time_to_live: 30 * 1000);
  print('end');
  var at_data = await keyStoreManager.getKeyStore().get('123');
  print(at_data?.data);
  assert(at_data?.data == 'abc');
  var expiredKey =
      await Future.delayed(Duration(minutes: 2), () => getKey(keyStoreManager));
  assert(expiredKey == null);
  print(expiredKey);
  exit(0);
}

Future<String> getKey(keyStoreManager) async {
  AtData at_data = await keyStoreManager.getKeyStore().get('123');
  return at_data?.data;
}
