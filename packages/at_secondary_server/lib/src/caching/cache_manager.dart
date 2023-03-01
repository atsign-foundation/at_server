import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_utils/at_logger.dart';

class AtCacheManager {
  final String atSign;
  final SecondaryKeyStore<String, AtData?, AtMetaData?> keyStore;
  final OutboundClientManager outboundClientManager;

  final logger = AtSignLogger('AtCacheManager');

  AtCacheManager(this.atSign, this.keyStore, this.outboundClientManager);

  /// Returns a List of keyNames of all cached records due to refresh
  Future<List<String>> getKeyNamesToRefresh() async {
    List<String> keysList = keyStore.getKeys(regex: CACHED);
    var cachedKeys = <String>[];
    var now = DateTime.now().toUtc();
    var nowInEpoch = now.millisecondsSinceEpoch;
    var itr = keysList.iterator;
    while (itr.moveNext()) {
      var key = itr.current;
      AtMetaData? metadata = await keyStore.getMeta(key);

      if (metadata == null) {
        // Should never be true. Log a warning.
        logger.warning('getKeyNamesToRefresh: Null metadata for $key');
        continue;
      }

      if (metadata.ttr == null || metadata.ttr == 0) {
        // ttr of null or 0 means "do not cache"
        // Technically, we should NEVER have this situation
        // However, we do, because of history
      }

      // If metadata.availableAt is in the future, key's TTB is not met, we should not refresh
      if (metadata.availableAt != null &&
          metadata.availableAt!.millisecondsSinceEpoch >= nowInEpoch) {
        continue;
      }

      // If metadata.expiresAt is in the past, key's TTL is expired, we should not refresh.
      // TODO Should we actually remove it at this point?
      if (metadata.expiresAt != null &&
          nowInEpoch >= metadata.expiresAt!.millisecondsSinceEpoch) {
        continue;
      }

      // Is this cached key supposed to auto-refresh? -1 means no, you can cache indefinitely.
      if (metadata.ttr == -1) {
        continue;
      }

      // Is it time to refresh yet?
      if (metadata.refreshAt != null && metadata.refreshAt!.millisecondsSinceEpoch > nowInEpoch) {
        continue;
      }

      cachedKeys.add(key);
    }
    return cachedKeys;
  }

  /// Looks up the value of a key on another atServer. Figures out whether to use
  /// * an unauthenticated lookup (for a cachedKeyName / that starts with `cached:public:`)
  /// * or an authenticated lookup (for a cachedKeyName / that starts with `cached:@myAtSign:`)
  ///
  /// If [maintainCache] is set to true, then remoteLookUp will update the cache as required:
  ///   * If we get a 'null' response, delete from the cache
  ///   * If we get KeyNotFoundException, delete from the cache
  ///   * If we get a valid response, update the cache
  ///
  /// Note: This method will always use the lookup operation 'all', so that it can fully update the cache.
  Future<AtData?> remoteLookUp(String cachedKeyName, {bool maintainCache = false}) async {
    logger.info("remoteLookUp: $cachedKeyName");
    if (!cachedKeyName.startsWith('cached:')) {
      throw IllegalArgumentException('AtCacheManager.remoteLookUp called with invalid cachedKeyName $cachedKeyName');
    }

    String? remoteResponse;
    String? remoteKeyName;
    try {
      if (cachedKeyName.startsWith('cached:public:')) {
        remoteKeyName = cachedKeyName.replaceAll('cached:public:', '');
        remoteResponse = await _remoteLookUp('all:$remoteKeyName', isHandShake: false);
      } else if (cachedKeyName.startsWith('cached:$atSign')) {
        remoteKeyName = cachedKeyName.replaceAll('cached:$atSign:', '');
        remoteResponse = await _remoteLookUp('all:$remoteKeyName', isHandShake: true);
      } else {
        throw IllegalArgumentException('remoteLookup called with invalid cachedKeyName $cachedKeyName');
      }
    } on KeyNotFoundException {
      if (maintainCache) {
        logger.info('remoteLookUp: KeyNotFoundException while looking up $remoteKeyName'
            ' - removing $cachedKeyName from cache');
        await delete(cachedKeyName);
      } else {
        logger.info('remoteLookUp: KeyNotFoundException while looking up $remoteKeyName'
            ' - but maintainCache is false, so leaving $cachedKeyName in cache');
      }
      rethrow;
    }

    // OutboundMessageListener will throw exceptions upon any 'error:' responses, malformed response, or timeouts
    // So we only have to worry about 'data:' response here
    remoteResponse = remoteResponse!.replaceAll('data:', '');
    if (remoteResponse == 'null') {
      if (maintainCache) {
        logger.info('remoteLookUp: String value of "null" response while looking up $remoteKeyName'
            ' - removing $cachedKeyName from cache');
        await delete(cachedKeyName);
      } else {
        logger.info('remoteLookUp: String value of "null" response while looking up $remoteKeyName'
            ' - but maintainCache is false, so leaving $cachedKeyName in cache');
      }
      throw KeyNotFoundException("remoteLookUp: remote atServer returned String value 'null' for $remoteKeyName");
    }

    AtData atData = AtData().fromJson(jsonDecode(remoteResponse));

    // We only cache other people's stuff
    if (cachedKeyName.endsWith(atSign)) {
      // TODO Why would we ever do a 'remote' lookup on our own stuff?
      logger.warning('Bizarrely, we did a remoteLookup of our own data $remoteKeyName');
    } else {
      if (maintainCache) {
        logger.info('remoteLookUp: Successfully looked up $remoteKeyName - updating cache for $cachedKeyName');
        if (atData.metaData == null) {
          // No metaData? Should never happen. don't cache

        } else if (atData.metaData!.ttr == 0) {
          // ttr of zero means do not cache

        } else {
          // We're good to cache it
          await put(cachedKeyName, atData);
        }
      } else {
        logger.info('remoteLookUp: Successfully looked up $remoteKeyName - but maintainCache is false, so not adding to cache');
      }
    }

    return atData;
  }

