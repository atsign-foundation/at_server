import 'dart:convert';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:dartis/dartis.dart' as redis;

Future<void> main() async {
  var redisUrl = 'redis://localhost:6379';
  var redisPassword =  'mypassword';
  var redis_client = await redis.Client.connect(redisUrl);
  // Runs some commands.
  var redis_commands = redis_client.asCommands<String, String>();
  await redis_commands.auth(redisPassword);
  await redis_commands.select(4);
  // var atNotification = (AtNotificationBuilder()
  //   ..id = '123'
  //   ..fromAtSign = '@alice'
  //   ..notificationDateTime = DateTime.now().toUtc()
  //   ..toAtSign = '@alice'
  //   ..notification = 'self_received_notification'
  //   ..type = NotificationType.received
  //   ..opType = OperationType.update)
  //     .build();
  await redis_commands.set('@alice', json.encode('{"data":"1234","metaData":{"createdBy":null,"updatedBy":null,"createdAt":"2021-05-17 08:51:56.447816Z","updatedAt":"2021-05-17 08:51:56.447816Z","availableAt":"null","expiresAt":"null","refreshAt":"null","status":"active","version":0,"ttl":null,"ttb":null,"ttr":null,"ccd":null,"isBinary":null,"isEncrypted":null,"dataSignature":null}}'));

  var result = await redis_commands.get('@alice');
  var notification = AtMetaData().fromJson(json.decode(result));
  print(notification);
}