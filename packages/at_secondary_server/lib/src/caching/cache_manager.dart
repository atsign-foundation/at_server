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

  /// Returns a List of keyNames of all cached records
  Future<List<String>> getCachedKeyNames() async {
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
      // If metadata.availableAt is in the future, key's TTB is not met.
      if (metadata.availableAt != null &&
          metadata.availableAt!.millisecondsSinceEpoch >= nowInEpoch) {
        continue;
      }
      // If metadata.expiresAt is in the past, key's TTL is expired.
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
  Future<AtData?> remoteLookUp(String cachedKeyName) async {
    if (!cachedKeyName.startsWith('cached:')) {
      throw IllegalArgumentException('AtCacheManager.remoteLookUp called with invalid cachedKeyName $cachedKeyName');
    }

    String? remoteResponse;
    if (cachedKeyName.startsWith('cached:public:')) {
      String remoteKeyName = cachedKeyName.replaceAll('cached:public:', '');
      remoteResponse = await _remoteLookUp('all:$remoteKeyName', isHandShake: false);
    } else if (cachedKeyName.startsWith('cached:$atSign')) {
      String remoteKeyName = cachedKeyName.replaceAll('cached:$atSign:', '');
      remoteResponse = await _remoteLookUp('all:$remoteKeyName', isHandShake: true);
    } else {
      throw IllegalArgumentException('remoteLookup called with invalid cachedKeyName $cachedKeyName');
    }

    // OutboundMessageListener will throw exceptions upon any 'error:' responses, malformed response, or timeouts
    // So we only have to worry about 'data:' response here
    remoteResponse = remoteResponse!.replaceAll('data:', '');
    if (remoteResponse == 'null') {
      return null;
    }

    return AtData().fromJson(jsonDecode(remoteResponse));
  }

  /// Fetch the currently cached value, if any.
  /// * If [applyMetadataRules] is false, return whatever is found in the [keyStore]
  /// * If [applyMetadataRules] is true, then use [SecondaryUtil.isActiveKey] to check
  ///   * Is this record 'active' i.e. it is non-null, it's been 'born', and it is still 'alive'
  ///   * Has this record been
  Future<AtData?> get(String cachedKeyName, {required bool applyMetadataRules}) async {
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
