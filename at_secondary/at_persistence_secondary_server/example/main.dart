import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

Future<void> main(List<String> arguments) async {
  // keystore
  var keyStoreManager = SecondaryKeyStoreManager.getInstance();
  keyStoreManager.init();
  var keyStore = keyStoreManager.getKeyStore();
  var atData = AtData();
  atData.data = '123';
  var result = await keyStore.create('phone', atData);
  print(result);

  //commitLog keystore
  var commitLogInstance = AtCommitLog.getInstance();
  var hiveKey =
      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
  var committedEntry = await commitLogInstance.getEntry(hiveKey);
  print(committedEntry);

  //Notification keystore
  var notificationKeyStore = AtNotificationKeystore.getInstance();
  var atNotification = AtNotification(
      '123',
      '@alice',
      DateTime.now().toUtc(),
      '@alice',
      'self_received_notification',
      NotificationType.received,
      OperationType.update);
  var notificationEntry1 = NotificationEntry([], [atNotification]);
  await notificationKeyStore.put('@alice', notificationEntry1);
  var notificationEntry = await notificationKeyStore.get('@alice');
  print(notificationEntry);
}
