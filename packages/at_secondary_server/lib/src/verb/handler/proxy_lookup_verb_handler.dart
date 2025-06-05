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

  ProxyLookupVerbHandler(
      super.keyStore, this.outboundClientManager, this.cacheManager);

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
    var atSign = verbParams[AtConstants.atSign];
    var entityName = verbParams[AtConstants.atKey];
    var operation = verbParams[AtConstants.operation];
    String? byPassCacheStr = verbParams[AtConstants.bypassCache];
    // Generate query using key, atSign from verbParams
    if (atSign.isNotNullOrEmpty) {
      atSign = AtUtils.fixAtSign(atSign!);
    }
    var keyAtAtSign = '$entityName$atSign';
    var cachedKeyName = 'cached:public:$keyAtAtSign';

    var atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    try {
      await atAccessLog?.insert(atSign!, pLookup.name(),
          lookupKey: keyAtAtSign);
    } on DataStoreException catch (e) {
      logger.severe('Hive error adding to access log:${e.toString()}');
    }

    final bool bypassCache;

    // - If it looks like *.<enrollmentId>.[ard].__e@thisAtsign
    // - Then fetch the enrollment to check if it's active
    //
    // This ensures that expired enrollment keys are in the right place
    //
    if (perEnrollmentRegex.hasMatch(keyAtAtSign)) {
      bypassCache = true;
    } else {
      bypassCache = byPassCacheStr == 'true';
    }

    AtData? atData;
    String? result;

    // First, check if we've even got a cached value
    if (!bypassCache) {
      atData = await cacheManager.get(cachedKeyName, applyMetadataRules: true);
      result = SecondaryUtil.prepareResponseData(operation, atData);
    }

    // If we don't have a cached value, or byPassCache parameter is set to 'true', then do a remote lookUp.
    if (result == null || bypassCache) {
      AtData? atData =
          await cacheManager.remoteLookUp(cachedKeyName, maintainCache: true);
      if (atData != null) {
        result = SecondaryUtil.prepareResponseData(operation, atData,
            key: 'public:$keyAtAtSign');
      }
    }
    response.data = result;
    return;
  }
}
