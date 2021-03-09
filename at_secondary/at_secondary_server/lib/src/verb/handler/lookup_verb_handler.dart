import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';

class LookupVerbHandler extends AbstractVerbHandler {
  static Lookup lookup = Lookup();
  static final DEPTH_OF_RESOLUTION =
      AtSecondaryConfig.lookup_depth_of_resolution;

  LookupVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith(getName(VerbEnum.lookup) + ':');

  @override
  Verb getVerb() {
    return lookup;
  }

  @override

  /// Throws an [SecondaryNotFoundException] if unable to establish connection to another secondary
  /// Throws an [UnAuthorizedException] if lookup if invoked with handshake=true and without a successful handshake
  ///  Throws an [LookupException] if there is exception during lookup operation
  Future<void> processVerb(
      Response response,
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {
    InboundConnectionMetadata atConnectionMetadata = atConnection.getMetaData();
    var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    var atAccessLog =
        await AtAccessLogManagerImpl.getInstance().getAccessLog(currentAtSign);
    var fromAtSign = atConnectionMetadata.fromAtSign;
    var atSign = verbParams[AT_SIGN];
    atSign = AtUtils.formatAtSign(atSign);
    var key = verbParams[AT_KEY];
    key = '${key}${atSign}';
    var operation = verbParams[OPERATION];

    logger.finer(
        'fromAtSign : $fromAtSign \n atSign : ${atSign.toString()} \n key : $key');
    // Connection is authenticated and the currentAtSign is not atSign
    // lookUp secondary of atSign for the key
    if (atConnectionMetadata.isAuthenticated) {
      if (currentAtSign == atSign) {
        var lookup_key = currentAtSign + ':' + key;
        var lookup_value = await keyStore.get(lookup_key);
        response.data =
            SecondaryUtil.prepareResponseData(operation, lookup_value);

        //Resolving value references to correct value
        if (response.data != null &&
            response.data.contains(AT_VALUE_REFERENCE)) {
          response.data = await resolveValueReference(
              response.data.toString(), currentAtSign);
        }
        await atAccessLog.insert(atSign, lookup.name(), lookupKey: key);
      } else {
        var cachedKey = '$CACHED:$currentAtSign:$key';
        //Get cached value.
        var cachedValue = await _getCachedValue(cachedKey);
        response.data =
            SecondaryUtil.prepareResponseData(operation, cachedValue);
        //If cached value is null, lookup for the value.
        if (response.data == null || response.data == '') {
          var outBoundClient = OutboundClientManager.getInstance()
              .getClient(atSign, atConnection);
          // Need not connect again if the client's handshake is already done
          if (!outBoundClient.isHandShakeDone) {
            var connectResult = await outBoundClient.connect();
            logger.finer('connect result: ${connectResult}');
          }
          key = (operation != null) ? '${operation}:${key}' : key;
          var lookupResult = await outBoundClient.lookUp(key);
          response.data = lookupResult;
        }
      }
      return;
    }
    // If the Connection is unauthenticated form the key based on presence of "fromAtSign"
    var keyPrefix = '';
    if (!(atConnectionMetadata.isAuthenticated)) {
      keyPrefix = (fromAtSign == null || fromAtSign.isEmpty)
          ? 'public:'
          : fromAtSign + ':';
    }

    // Form the look up key
    var lookup_key = keyPrefix + key;
    logger.finer('lookup_key in lookupVerbHandler : ' + lookup_key);
    // Find the value for the key from the data store
    var lookup_data = await keyStore.get(lookup_key);
    var isActive = SecondaryUtil.isActiveKey(lookup_data);
    if (isActive) {
      // update looked up status in metadata
      if (atConnectionMetadata.isPolAuthenticated) {
        if (fromAtSign != null && fromAtSign.isNotEmpty) {
          logger.finer('key looked up:$lookup_key');
          lookup_data.metaData.sharedKeyStatus =
              getSharedKeyName(SharedKeyStatus.SHARED_WITH_LOOKED_UP);
          await keyStore.putMeta(key, lookup_data.metaData);
        }
      }
      response.data = SecondaryUtil.prepareResponseData(operation, lookup_data);
      //Resolving value references to correct values
      if (response.data != null && response.data.contains(AT_VALUE_REFERENCE)) {
        response.data = await resolveValueReference(response.data, keyPrefix);
      }
      //Omit all keys starting with '_' to record in access log
      if (!key.startsWith('_')) {
        await atAccessLog.insert(atSign, lookup.name(), lookupKey: key);
      }
      return;
    } else {
      response.data = null;
    }
  }

  /// Resolves the value references and returns correct value if value is resolved with in depth of resolution.
  /// else null is returned.
  /// @param - value : The reference value to be resolved.
  /// @param - keyPrefix : The prefix for the key: <atsign> or public.
  Future<String> resolveValueReference(String value, String keyPrefix) async {
    var resolutionCount = 1;
    var lookup_value;

    // Iterates for DEPTH_OF_RESOLUTION times to resolve the value reference.If value is still a reference, returns null.
    while (value.contains(AT_VALUE_REFERENCE) &&
        resolutionCount <= DEPTH_OF_RESOLUTION) {
      var index = value.indexOf('/');
      var keyToResolve = value.substring(index + 2, value.length);
      if (!keyPrefix.endsWith(':')) {
        keyPrefix = keyPrefix + ':';
      }
      keyToResolve = keyPrefix + keyToResolve;
      lookup_value = await keyStore.get(keyToResolve);
      value = lookup_value?.data;
      // If the value is null for a private key, searches on public namespace.
      if (value == null) {
        keyToResolve = keyToResolve.replaceAll(keyPrefix, 'public:');
        lookup_value = await keyStore.get(keyToResolve);
        value = lookup_value?.data;
      }
      resolutionCount++;
    }
    return value.contains(AT_VALUE_REFERENCE) ? null : value;
  }

  /// Gets the cached key value.
  /// key to query for value.
  /// Return value to which the specified key is mapped, or null if the key does not have value.
  Future<AtData> _getCachedValue(String key) async {
    var atData = await keyStore.get(key);
    if (atData == null) {
      return null;
    }
    var isActive = SecondaryUtil.isActiveKey(atData);
    if (!isActive) {
      return null;
    }
    if (atData.metaData.ttr != null && atData.metaData.ttr == -1) {
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
  }
}
