import 'package:at_utils/at_logger.dart';

class RedisKeyStoreHelper {
  static final RedisKeyStoreHelper _singleton = RedisKeyStoreHelper._internal();

  RedisKeyStoreHelper._internal();

  factory RedisKeyStoreHelper.getInstance() {
    return _singleton;
  }

  final logger = AtSignLogger('RedisKeyStoreHelper');

}