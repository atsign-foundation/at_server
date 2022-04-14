import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/at_notification_map.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/notify_list_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_remove_verb_handler.dart';
import 'package:at_server_spec/verbs.dart';
import 'package:test/test.dart';

void main() {
  var storageDir = Directory.current.path + '/test/hive';
  late SecondaryKeyStoreManager keyStoreManager;
  group('A group of test to verify NotifyDeleteVerb', () {
    test('Test to verify notify delete getVerb', () {
      var handler = NotifyRemoveVerbHandler(null);
      var verb = handler.getVerb();
      expect(verb is NotifyRemove, true);
    });
  });

  group('A group of hive tests to verify notify delete', () {
    setUp(() async => keyStoreManager = await setUpFunc(storageDir));
    test('A test to verify notify remove', () async {
      // Notification Object
      var notificationObj = (AtNotificationBuilder()
            ..id = '122'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime = DateTime.now().subtract(Duration(days: 1))
            ..toAtSign = '@test_user_1'
            ..notification = 'key1'
            ..type = NotificationType.received)
          .build();
      await AtNotificationKeystore.getInstance().put('122', notificationObj);

      // Dummy Inbound connection
      var atConnection = InboundConnectionImpl(null, '123')
        ..metaData = (InboundConnectionMetadata()
          ..fromAtSign = '@alice'
          ..isAuthenticated = true);
      var response = Response();
      // Verify Notification is inserted into keystore
      var notifyListVerbHandler =
          NotifyListVerbHandler(keyStoreManager.getKeyStore());
      var notifyListParams = getVerbParam(NotifyList().syntax(), 'notify:list');
      await notifyListVerbHandler.processVerb(
          response, notifyListParams, atConnection);

      //Notify delete verb handler
      var notifyDeleteHandler =
          NotifyRemoveVerbHandler(keyStoreManager.getKeyStore());
      await notifyDeleteHandler.processVerb(
          response,
          getVerbParam(NotifyRemove().syntax(), 'notify:remove:122'),
          atConnection);
      expect(response.data, 'success');

      // Notify List to verify after deletion
      await notifyListVerbHandler.processVerb(
          response, notifyListParams, atConnection);
      expect(response.data, null);
    });
    tearDown(() async => await tearDownFunc());
  });
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir, {String? atsign}) async {
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(atsign ?? '@test_user_1')!;
  var persistenceManager =
      secondaryPersistenceStore.getHivePersistenceManager()!;
  await persistenceManager.init(storageDir);
//  persistenceManager.scheduleKeyExpireTask(1); //commented this line for coverage test
  var hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
  var keyStoreManager =
      secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
  keyStoreManager.keyStore = hiveKeyStore;
  hiveKeyStore.commitLog = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog(atsign ?? '@test_user_1', commitLogPath: storageDir);
  await AtAccessLogManagerImpl.getInstance()
      .getAccessLog(atsign ?? '@test_user_1', accessLogPath: storageDir);
  var notificationInstance = AtNotificationKeystore.getInstance();
  notificationInstance.currentAtSign = atsign ?? '@test_user_1';
  await notificationInstance.init(storageDir);
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  var isExists = await Directory('test/hive').exists();
  AtNotificationMap.getInstance().clear();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}
