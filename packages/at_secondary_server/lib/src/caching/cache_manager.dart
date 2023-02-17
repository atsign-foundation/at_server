import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_utils/at_logger.dart';

class CacheManager {
  final String atSign;
  final SecondaryKeyStore<String, AtData?, AtMetaData?> keyStore;
  final OutboundClientManager outboundClientManager;

  final logger = AtSignLogger('CacheManager');

  CacheManager(this.atSign, this.keyStore, this.outboundClientManager);

  /// Returns the list of cached keys
  Future<List<String>> getCachedKeys() async {
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

  /// Looks up the value of a key, which we've cached locally, on another secondary
  /// server. Figures out whether to use an unauthenticated lookup (for a cachedKeyName
  /// that starts with `cached:public:`) or an authenticated lookup (for a cachedKeyName
  /// that starts with `cached:@myAtSign:`)
  Future<String?> lookUpRemoteValue(String cachedKeyName) async {
    if (cachedKeyName.startsWith('cached:public:')) {
      return await _lookUpRemoteValue(cachedKeyName.replaceAll('cached:public:', ''), isHandShake: false);
    } else {
      return await _lookUpRemoteValue(cachedKeyName.replaceAll('$CACHED:$atSign:', ''), isHandShake: true);
    }
  }

  /// Fetch the currently cached value, if any
  Future<AtData?> getCachedValue(String cachedKeyName) async {
    return await keyStore.get(cachedKeyName);
  }

  /// Updates the cached key with the new value. The refreshAt metadata will also
  /// be reset; new refreshAt will be "now" plus ttr seconds
  Future<void> updateCachedValue(
      String? newValue, AtData? oldValue, var cachedKeyName) async {
    var atData = AtData();
    atData.data = newValue;
    atData.metaData = oldValue?.metaData;
    await keyStore.put(cachedKeyName, atData, time_to_refresh: oldValue!.metaData!.ttr);
  }

  Future<String?> _lookUpRemoteValue(String key, {required bool isHandShake}) async {
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
}
