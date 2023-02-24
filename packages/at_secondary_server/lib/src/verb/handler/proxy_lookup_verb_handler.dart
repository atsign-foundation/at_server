import 'dart:async';
import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
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
  final OutboundClientManager outboundClientManager;
  final AtCacheManager cacheManager;

  ProxyLookupVerbHandler(SecondaryKeyStore keyStore, this.outboundClientManager, this.cacheManager) : super(keyStore);

  // Method to verify whether command is accepted or not
  // Input: command
  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.plookup)}:');

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
    var entityName = verbParams[AT_KEY];
    var operation = verbParams[OPERATION];
    String? byPassCacheStr = verbParams[bypassCache];
    // Generate query using key, atSign from verbParams
    atSign = AtUtils.formatAtSign(atSign);
    var keyName = '$entityName$atSign';
    var cachedKeyName = 'cached:public:$keyName';

    var atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    try {
      await atAccessLog?.insert(atSign!, pLookup.name(), lookupKey: keyName);
    } on DataStoreException catch (e) {
      logger.severe('Hive error adding to access log:${e.toString()}');
    }

    // First, check if we've even got a cached value
    var atData = await cacheManager.get(cachedKeyName, applyMetadataRules: false);
    var result = SecondaryUtil.prepareResponseData(operation, atData);

    // If we don't have a cached value, or byPassCache parameter is set to 'true', then do a remote lookUp.
    if (result == null || byPassCacheStr == 'true') {
      AtData? atData = await cacheManager.remoteLookUp(cachedKeyName, maintainCache: true);
      if (atData != null) {
        result = SecondaryUtil.prepareResponseData(operation, atData, keyToUseIfNotAlreadySetInAtData: keyName);
      }
    }
    response.data = result;
    return;
  }
}
