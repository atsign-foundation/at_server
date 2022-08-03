import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';

// Class which will process plookup (proxy lookup) verb
class ProxyLookupVerbHandler extends AbstractVerbHandler {
  static ProxyLookup pLookup = ProxyLookup();

  ProxyLookupVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  // Method to verify whether command is accepted or not
  // Input: command
  @override
  bool accept(String command) =>
      command.startsWith(getName(VerbEnum.plookup) + ':');

  // Method to return Instance of verb belongs to this VerbHandler
  @override
  Verb getVerb() {
    return pLookup;
  }

  // Method to process plookup verb
  // This will process given verb and write response to response object
  // Input: response, verbParams, AtConnection
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var atSign = verbParams[AT_SIGN];
    var key = verbParams[AT_KEY];
    var operation = verbParams[OPERATION];
    String? byPassCacheStr = verbParams[bypassCache];
    // Generate query using key, atSign from verbParams
    atSign = AtUtils.formatAtSign(atSign);
    key = '$key$atSign';
    //If key is cached, return cached value.
    var result = await _getCachedValue(operation, key);
    // If cached key value is null or byPassCache is true, perform a remote plookup.
    if (result == null || byPassCacheStr == 'true') {
      result = await _getRemoteValue(key, atSign, atConnection);
      // OutboundMessageListener will throw exceptions upon any 'error:' responses, malformed response, or timeouts
      // So we only have to worry about 'data:' response here
      result = result!.replaceAll('data:', '');
      if (result == 'null') {
        await _removeCachedKey(key);
        return;
      }
      var atData = AtData();
      atData = atData.fromJson(jsonDecode(result));
      if (operation != 'all') {
        result = SecondaryUtil.prepareResponseData(operation, atData);
      }
      // Caching of keys is refrained when looked up the currentAtSign user
      // Cache keys only if currentAtSign is not equal to atSign
      if (AtSecondaryServerImpl.getInstance().currentAtSign != atSign) {
        await _storeCachedKey(key, atData);
      }
    }
    response.data = result;
    var atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    try {
      await atAccessLog?.insert(atSign!, pLookup.name(), lookupKey: key);
    } on DataStoreException catch (e) {
      logger.severe('Hive error adding to access log:${e.toString()}');
    }
    return;
  }

  /// Returns the cached value of the key.
  Future<String?> _getCachedValue(String? operation, String key) async {
    key = 'cached:public:$key';
    if (keyStore!.isKeyExists(key)) {
      var atData = await keyStore!.get(key);
      return SecondaryUtil.prepareResponseData(operation, atData);
    }
  }

  /// Performs the remote lookup and returns the value of the key.
  Future<String?> _getRemoteValue(
      String query, String? atSign, InboundConnection atConnection) async {
    var outBoundClient = OutboundClientManager.getInstance()
        .getClient(atSign, atConnection, isHandShake: false)!;
    if (!outBoundClient.isConnectionCreated) {
      logger.finer('creating outbound connection $atSign');
      await outBoundClient.connect(handshake: false);
    }
    // call lookup with the query. Added operation as all to get key's value and metadata for caching
    return await outBoundClient.lookUp('all:$query', handshake: false);
  }

  /// Caches the key.
  Future<void> _storeCachedKey(String key, AtData atData) async {
    key = 'cached:public:$key';
    atData.metaData!.ttr ??= -1;
    await keyStore!.put(key, atData);
  }

  /// Remove cached key.
  Future<void> _removeCachedKey(String key) async {
    await keyStore!.remove(key);
  }
}