  /// Fetch the currently cached value, if any.
  /// * If [applyMetadataRules] is false, return whatever is found in the [keyStore]
  /// * If [applyMetadataRules] is true, then use [SecondaryUtil.isActiveKey] to check
  ///   * Is this record 'active' i.e. it is non-null, it's been 'born', and it is still 'alive'
  ///   * Has this record been
  Future<AtData?> get(String cachedKeyName, {required bool applyMetadataRules}) async {
    logger.info("get: $cachedKeyName");
    if (!cachedKeyName.startsWith('cached:')) {
      throw IllegalArgumentException('AtCacheManager.get called with invalid cachedKeyName $cachedKeyName');
    }

    if (!keyStore.isKeyExists(cachedKeyName)) {
      return null;
    }
    var atData = await keyStore.get(cachedKeyName);
    if (atData == null) {
      return null;
    }

    // If not applying the metadata rules, just return what we found
    if (! applyMetadataRules) {
      return atData;
    }

    var isActive = SecondaryUtil.isActiveKey(atData);
    if (!isActive) {
      return null;
    }

    // ttr of -1 means the recipient has permission to cache it forever
    if (atData.metaData?.ttr == -1) {
      return atData;
    }
    var refreshAt = atData.toJson()['metaData']['refreshAt'];
    if (refreshAt != null) {
      refreshAt = DateTime.parse(refreshAt).toUtc().millisecondsSinceEpoch;
      var now = DateTime.now().toUtc().millisecondsSinceEpoch;
      if (now <= refreshAt) {
        return atData;
      }
    }
    return null;
  }

  /// Delete cached record
  Future<void> delete(String cachedKeyName) async {
    logger.info("delete: $cachedKeyName");
    if (!cachedKeyName.startsWith('cached:')) {
      throw IllegalArgumentException('AtCacheManager.delete called with invalid cachedKeyName $cachedKeyName');
    }

    try {
      await keyStore.remove(cachedKeyName);
    } on KeyNotFoundException {
      logger.warning('remove operation - key $cachedKeyName does not exist in keystore');
    }
  }


  /// Update the cached data.
  Future<void> put(String cachedKeyName, AtData atData) async {
    logger.info("put: $cachedKeyName");
    if (!cachedKeyName.startsWith('cached:')) {
      throw IllegalArgumentException('AtCacheManager.put called with invalid cachedKeyName $cachedKeyName');
    }
    if (cachedKeyName.endsWith(atSign)) {
      throw IllegalArgumentException('AtCacheManager.put called with invalid cachedKeyName $cachedKeyName - we do not re-cache our own data');
    }
    atData.metaData!.ttr ??= -1;
    await keyStore.put(cachedKeyName, atData, time_to_refresh: atData.metaData!.ttr);
  }

  /// Does the remote lookup - returns the atProtocol string which it receives
  Future<String?> _remoteLookUp(String key, {required bool isHandShake}) async {
    logger.info("_remoteLookup: $key");
    var index = key.indexOf('@');
    var otherAtSign = key.substring(index);
    var outBoundClient = outboundClientManager.getClient(
        otherAtSign, DummyInboundConnection(),
        isHandShake: isHandShake);
    // Need not connect again if the client's handshake is already done

    if (!outBoundClient.isHandShakeDone) {
      var connectResult =
      await outBoundClient.connect(handshake: isHandShake);
      logger.finer('connect result: $connectResult');
    }
    return await outBoundClient.lookUp(key, handshake: isHandShake);
  }
}
