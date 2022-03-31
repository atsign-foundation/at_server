import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_base.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification_callback.dart';
import 'package:at_utf7/at_utf7.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';

/// Class to initialize, put and get entries into [AtNotificationKeystore]
class AtNotificationKeystore
    with HiveBase<AtNotification?>
    implements SecondaryKeyStore, AtLogType {
  static final AtNotificationKeystore _singleton =
      AtNotificationKeystore._internal();

  AtNotificationKeystore._internal();
  late String currentAtSign;
  late String _boxName;
  final _notificationExpiryInHours = 72;
  factory AtNotificationKeystore.getInstance() {
    return _singleton;
  }

  final _logger = AtSignLogger('AtNotificationKeystore');

  bool _register = false;

  @override
  Future<void> initialize() async {
    _boxName = 'notifications_' + AtUtils.getShaForAtSign(currentAtSign);
    if (!_register) {
      Hive.registerAdapter(AtNotificationAdapter());
      Hive.registerAdapter(OperationTypeAdapter());
      Hive.registerAdapter(NotificationTypeAdapter());
      Hive.registerAdapter(NotificationStatusAdapter());
      Hive.registerAdapter(NotificationPriorityAdapter());
      Hive.registerAdapter(MessageTypeAdapter());
      if (!Hive.isAdapterRegistered(AtMetaDataAdapter().typeId)) {
        Hive.registerAdapter(AtMetaDataAdapter());
      }
      _register = true;
    }
    await super.openBox(_boxName);
  }

  bool isEmpty() {
    return _getBox().isEmpty;
  }

  /// Returns a list of atNotification sorted on notification date time.
  Future<List> getValues() async {
    var returnList = [];
    var notificationLogMap = await _toMap();
    returnList = notificationLogMap!.values.toList();
    returnList.sort(
        (k1, k2) => k1.notificationDateTime.compareTo(k2.notificationDateTime));
    return returnList;
  }

  @override
  Future<AtNotification?> get(key) async {
    return await getValue(key);
  }

  @override
  Future<dynamic> put(key, value,
      {int? time_to_live,
      int? time_to_born,
      int? time_to_refresh,
      bool? isCascade,
      bool? isBinary,
      bool? isEncrypted,
        String? dataSignature,
        String? sharedKeyEncrypted,
        String? publicKeyChecksum}) async {
    await _getBox().put(key, value);
    AtNotificationCallback.getInstance().invokeCallbacks(value);
  }

  @override
  Future<dynamic> create(key, value,
      {int? time_to_live,
      int? time_to_born,
      int? time_to_refresh,
      bool? isCascade,
      bool? isBinary,
      bool? isEncrypted,
        String? dataSignature,
        String? sharedKeyEncrypted,
        String? publicKeyChecksum}) async {
    throw UnimplementedError();
  }

  @override
  Future<bool> deleteExpiredKeys() async {
    var result = true;
    try {
      var expiredKeys = await getExpiredKeys();
      if (expiredKeys.isNotEmpty) {
        _logger.finer('expired keys: $expiredKeys');
        await Future.forEach(expiredKeys, (expiredKey) async {
          await remove(expiredKey);
        });
      } else {
        _logger.finer('notification key store. No expired notifications');
      }
    } on Exception catch (e) {
      result = false;
      _logger.severe('Exception in deleteExpired keys: ${e.toString()}');
      throw DataStoreException(
          'exception in deleteExpiredKeys: ${e.toString()}');
    } on HiveError catch (error) {
      _logger.severe('HiveKeystore get error: $error');
      throw DataStoreException(error.message);
    }
    return result;
  }

  @override
  Future<List<dynamic>> getExpiredKeys() async {
    var expiredKeys = <String>[];
    try {
      var keys = _getBox().keys;
      var expired = [];
      await Future.forEach(keys, (key) async {
        var value = await get(key);
        if (value != null && value.isExpired()) {
          expired.add(key);
        }
        if (value?.expiresAt == null &&
            DateTime.now()
                    .toUtc()
                    .difference(value!.notificationDateTime!)
                    .inHours >=
                _notificationExpiryInHours) {
          var newNotification = (AtNotificationBuilder()
                ..id = value.id
                ..fromAtSign = value.fromAtSign
                ..notificationDateTime = value.notificationDateTime
                ..toAtSign = value.toAtSign
                ..notification = value.notification
                ..type = value.type
                ..opType = value.opType
                ..messageType = value.messageType
                ..expiresAt = value.notificationDateTime
                ..priority = value.priority
                ..notificationStatus = value.notificationStatus
                ..retryCount = value.retryCount
                ..strategy = value.strategy
                ..notifier = value.notifier
                ..depth = value.depth
                ..atValue = value.atValue
                ..atMetaData = value.atMetadata
                ..ttl = value.ttl)
              .build();
          put(key, newNotification);
        }
      });

      expired.forEach((key) => expiredKeys.add(Utf7.encode(key)));
    } on Exception catch (e) {
      _logger.severe('exception in hive get expired keys:${e.toString()}');
      throw DataStoreException('exception in getExpiredKeys: ${e.toString()}');
    } on HiveError catch (error) {
      _logger.severe('HiveKeystore get error: $error');
      throw DataStoreException(error.message);
    }
    return expiredKeys;
  }

  @override
  List getKeys({String? regex}) {
    var keys = <String>[];
    var encodedKeys;

    if (_getBox().keys.isEmpty) {
      return [];
    }
    // If regular expression is not null or not empty, filter keys on regular expression.
    if (regex != null && regex.isNotEmpty) {
      encodedKeys = _getBox().keys.where(
          (element) => Utf7.decode(element).toString().contains(RegExp(regex)));
    } else {
      encodedKeys = _getBox().keys.toList();
    }
    encodedKeys?.forEach((key) => keys.add(Utf7.decode(key)));
    return encodedKeys;
  }

  @override
  Future remove(key) async {
    assert(key != null);
    await _getBox().delete(key);
  }

  Future<Map>? _toMap() async {
    var notificationLogMap = {};
    var keys = _getBox().keys;
    var value;
    await Future.forEach(keys, (key) async {
      value = await getValue(key);
      notificationLogMap.putIfAbsent(key, () => value);
    });
    return notificationLogMap;
  }

  BoxBase _getBox() {
    return super.getBox();
  }

  @override
  bool isKeyExists(String key) {
    return _getBox().keys.contains(key);
  }

  @override
  Future<void> delete(expiredKeys) async {
    try {
      if (expiredKeys.isNotEmpty) {
        _logger.finer('expired keys: $expiredKeys');
        await Future.forEach(expiredKeys, (expiredKey) async {
          await remove(expiredKey);
        });
      } else {
        _logger.finer('notification key store. No expired notifications');
      }
    } on Exception catch (e) {
      _logger.severe('Exception in deleteExpired keys: ${e.toString()}');
      throw DataStoreException(
          'exception in deleteExpiredKeys: ${e.toString()}');
    } on HiveError catch (error) {
      _logger.severe('HiveKeystore get error: $error');
      throw DataStoreException(error.message);
    }
  }

  @override
  int entriesCount() {
    return _getBox().keys.length;
  }

  @override
  Future<List> getExpired(int expiryInDays) async {
    return await getExpiredKeys();
  }

  @override
  Future getMeta(key) {
    throw UnimplementedError();
  }

  @override
  Future putAll(key, value, metadata) {
    throw UnimplementedError();
  }

  @override
  Future putMeta(key, metadata) {
    throw UnimplementedError();
  }

  @override
  Future<List> getFirstNEntries(int N) {
    throw UnimplementedError();
  }

  @override
  Future<int> latestCommitIdForKey(key) {
    throw UnsupportedError('Notification Keystore does not use a commit log');
  }
}
