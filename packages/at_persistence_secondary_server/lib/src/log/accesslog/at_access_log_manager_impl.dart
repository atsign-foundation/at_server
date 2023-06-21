import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class AtAccessLogManagerImpl implements AtAccessLogManager {
  static final AtAccessLogManagerImpl _singleton =
      AtAccessLogManagerImpl._internal();

  AtAccessLogManagerImpl._internal();

  factory AtAccessLogManagerImpl.getInstance() {
    return _singleton;
  }

  final Map<String, AtAccessLog> _accessLogMap = {};

  @override
  Future<AtAccessLog?> getAccessLog(String atSign,
      {String? accessLogPath}) async {
    if (!_accessLogMap.containsKey(atSign)) {
      var accessLogKeyStore = AccessLogKeyStore(atSign);
      await accessLogKeyStore.init(accessLogPath!);
      _accessLogMap[atSign] = AtAccessLog(accessLogKeyStore);
    }
    return _accessLogMap[atSign];
  }

  Future<void> close() async {
    await Future.forEach(
        _accessLogMap.values, (AtAccessLog atAccessLog) => atAccessLog.close());
    _accessLogMap.clear();
  }
}
