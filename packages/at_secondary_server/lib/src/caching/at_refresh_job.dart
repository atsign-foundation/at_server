import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_utils/at_logger.dart';
import 'package:cron/cron.dart';

class AtRefreshJob {
  final String atSign;
  final SecondaryKeyStore<String, AtData?, AtMetaData?> keyStore;
  late Cron _cron;
  final OutboundClientManager outboundClientManager;

  AtRefreshJob(this.atSign, this.keyStore, this.outboundClientManager);

  final logger = AtSignLogger('AtRefreshJob');

  /// Returns the list of cached keys
  Future<List<String>> _getCachedKeys() async {
    List<String> keysList = keyStore.getKeys(regex: CACHED);
    var cachedKeys = <String>[];
    var now = DateTime.now().toUtc();
    var nowInEpoch = now.millisecondsSinceEpoch;
    var itr = keysList.iterator;
    while (itr.moveNext()) {
      var key = itr.current;
      AtMetaData? metadata = await keyStore.getMeta(key);
      // Setting metadata.ttr = -1 represents not to updated the cached key.
      // Hence skipping the key from refresh job.
      if (metadata == null || metadata.ttr == -1) {
        continue;
      }
      if (metadata.ttr != -1 &&
          metadata.refreshAt!.millisecondsSinceEpoch > nowInEpoch) {
        continue;
      }
      // If metadata.availableAt is greater is lastRefreshedAtInEpoch, key's TTB is not met.
      if (metadata.availableAt != null &&
          metadata.availableAt!.millisecondsSinceEpoch >= nowInEpoch) {
        continue;
      }
      // If metadata.expiresAt is less than nowInEpoch, key's TTL is expired.
      if (metadata.expiresAt != null &&
          nowInEpoch >= metadata.expiresAt!.millisecondsSinceEpoch) {
        continue;
      }
      cachedKeys.add(key);
    }
    return cachedKeys;
  }

  /// Returns of the value of the key from the another secondary server.
  /// Key to lookup on the another secondary server.
  /// Future<String> value of the key.
  Future<String?> _lookupValue(String key, {bool isHandShake = true}) async {
    var index = key.indexOf('@');
    var otherAtSign = key.substring(index);
    var outBoundClient = outboundClientManager.getClient(
        otherAtSign, DummyInboundConnection(),
        isHandShake: isHandShake)!;
    // Need not connect again if the client's handshake is already done

    if (!outBoundClient.isHandShakeDone) {
      var connectResult =
      await outBoundClient.connect(handshake: isHandShake);
      logger.finer('connect result: $connectResult');
    }
    return await outBoundClient.lookUp(key, handshake: isHandShake);
  }

  /// Updates the cached key with the new value.
  Future<void> _updateCachedValue(
      String? newValue, AtData? oldValue, var cachedKeyName) async {
    var atData = AtData();
    atData.data = newValue;
    atData.metaData = oldValue?.metaData;
    await keyStore.put(cachedKeyName, atData);
  }

  /// The refresh job
  Future<void> _refreshJob(int runFrequencyHours) async {
    var keysToRefresh = await _getCachedKeys();
    String lookupKey;
    var itr = keysToRefresh.iterator;
    while (itr.moveNext()) {
      var cachedKeyName = itr.current;
      lookupKey = cachedKeyName;
      String? newValue;

      try {
        if (lookupKey.startsWith('cached:public:')) {
          lookupKey = lookupKey.replaceAll('cached:public:', '');
          newValue = await _lookupValue(lookupKey, isHandShake: false);
        } else {
          lookupKey = lookupKey.replaceAll('$CACHED:$atSign:', '');
          newValue = await _lookupValue(lookupKey);
        }
      } catch (e) {
        logger.info("Exception while looking up $lookupKey : $e");
        continue;
      }
      // If new value is null, do nothing. Continue for next key.
      if (newValue == null) {
        continue;
      }
      newValue = newValue.replaceAll('data:', '');
      // If new value is 'null' or empty
      // do not update the cached key. Do nothing. Continue for next key.
      if (newValue.trim().isEmpty || newValue == 'null') {
        logger.finest(
            'value not found for $lookupKey. Failed updating the cached key');
        continue;
      }
      // If old value and new value are equal, then do not update;
      // Continue for next key.
      var oldValue = await keyStore.get(cachedKeyName);
      if (oldValue?.data == newValue) {
        logger.finest(
            '$lookupKey cached value is same as looked-up value. Not updating the cached key');
        continue;
      }
      logger.finest('Updated the cached key value of $lookupKey with $newValue');
      await _updateCachedValue(newValue, oldValue, cachedKeyName);
      //Update the refreshAt date for the next interval.
      var atMetadata = AtMetadataBuilder(ttr: oldValue!.metaData!.ttr).build();
      await keyStore.putMeta(cachedKeyName, atMetadata);
    }
  }

  /// The Cron Job which runs at a frequent time interval.
  void scheduleRefreshJob(int runJobHour) {
    logger.finest('scheduleKeyRefreshTask runs at $runJobHour hours');
    _cron = Cron();
    _cron.schedule(Schedule.parse('0 $runJobHour * * *'), () async {
      logger.finest('Scheduled Refresh Job started');
      await _refreshJob(runJobHour);
      logger.finest('scheduled Refresh Job completed');
    });
  }

  void close() {
    _cron.close();
  }
}
