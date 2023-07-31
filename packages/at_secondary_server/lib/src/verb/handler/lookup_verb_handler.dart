import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';

class LookupVerbHandler extends AbstractVerbHandler {
  static Lookup lookup = Lookup();
  static final depthOfResolution = AtSecondaryConfig.lookup_depth_of_resolution;
  final OutboundClientManager outboundClientManager;
  final AtCacheManager cacheManager;

  LookupVerbHandler(
      SecondaryKeyStore keyStore, this.outboundClientManager, this.cacheManager)
      : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.lookup)}:');

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
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var atConnectionMetadata =
        atConnection.getMetaData() as InboundConnectionMetadata;
    var thisServersAtSign = cacheManager.atSign;
    var atAccessLog = await AtAccessLogManagerImpl.getInstance()
        .getAccessLog(thisServersAtSign);
    var fromAtSign = atConnectionMetadata.fromAtSign;
    String keyOwnersAtSign = verbParams[AT_SIGN]!;
    keyOwnersAtSign = AtUtils.fixAtSign(keyOwnersAtSign);
    var entity = verbParams[AT_KEY];
    var keyAtAtSign = '$entity$keyOwnersAtSign';
    var operation = verbParams[OPERATION];
    String? byPassCacheStr = verbParams[bypassCache];

    logger.finer(
        'fromAtSign : $fromAtSign \n atSign : ${keyOwnersAtSign.toString()} \n key : $keyAtAtSign');
    // Connection is authenticated and the currentAtSign is not atSign
    // lookUp secondary of atSign for the key
    if (atConnectionMetadata.isAuthenticated) {
      if (keyOwnersAtSign == thisServersAtSign) {
        // We're looking up data owned by this server's atSign
        var lookupKey = '$thisServersAtSign:$keyAtAtSign';
        final enrollApprovalId =
            (atConnection.getMetaData() as InboundConnectionMetadata)
                .enrollmentId;
        bool isAuthorized = true; // for legacy clients allow access by default
        if (enrollApprovalId != null) {
          var keyNamespace =
              lookupKey.substring(lookupKey.lastIndexOf('.') + 1);
          isAuthorized =
              await super.isAuthorized(enrollApprovalId, keyNamespace);
        }
        if (!isAuthorized) {
          throw UnAuthorizedException(
              'Enrollment Id: $enrollApprovalId is not authorized for lookup operation on the key: $lookupKey');
        }
        var lookupValue = await keyStore.get(lookupKey);
        response.data =
            SecondaryUtil.prepareResponseData(operation, lookupValue);

        //Resolving value references to correct value
        if (response.data != null &&
            response.data!.contains(AT_VALUE_REFERENCE)) {
          response.data = await resolveValueReference(
              response.data.toString(), thisServersAtSign);
        }
        try {
          await atAccessLog!
              .insert(keyOwnersAtSign, lookup.name(), lookupKey: keyAtAtSign);
        } on DataStoreException catch (e) {
          logger.severe('Hive error adding to access log:${e.toString()}');
        }
      } else {
        // keyOwnersAtSign != thisServersAtSign
        // We're looking up data owned by another atSign.
        String cachedKeyName = '$CACHED:$thisServersAtSign:$keyAtAtSign';
        //Get cached value.
        AtData? cachedValue =
            await cacheManager.get(cachedKeyName, applyMetadataRules: true);
        response.data =
            SecondaryUtil.prepareResponseData(operation, cachedValue);

        //If cached value is null or byPassCache is true, do a remote lookUp
        if (response.data == null ||
            response.data == '' ||
            byPassCacheStr == 'true') {
          AtData? atData = await cacheManager.remoteLookUp(cachedKeyName,
              maintainCache: true);
          if (atData != null) {
            response.data = SecondaryUtil.prepareResponseData(operation, atData,
                key: '$thisServersAtSign:$keyAtAtSign');
          }
        }
      }
      return;
    } else {
      // isAuthenticated is false
      // If the Connection is unauthenticated form the key based on presence of "fromAtSign"
      var keyPrefix = '';
      if (!(atConnectionMetadata.isAuthenticated)) {
        keyPrefix = (fromAtSign == null || fromAtSign == '')
            ? 'public:'
            : '$fromAtSign:';
      }
      // Form the look up key
      var lookupKey = keyPrefix + keyAtAtSign;
      logger.finer('lookupKey in lookupVerbHandler : $lookupKey');
      // Find the value for the key from the data store
      var lookupData = await keyStore.get(lookupKey);
      var isActive = SecondaryUtil.isActiveKey(lookupData);
      if (isActive) {
        response.data =
            SecondaryUtil.prepareResponseData(operation, lookupData);
        //Resolving value references to correct values
        if (response.data != null &&
            response.data!.contains(AT_VALUE_REFERENCE)) {
          response.data =
              await resolveValueReference(response.data!, keyPrefix);
        }
        //Omit all keys starting with '_' to record in access log
        if (!keyAtAtSign.startsWith('_')) {
          try {
            await atAccessLog!
                .insert(keyOwnersAtSign, lookup.name(), lookupKey: keyAtAtSign);
          } on DataStoreException catch (e) {
            logger.severe('Hive error adding to access log:${e.toString()}');
          }
        }
        return;
      } else {
        response.data = null;
      }
    }
  }

  /// Resolves the value references and returns correct value if value is resolved with in depth of resolution.
  /// else null is returned.
  /// @param - value : The reference value to be resolved.
  /// @param - keyPrefix : The prefix for the key: <atsign> or public.
  Future<String?> resolveValueReference(String value, String keyPrefix) async {
    var resolutionCount = 1;

    // Iterates for DEPTH_OF_RESOLUTION times to resolve the value reference.If value is still a reference, returns null.
    while (value.contains(AT_VALUE_REFERENCE) &&
        resolutionCount <= depthOfResolution!) {
      var index = value.indexOf('/');
      var keyToResolve = value.substring(index + 2, value.length);
      if (!keyPrefix.endsWith(':')) {
        keyPrefix = '$keyPrefix:';
      }
      keyToResolve = keyPrefix + keyToResolve;
      var lookupValue = await keyStore.get(keyToResolve);
      value = lookupValue?.data;
      // If the value is null for a private key, searches on public namespace.
      keyToResolve = keyToResolve.replaceAll(keyPrefix, 'public:');
      lookupValue = await keyStore.get(keyToResolve);
      value = lookupValue?.data;
      resolutionCount++;
    }
    return value.contains(AT_VALUE_REFERENCE) ? null : value;
  }
}
