import 'dart:async';
import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

Future<void> main(List<String> arguments) async {
  // keystore
  var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@alice')!;
  var keyStore = keyStoreManager.getSecondaryKeyStore()!;
  var atData = AtData();
  atData.data = '123';
  var result = await keyStore.create('phone@alice', atData);
  print(result);

  //commitLog keystore
  var commitLogInstance = await (AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@alice') as FutureOr<HiveAtCommitLog>);
  var hiveKey =
      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
  var committedEntry = await commitLogInstance.getEntry(hiveKey);
  print(committedEntry);

  //Notification keystore
  var storageDir = '${Directory.current.path}/example/hive';
  var notificationKeyStore = HiveAtNotificationKeystore('@alice');
  await notificationKeyStore.init(storageDir);

  var atNotification = (AtNotificationBuilder()
        ..id = '123'
        ..fromAtSign = '@alice'
        ..notificationDateTime = DateTime.now().toUtcMillisecondsPrecision()
        ..toAtSign = '@alice'
        ..notification = 'self_received_notification'
        ..type = NotificationType.received
        ..opType = OperationType.update)
      .build();
  await notificationKeyStore.put('@alice', atNotification);
  var notificationEntry = await notificationKeyStore.get('@alice');
  print(notificationEntry);
}
