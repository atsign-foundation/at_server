import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification_callback.dart';
import 'package:at_utils/at_logger.dart';
import 'package:utf7/utf7.dart';
import 'package:dartis/dartis.dart' as redis;

/// Class to initialize, put and get entries into [AtNotificationRedisKeystore]
class AtNotificationRedisKeystore implements SecondaryKeyStore {
  static final AtNotificationRedisKeystore _singleton =
      AtNotificationRedisKeystore._internal();

  AtNotificationRedisKeystore._internal();

  factory AtNotificationRedisKeystore.getInstance() {
    return _singleton;
  }

  bool _register = false;

  var redis_client;
  var redis_commands;
  final NOTIFICATION_LOG = 'at_notification_log';

  final logger = AtSignLogger('AtNotificationRedisKeystore');

  Future<void> init(String redisUrl, String password) async {
    try {
      // Connects.
      redis_client = await redis.Client.connect(redisUrl);
      // Runs some commands.
      redis_commands = redis_client.asCommands<String, String>();
      await redis_commands.auth(password);
      await redis_commands.select(1);
    } on Exception catch (e) {
      logger.severe('AtPersistence.init exception: ' + e.toString());
      throw DataStoreException(
          'Exception initializing secondary keystore manager: ${e.toString()}');
    }
  }

  // bool isEmpty() {
  //   return _box.isEmpty;
  // }

  /// Returns a list of atNotification sorted on notification date time.
  Future<List> getValues() async {
    var returnList = [];
    var keys = await redis_commands.keys('*');
    if (keys != null && keys.isNotEmpty) {
      returnList = await redis_commands.mget(keys: keys);
    }
    var values = <AtNotification>[];
    returnList.forEach((element) {
      values.add(AtNotification.fromJson(json.decode(element)));
    });
    values.sort(
        (k1, k2) => k1.notificationDateTime.compareTo(k2.notificationDateTime));
    return values;
  }

  @override
  Future<AtNotification> get(key) async {
    var notification;
    var result = await redis_commands.get(key);
    notification =
        (result != null) ? AtNotification.fromJson(json.decode(result)) : null;
    return notification;
  }

  @override
  Future put(key, value,
      {int time_to_live,
      int time_to_born,
      int time_to_refresh,
      bool isCascade,
      bool isBinary,
      bool isEncrypted,
      String dataSignature}) async {
    var notification_value = json.encode(value.toJson());
    await redis_commands.set(key, notification_value);
    AtNotificationCallback.getInstance().invokeCallbacks(value);
  }

  @override
  Future create(key, value,
      {int time_to_live,
      int time_to_born,
      int time_to_refresh,
      bool isCascade,
      bool isBinary,
      bool isEncrypted,
      String dataSignature}) async {
    // TODO: implement deleteExpiredKeys
    throw UnimplementedError();
  }

  @override
  Future<bool> deleteExpiredKeys() async {
    throw UnimplementedError();
  }

  @override
  Future<List> getExpiredKeys() async {
    // TODO: implement getExpiredKeys
    throw UnimplementedError();
  }

  @override
  Future<List> getKeys({String regex}) async {
    var keys = <String>[];
    var encodedKeys;

    var redis_keys = await redis_commands.keys();
    if (redis_keys.isEmpty) {
      return null;
    }
    // If regular expression is not null or not empty, filter keys on regular expression.
    if (regex != null && regex.isNotEmpty) {
      encodedKeys = redis_keys.where(
          (element) => Utf7.decode(element).toString().contains(RegExp(regex)));
    } else {
      encodedKeys = redis_keys.toList();
    }
    encodedKeys?.forEach((key) => keys.add(Utf7.decode(key)));
    return encodedKeys;
  }

  @override
  Future getMeta(key) {
    // TODO: implement getMeta
    throw UnimplementedError();
  }

  @override
  Future putAll(key, value, metadata) {
    // TODO: implement putAll
    throw UnimplementedError();
  }

  @override
  Future putMeta(key, metadata) {
    // TODO: implement putMeta
    throw UnimplementedError();
  }

  @override
  Future remove(key) async {
    assert(key != null);
    await redis_commands.del(keys: [key]);
  }

  Future<void> close() async {
    await redis_client.disconnect();
  }

  Future<bool> isEmpty() async {
    var list = await redis_commands.keys('*');
    return list.isEmpty;
  }
}
