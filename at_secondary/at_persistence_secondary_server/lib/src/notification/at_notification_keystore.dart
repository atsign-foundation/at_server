import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification_callback.dart';
import 'package:at_utf7/at_utf7.dart';
import 'package:hive/hive.dart';

/// Class to initialize, put and get entries into [AtNotificationKeystore]
class AtNotificationKeystore implements SecondaryKeyStore {
  static final AtNotificationKeystore _singleton =
      AtNotificationKeystore._internal();

  AtNotificationKeystore._internal();

  late String _boxName;
  factory AtNotificationKeystore.getInstance() {
    return _singleton;
  }

  bool _register = false;

  Future<void> init(storagePath, boxName) async {
    Hive.init(storagePath);
    _boxName = boxName;
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
    await Hive.openLazyBox(boxName);
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
    return await _getBox().get(key);
  }

  @override
  Future put(key, value,
      {int? time_to_live,
      int? time_to_born,
      int? time_to_refresh,
      bool? isCascade,
      bool? isBinary,
      bool? isEncrypted,
      String? dataSignature}) async {
    await _getBox().put(key, value);
    AtNotificationCallback.getInstance().invokeCallbacks(value);
  }

  @override
  Future create(key, value,
      {int? time_to_live,
      int? time_to_born,
      int? time_to_refresh,
      bool? isCascade,
      bool? isBinary,
      bool? isEncrypted,
      String? dataSignature}) async {
    // TODO: implement deleteExpiredKeys
    throw UnimplementedError();
  }

  @override
  Future<bool> deleteExpiredKeys() async {
    // TODO: implement deleteExpiredKeys
    return Future.value(false);
  }

  @override
  Future<List<dynamic>> getExpiredKeys() async {
    // TODO: implement getExpiredKeys
    return <dynamic>[];
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
    await _getBox().delete(key);
  }

  Future<void> close() async {
    if (_getBox().isOpen) {
      await _getBox().close();
    }
  }

  Future<Map>? _toMap() async {
    var notificationLogMap = {};
    var keys = _getBox().keys;
    var value;
    await Future.forEach(keys, (key) async {
      value = await _getBox().get(key);
      notificationLogMap.putIfAbsent(key, () => value);
    });
    return notificationLogMap;
  }

  LazyBox _getBox() {
    return Hive.lazyBox(_boxName);
  }
}
