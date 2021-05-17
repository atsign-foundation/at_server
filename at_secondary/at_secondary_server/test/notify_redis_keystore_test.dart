import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:dartis/dartis.dart' as redis;

Future<void> main() async {
  var redisUrl = 'redis://localhost:6379';
  var redisPassword =  'mypassword';
  var redis_client = await redis.Client.connect(redisUrl);
  // Runs some commands.
  var redis_commands = redis_client.asCommands<String, String>();
  await redis_commands.auth(redisPassword);
  await redis_commands.select(3);
  var atNotification = (AtNotificationBuilder()
    ..id = '123'
    ..fromAtSign = '@alice'
    ..notificationDateTime = DateTime.now().toUtc()
    ..toAtSign = '@alice'
    ..notification = 'self_received_notification'
    ..type = NotificationType.received
    ..opType = OperationType.update)
      .build();
  await redis_commands.set('@alice', json.encode(atNotification.toJson()));

  var result = await redis_commands.get('@alice');
  var notification = AtNotification.fromJson(json.decode(result));
  print(notification);
}