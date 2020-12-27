import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification_entry.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification_log.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_commons/at_commons.dart';
import 'package:hive/hive.dart';
import 'package:utf7/utf7.dart';

class AtNotificationKeystore
    implements
        SecondaryKeyStore<String, NotificationEntry, NotificationEntryMeta> {
  static final AtNotificationKeystore _singleton =
      AtNotificationKeystore._internal();

  AtNotificationKeystore._internal();

  factory AtNotificationKeystore.getInstance() {
    return _singleton;
  }

  final logger = AtSignLogger('AtNotificationKeystore');

  var atNotificationLogInstance = AtNotificationLog.getInstance();

  @override
  Future create(String key, NotificationEntry notificationEntry,
      {int time_to_live,
      int time_to_born,
      int time_to_refresh,
      bool isCascade,
      bool isBinary,
      bool isEncrypted}) async {
    try {
      await atNotificationLogInstance.box
          ?.put(Utf7.encode(key), notificationEntry);
    } on Exception catch (exception) {
      logger.severe('AtNotificationKeystore create exception: $exception');
      throw DataStoreException('exception in create: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('AtNotificationKeystore error: $error');
      throw DataStoreException(error.message);
    }
  }

  /// Returning null as there is no concept of expired keys on the notification
  @override
  bool deleteExpiredKeys() {
    return null;
  }

  @override
  Future<NotificationEntry> get(String key) async {
    var value;
    try {
      value = await atNotificationLogInstance.box?.get(Utf7.encode(key));
      logger.finer('value : $value');
      return value;
    } on Exception catch (exception) {
      logger.severe('AtNotificationKeystore get exception: $exception');
      throw DataStoreException('exception in get: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('AtNotificationKeystore get error: ${error}');
      throw DataStoreException(error.message);
    }
  }

  /// Returning null as there is no concept of expired keys on the notification
  @override
  List<String> getExpiredKeys() {
    return null;
  }

  @override
  List<String> getKeys({String regex}) {
    var keys = <String>[];
    var encodedKeys;
    var atNotificationLogInstance = AtNotificationLog.getInstance();
    try {
      if (atNotificationLogInstance.box != null) {
        // If regular expression is not null or not empty, filter keys on regular expression.
        if (regex != null && regex.isNotEmpty) {
          encodedKeys = atNotificationLogInstance.box.keys
              .where((element) =>  Utf7.decode(element).toString().contains(RegExp(regex)));
        } else {
          encodedKeys = atNotificationLogInstance.box.keys.toList();
        }
        encodedKeys?.forEach((key) => keys.add(Utf7.decode(key)));
      }
    } on FormatException catch (exception) {
      logger.severe('Invalid regular expression : ${regex}');
      throw InvalidSyntaxException('Invalid syntax ${exception.toString()}');
    } on Exception catch (exception) {
      logger.severe('HiveKeystore getKeys exception: ${exception.toString()}');
      throw DataStoreException('exception in getKeys: ${exception.toString()}');
    }
    return keys;
  }

  @override
  Future<void> put(String key, NotificationEntry notificationEntry,
      {int time_to_live,
      int time_to_born,
      int time_to_refresh,
      bool isCascade,
      bool isBinary,
      bool isEncrypted}) async {
    var atNotificationLogInstance = AtNotificationLog.getInstance();
    try {
      assert(key != null);
      var existingData = await get(key);
      logger.finer('existingData : $existingData');
      var newData =
          (existingData == null) ? NotificationEntry([], []) : existingData;
      newData = atNotificationLogInstance.prepareNotificationEntry(
          existingData, notificationEntry);
      await create(key, newData);
      atNotificationLogInstance.invokeCallbacks(notificationEntry);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to notification log:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to notification log:${e.toString()}');
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      assert(key != null);
      await atNotificationLogInstance.box?.delete(key);
    } on Exception catch (exception) {
      logger.severe('AtNotificationKeystore delete exception: $exception');
      throw DataStoreException('exception in remove: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('AtNotificationKeystore delete error: $error');
      throw DataStoreException(error.message);
    }
  }

  @override
  Future<NotificationEntryMeta> getMeta(String key) {
    // TODO: implement getMeta
    return null;
  }

  @override
  Future putAll(
      String key, NotificationEntry value, NotificationEntryMeta metadata) {
    // TODO: implement putAll
    return null;
  }

  @override
  Future putMeta(String key, NotificationEntryMeta metadata) {
    // TODO: implement putMeta
    return null;
  }
}
