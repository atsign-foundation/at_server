import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class AtAccessLogManagerImpl implements AtAccessLogManager {
  static final AtAccessLogManagerImpl _singleton =
      AtAccessLogManagerImpl._internal();

  AtAccessLogManagerImpl._internal();

  @Deprecated(
      'Use HiveAtPersistenceFactory (or any AtPersistenceFactory) and '
      'inject `bundle.accessLog` instead. Will be removed in the next '
      'major release.')
  factory AtAccessLogManagerImpl.getInstance() {
    return _singleton;
  }

  final Map<String, HiveAtAccessLog> _accessLogMap = {};

  @override
  Future<HiveAtAccessLog?> getAccessLog(String atSign,
      {String? accessLogPath}) async {
    if (!_accessLogMap.containsKey(atSign)) {
      var accessLogKeyStore = AccessLogKeyStore(atSign);
      await accessLogKeyStore.init(accessLogPath!);
      _accessLogMap[atSign] = HiveAtAccessLog(accessLogKeyStore);
    }
    return _accessLogMap[atSign];
  }

  Future<void> close() async {
    await Future.forEach(
        _accessLogMap.values, (HiveAtAccessLog atAccessLog) => atAccessLog.close());
    _accessLogMap.clear();
  }

  /// Clears the internal per-atSign cache without calling close() on the
  /// entries. Used by [HiveAtPersistenceFactory] when the entries have
  /// already been closed via shared references.
  void clear() {
    _accessLogMap.clear();
  }
}
