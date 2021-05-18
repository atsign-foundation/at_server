import 'package:at_persistence_root_server/src/redis_connection_manager.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';

class RedisKeystore implements Keystore<String, String?> {
  final logger = AtSignLogger('RedisKeystore');
  @override
  Future<String?> get(String key) async {
    var atRedisConnection =
        await RedisConnectionManager.getInstance().getConnection();
    String? result = await (atRedisConnection.command.get(key));
    logger.finer('redis key $key result $result');
    RedisConnectionManager.getInstance().releaseConnection(atRedisConnection);
    return result;
  }
}
