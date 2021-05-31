import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_log_redis_keystore.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';

class AtAccessLogManagerImpl implements AtAccessLogManager {
  static final AtAccessLogManagerImpl _singleton =
      AtAccessLogManagerImpl._internal();

  AtAccessLogManagerImpl._internal();

  factory AtAccessLogManagerImpl.getInstance() {
    return _singleton;
  }

  var logger = AtSignLogger('AtAccessLogManagerImpl');

  final Map<String, AtAccessLog> _accessLogMap = {};

  @override
  Future<AtAccessLog> getHiveAccessLog(String atSign,
      {String accessLogPath}) async {
    if (!_accessLogMap.containsKey(atSign)) {
      var accessLogKeyStore = AccessLogKeyStore(atSign);
      await accessLogKeyStore.init(accessLogPath);
      _accessLogMap[atSign] = AtAccessLog(accessLogKeyStore);
    }
    return _accessLogMap[atSign];
  }

  @override
  Future<AtAccessLog> getRedisAccessLog(String atSign, String url,
      {String password}) async {
    if (!_accessLogMap.containsKey(atSign)) {
      var accessLogKeyStore = AccessLogRedisKeyStore();
      await accessLogKeyStore.init(url, password: password);
      _accessLogMap[atSign] = AtAccessLog(accessLogKeyStore);
    }
    return _accessLogMap[atSign];
  }

  Future<void> close() async {
    await Future.forEach(
        _accessLogMap.values, (atAccessLog) => atAccessLog.close());
    _accessLogMap.clear();
  }
}
