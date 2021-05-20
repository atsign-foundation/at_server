import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_manager.dart';
import 'package:at_utils/at_logger.dart';
import 'package:dartis/dartis.dart' as redis;
import 'package:at_persistence_spec/at_persistence_spec.dart';

class RedisPersistenceManager implements PersistenceManager {
  final bool _debug = false;

  var _atSign;

  RedisPersistenceManager(this._atSign);

  final logger = AtSignLogger('RedisPersistenceManager');
  var redis_client;
  var redis_commands;

  @override
  Future<bool> init(String atSign, String url, {String password}) async {
    var success = false;
    try {
      // Connects.
      redis_client = await redis.Client.connect(url);
      // Runs some commands.
      redis_commands = redis_client.asCommands<String, String>();
      await redis_commands.auth(password);
    } on Exception catch (e) {
      logger.severe('AtPersistence.init exception: ' + e.toString());
      throw DataStoreException(
          'Exception initializing secondary keystore manager: ${e.toString()}');
    }
    return success;
  }

  /// Redis has internal mechanism to remove the expired keys. Hence leaving the method
  /// unimplemented.
  @override
  void scheduleKeyExpireTask(int runFrequencyMins) {
    /// Not applicable
  }

  // Closes the secondary keystore.
  @override
  void close() {
    redis_commands.disconnect();
  }

  Future openVault(String atsign, {List<int> hiveSecret}) {
    // Not applicable
    return null;
  }
}
