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
    if (atConnectionMetadata.isAuthenticated) {
      await _handleAuthenticatedConnection(
          keyOwnersAtSign,
          thisServersAtSign,
          keyAtAtSign,
          atConnection,
          response,
          operation,
          atAccessLog,
          byPassCacheStr);
    } else {
      await _handleUnAuthAndPolAuthConnection(atConnectionMetadata, fromAtSign,
          keyAtAtSign, response, operation, atAccessLog, keyOwnersAtSign);
    }
  }

  /// Handles the Authenticated connection requests
  ///   - If the [keyOwnersAtSign] corresponds to the [thisServersAtSign], retrieves data
  ///     from the keystore.
  ///   - If the [keyOwnersAtSign] differs from the [thisServersAtSign], a network call
  ///     is initiated to the [keyOwnersAtSign] to acquire the data.
  ///
  ///   - If the user is authenticated using the legacy PKAM, the data is returned.
  ///   - If the user is authenticated using the APKAM, the function fetches the
  ///     enrollmentId from metadata. Data is only returned if the atSign has
  ///     permission to access the key's namespace.
  ///   - If permissions are not met, [UnAuthorizedException] is thrown.
  Future<void> _handleAuthenticatedConnection(
      String keyOwnersAtSign,
      String thisServersAtSign,
      String keyAtAtSign,
      InboundConnection atConnection,
      Response response,
      String? operation,
      AtAccessLog? atAccessLog,
      String? byPassCacheStr) async {
    var lookupKey = '$thisServersAtSign:$keyAtAtSign';
    bool isAuthorized = await _isAuthorizedToViewData(atConnection, lookupKey);
    if (!isAuthorized) {
      throw UnAuthorizedException(
          'Enrollment Id: ${(atConnection.getMetaData() as InboundConnectionMetadata).enrollmentId} is not authorized for lookup operation on the key: $lookupKey');
    }
    if (keyOwnersAtSign == thisServersAtSign) {
      // We're looking up data owned by this server's atSign
      await _fetchDataOwnedByThisAtSign(thisServersAtSign, keyAtAtSign,
          atConnection, response, operation, atAccessLog, keyOwnersAtSign);
    } else {
      // keyOwnersAtSign != thisServersAtSign
      // We're looking up data owned by another atSign.
      await _fetchDataOwnedByOtherAtSign(
          thisServersAtSign, keyAtAtSign, response, operation, byPassCacheStr);
    }
  }

  /// Handles requests from unauthenticated or pol-authenticated connections.
  ///
  ///   - In the case of an unauthenticated connection,  the "lookup" verb is used
  ///     to fetch public keys from the storage associated with the current "atSign".
  ///
  ///     For instance, if the current atSign is "alice", then using "lookup:phone.wavi@alice"
  ///     yields the corresponding value of the key "public:phone.wavi@alice".
  ///
  ///   - In cases where the 'atSign' does not possess ownership of the data,
  ///     a pol authentication is initiated towards the 'atSign' that does own the data.
  ///
  ///     For instance, when the current "atSign" is "alice" and the request is
  ///     "lookup:phone.wavi@bob"(from an authenticated connection), an interaction
  ///     occurs where Alice proves identity to Bob, who subsequently returns the
  ///     value of the key "@alice:phone.wavi@bob".
  Future<void> _handleUnAuthAndPolAuthConnection(
      InboundConnectionMetadata atConnectionMetadata,
      String? fromAtSign,
      String keyAtAtSign,
      Response response,
      String? operation,
      AtAccessLog? atAccessLog,
      String keyOwnersAtSign) async {
    var keyPrefix = '';
    // When a connection is not authenticated, two scenarios arise:
    //  1. An unauthenticated connection, wherein only public keys are accessible.
    //     In this scenario, set the keyPrefix to "public:".
    //  2. A pol authenticated connection, where request originates from a different
    //     'atSign'. In this scenario, set the keyPrefix to the requesting 'atSign'.
    if (!(atConnectionMetadata.isAuthenticated)) {
      keyPrefix =
          (fromAtSign == null || fromAtSign == '') ? 'public:' : '$fromAtSign:';
    }
    var lookupKey = keyPrefix + keyAtAtSign;
    logger.finer('lookupKey in lookupVerbHandler : $lookupKey');
    var lookupData = await keyStore.get(lookupKey);
    var isActive = SecondaryUtil.isActiveKey(lookupData);
    if (!isActive) {
      response.data = null;
      return;
    }
    response.data = SecondaryUtil.prepareResponseData(operation, lookupData);
    //Resolving value references to correct values
    if (response.data != null && response.data!.contains(AT_VALUE_REFERENCE)) {
      response.data = await resolveValueReference(response.data!, keyPrefix);
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
  }

  /// Retrieve data owned by a different 'atSign':
  ///
  ///  - If a cached key is available, fetch data from the cache. However,
  ///    if [byPassCacheStr] is set to true, the value from cached key is ignored.
  ///    Initiates a network call to the "atSign" who owns the data and returns the value.
  ///  - If cached key does not exist, fetches data from the "atSign" that owns the data.
  Future<void> _fetchDataOwnedByOtherAtSign(
      String thisServersAtSign,
      String keyAtAtSign,
      Response response,
      String? operation,
      String? byPassCacheStr) async {
    String cachedKeyName = '$CACHED:$thisServersAtSign:$keyAtAtSign';
    //Get cached value.
    AtData? cachedValue =
        await cacheManager.get(cachedKeyName, applyMetadataRules: true);
    response.data = SecondaryUtil.prepareResponseData(operation, cachedValue);

    //If cached value is null or byPassCache is true, do a remote lookUp
    if (response.data == null ||
        response.data == '' ||
        byPassCacheStr == 'true') {
      AtData? atData =
          await cacheManager.remoteLookUp(cachedKeyName, maintainCache: true);
      if (atData != null) {
        response.data = SecondaryUtil.prepareResponseData(operation, atData,
            key: '$thisServersAtSign:$keyAtAtSign');
      }
    }
  }

  /// Retrieve data owned by [thisServersAtSign].
  Future<void> _fetchDataOwnedByThisAtSign(
      String thisServersAtSign,
      String keyAtAtSign,
      InboundConnection atConnection,
      Response response,
      String? operation,
      AtAccessLog? atAccessLog,
      String keyOwnersAtSign) async {
    var lookupKey = '$thisServersAtSign:$keyAtAtSign';
    var lookupValue = await keyStore.get(lookupKey);
    response.data = SecondaryUtil.prepareResponseData(operation, lookupValue);
    //Resolving value references to correct value
    if (response.data != null && response.data!.contains(AT_VALUE_REFERENCE)) {
      response.data = await resolveValueReference(
          response.data.toString(), thisServersAtSign);
    }
    try {
      await atAccessLog!
          .insert(keyOwnersAtSign, lookup.name(), lookupKey: keyAtAtSign);
    } on DataStoreException catch (e) {
      logger.severe('Hive error adding to access log:${e.toString()}');
    }
  }

  /// When an 'atSign' is authenticated via APKAM, retrieves enrollment data based
  /// on the enrollmentId.
  ///
  /// If the user possesses authorization for the [lookupKey] namespace, returns true;
  /// otherwise, returns false.
  Future<bool> _isAuthorizedToViewData(
      InboundConnection atConnection, String lookupKey) async {
    final enrollmentId =
        (atConnection.getMetaData() as InboundConnectionMetadata).enrollmentId;
    bool isAuthorized = true; // for legacy clients allow access by default
    if (enrollmentId != null) {
      // Extract namespace from the key - 'some_key.wavi@alice' where "wavi" is
      // is the namespace.
      var keyNamespace = lookupKey.substring(
          lookupKey.lastIndexOf('.') + 1, lookupKey.lastIndexOf('@'));
      isAuthorized = await super.isAuthorized(enrollmentId, keyNamespace);
    }
    return isAuthorized;
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
