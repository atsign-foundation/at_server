import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_utils/at_logger.dart';
import 'package:cron/cron.dart';

class AtRefreshJob {
  String _atSign;
  var keyStore;
  var _cron;

  AtRefreshJob(this._atSign) {
    var secondaryPersistenceStore =
        SecondaryPersistenceStoreFactory.getInstance()
            .getSecondaryPersistenceStore(_atSign);
    keyStore = secondaryPersistenceStore.getSecondaryKeyStore();
  }

  final logger = AtSignLogger('AtRefreshJob');

  /// Returns the list of cached keys
  Future<List<dynamic>> _getCachedKeys() async {
    var keysList = await keyStore.getKeys(regex: CACHED);
    // If no keys to return
    if (keysList == null) {
      return null;
    }

    var cachedKeys = [];
    var now = DateTime.now();
    var nowInEpoch = now.millisecondsSinceEpoch;
    var itr = keysList.iterator;
    while (itr.moveNext()) {
      var key = itr.current;
      var metadata = await keyStore.getMeta(key);
      if (metadata.refreshAt.millisecondsSinceEpoch > nowInEpoch) {
        continue;
      }
      // If metadata.availableAt is greater is lastRefreshedAtInEpoch, key's TTB is not met.
      if (metadata.availableAt != null &&
          metadata.availableAt.millisecondsSinceEpoch >= nowInEpoch) {
        continue;
      }
      // If metadata.expiresAt is less than nowInEpoch, key's TTL is expired.
      if (metadata.expiresAt != null &&
          nowInEpoch >= metadata.expiresAt.millisecondsSinceEpoch) {
        continue;
      }
      cachedKeys.add(key);
    }
    return cachedKeys;
  }

  /// Returns of the value of the key from the another secondary server.
  /// Key to lookup on the another secondary server.
  /// Future<String> value of the key.
  Future<String> _lookupValue(String key) async {
    var index = key.indexOf('@');
    var atSign = key.substring(index);
    var lookupResult;
    var outBoundClient = OutboundClientManager.getInstance()
        .getClient(atSign, DummyInboundConnection.getInstance());
    // Need not connect again if the client's handshake is already done
    try {
      if (!outBoundClient.isHandShakeDone) {
        var connectResult = await outBoundClient.connect();
        logger.finer('connect result: ${connectResult}');
      }
      lookupResult = await outBoundClient.lookUp(key);
    } catch (exception) {
      logger.severe(
          'Exception while refreshing cached key ${exception.toString()}');
    }
    return lookupResult;
  }

  /// Updates the cached key with the new value.
  void _updateCachedValue(var newValue, var oldValue, var element) async {
    newValue = newValue.replaceAll('data:', '');
    // When the value of the lookup key is 'data:null', on trimming 'data:',
    // If new value is 'null' or not equal to old value, update the old value with new value.
    if (newValue != 'null' && oldValue.data != newValue) {
      var atData = AtData();
      atData.data = newValue;
      atData.metaData = oldValue.metaData;
      await keyStore.put(element, atData);
    }
  }

  /// The refresh job
  void _refreshJob(int runFrequencyHours) async {
    var keysToRefresh = await _getCachedKeys();
    if (keysToRefresh == null) {
      return;
    }
    var lookupKey;
    var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    var itr = keysToRefresh.iterator;
    while (itr.moveNext()) {
      var element = itr.current;
      lookupKey = element;
      lookupKey = lookupKey.replaceAll('$CACHED:$atSign:', '');
      var newValue = await _lookupValue(lookupKey);
      // Nothing to do. Just return
      if (newValue == null) {
        return;
      }
      await logger.finest('lookup value of $lookupKey is $newValue');
      var oldValue = await keyStore.get(element);
      await _updateCachedValue(newValue, oldValue, element);
    }
  }

  /// The Cron Job which runs at a frequent time interval.
  void scheduleRefreshJob(int runJobHour) {
    logger.finest('scheduleKeyRefreshTask starting cron job.');
    _cron = Cron();
    _cron.schedule(Schedule.parse('0 ${runJobHour} * * *'), () async {
      logger.finest('Scheduled Refresh Job started');
      await _refreshJob(runJobHour);
      logger.finest('scheduled Refresh Job completed');
    });
  }

  void close() {
    _cron.close();
  }
}
