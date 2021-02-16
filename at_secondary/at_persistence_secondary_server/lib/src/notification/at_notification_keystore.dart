import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification_callback.dart';
import 'package:hive/hive.dart';
import 'package:utf7/utf7.dart';

/// Class to initialize, put and get entries into [AtNotificationKeystore]
class AtNotificationKeystore implements SecondaryKeyStore {
  static final AtNotificationKeystore _singleton =
      AtNotificationKeystore._internal();

  AtNotificationKeystore._internal();

  factory AtNotificationKeystore.getInstance() {
    return _singleton;
  }

  Box _box;

  bool _register = false;

  void init(storagePath, boxName) async {
    Hive.init(storagePath);
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
    _box = await Hive.openBox(boxName);
  }

  bool isEmpty() {
    return _box.isEmpty;
  }

  /// Returns a list of atNotification sorted on notification date time.
  List<dynamic> getValues() {
    var returnList = [];
    returnList = _box.values.toList();
    returnList.sort(
        (k1, k2) => k1.notificationDateTime.compareTo(k2.notificationDateTime));
    return returnList;
  }

  @override
  Future<AtNotification> get(key) async {
    return await _box.get(key);
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
    await _box.put(key, value);
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
  bool deleteExpiredKeys() {
    throw UnimplementedError();
  }

  @override
  List getExpiredKeys() {
    // TODO: implement getExpiredKeys
    throw UnimplementedError();
  }

  @override
  List getKeys({String regex}) {
    var keys = <String>[];
    var encodedKeys;

    if (_box.keys.isEmpty) {
      return null;
    }
    // If regular expression is not null or not empty, filter keys on regular expression.
    if (regex != null && regex.isNotEmpty) {
      encodedKeys = _box.keys.where(
          (element) => Utf7.decode(element).toString().contains(RegExp(regex)));
    } else {
      encodedKeys = _box.keys.toList();
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
    await _box.delete(key);
  }
}
