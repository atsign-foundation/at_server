import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

Future<void> main(List<String> arguments) async {
  final storageDir = '${Directory.current.path}/example/hive';
  final factory = HiveAtPersistenceFactory();

  // Bring up persistence for @alice with all server-side capabilities
  // (keystore + commit log + access log + notification keystore).
  final bundle = await factory.initialize(
    '@alice',
    HivePersistenceConfig.serverDefaults(
      storagePath: '$storageDir/keys',
      commitLogPath: '$storageDir/commitLog',
      accessLogPath: '$storageDir/accessLog',
      notificationStoragePath: '$storageDir/notifications',
    ),
  );

  // Keystore
  final atData = AtData()..data = '123';
  final result = await bundle.keyValueStore.create('phone@alice', atData);
  print(result);

  // Commit log lives inside the keystore.
  final hiveKey = await bundle.keyValueStore.commitLog!
      .commit('location@alice', CommitOp.UPDATE);
  print(hiveKey);

  // Notification keystore
  final atNotification = (AtNotificationBuilder()
        ..id = '123'
        ..fromAtSign = '@alice'
        ..notificationDateTime = DateTime.now().toUtcMillisecondsPrecision()
        ..toAtSign = '@alice'
        ..notification = 'self_received_notification'
        ..type = NotificationType.received
        ..opType = OperationType.update)
      .build();
  await bundle.notificationKeystore!.put('@alice', atNotification);
  final notificationEntry = await bundle.notificationKeystore!.get('@alice');
  print(notificationEntry);

  await factory.close();
}
