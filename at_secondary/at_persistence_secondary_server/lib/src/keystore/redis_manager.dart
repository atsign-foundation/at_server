import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';
import 'package:cron/cron.dart';
import 'package:dartis/dartis.dart' as redis;
import 'package:at_persistence_spec/at_persistence_spec.dart';

class RedisPersistenceManager {
  final bool _debug = false;

  var _atSign;

  RedisPersistenceManager(this._atSign);

  final logger = AtSignLogger('RedisPersistenceManager');
  var redis_client;
  var redis_commands;

  Future<bool> init() async {
    var success = false;
    try {
      // Connects.
      redis_client = await redis.Client.connect('redis://localhost:6379');
      // Runs some commands.
      redis_commands = redis_client.asCommands<String, String>();
      await redis_commands.auth('mypassword');


    } on Exception catch (e) {
      logger.severe('AtPersistence.init exception: ' + e.toString());
      throw DataStoreException(
          'Exception initializing secondary keystore manager: ${e.toString()}');
    }
    return success;
  }

  //TODO change into to Duration and construct cron string dynamically
  void scheduleKeyExpireTask(int runFrequencyMins) {
    logger.finest('scheduleKeyExpireTask starting cron job.');
    var cron = Cron();
    cron.schedule(Schedule.parse('*/${runFrequencyMins} * * * *'), () async {
      var hiveKeyStore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(this._atSign)
          .getSecondaryKeyStore();
      hiveKeyStore.deleteExpiredKeys();
    });
  }

  // Closes the secondary keystore.
  void close() {
    redis_commands.disconnect();
  }

}