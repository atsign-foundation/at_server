import 'dart:convert';
import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/at_access_log_manager_impl.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  var storageDir = Directory.current.path + '/test/hive';

  group('A group of hive related test cases', () {
    setUp(() async => await setUpFunc(storageDir));

    test('Test to verify most visited atKeys', () async {
      var accessLogInstance = await AtAccessLogManagerImpl.getInstance()
          .getHiveAccessLog(_getShaForAtsign('@alice'));
      await accessLogInstance.insert('@bob', 'lookup',
          lookupKey: '@bob:mobile@alice');
      await accessLogInstance.insert('@bob', 'lookup',
          lookupKey: '@bob:mobile@alice');
      await accessLogInstance.insert('@colin', 'lookup',
          lookupKey: '@colin:mobile@alice');
      await accessLogInstance.insert('@colin', 'lookup',
          lookupKey: '@colin:mobile@alice');
      await accessLogInstance.insert('@colin', 'lookup',
          lookupKey: '@colin:mobile@alice');
      var mostVisitedKeys = accessLogInstance.mostVisitedKeys(2);
      assert(mostVisitedKeys.length == 2);
      assert(mostVisitedKeys['@colin:mobile@alice'] == 3);
      assert(mostVisitedKeys['@bob:mobile@alice'] == 2);
    });

    test('Test to verify most visited atSign', () async {
      var accessLogInstance = await AtAccessLogManagerImpl.getInstance()
          .getHiveAccessLog(_getShaForAtsign('@alice'));
      await accessLogInstance.insert('@bob', 'pol');
      await accessLogInstance.insert('@bob', 'pol');
      await accessLogInstance.insert('@colin', 'pol');
      await accessLogInstance.insert('@colin', 'pol');
      await accessLogInstance.insert('@colin', 'pol');
      var mostVisitedAtSign = accessLogInstance.mostVisitedAtSigns(2);
      assert(mostVisitedAtSign.length == 2);
      assert(mostVisitedAtSign['@colin'] == 3);
      assert(mostVisitedAtSign['@bob'] == 2);
    });

    tearDown(() async => await tearDownFunc());
  });
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir) async {
  await AtAccessLogManagerImpl.getInstance()
      .getHiveAccessLog(_getShaForAtsign('@alice'), accessLogPath: storageDir);
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@alice');
  var persistenceManager = secondaryPersistenceStore.getPersistenceManager();
  await persistenceManager.init('@alice', storageDir);
  var keyStore;
  if (persistenceManager is HivePersistenceManager) {
    await persistenceManager.openVault('@alice');
  }
//  persistenceManager.scheduleKeyExpireTask(1); //commented this line for coverage test
  keyStore = secondaryPersistenceStore.getSecondaryKeyStore();
  var keyStoreManager = secondaryPersistenceStore.getSecondaryKeyStoreManager();
  keyStoreManager.keyStore = keyStore;
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  await AtAccessLogManagerImpl.getInstance().close();
}

String _getShaForAtsign(String atsign) {
  var bytes = utf8.encode(atsign);
  return sha256.convert(bytes).toString();
}
