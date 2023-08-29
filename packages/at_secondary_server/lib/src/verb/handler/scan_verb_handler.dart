import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

/// ScanVerbHandler class is used to process scan verb
/// Scan verb will return all the possible keys you can lookup
///Ex: scan\n
class ScanVerbHandler extends AbstractVerbHandler {
  static Scan scan = Scan();
  final OutboundClientManager outboundClientManager;
  final AtCacheManager cacheManager;

  ScanVerbHandler(
      SecondaryKeyStore keyStore, this.outboundClientManager, this.cacheManager)
      : super(keyStore);

  /// Verifies whether command is accepted or not
  ///
  /// [command]: Input to scan verb
  ///
  /// Return true if command is accepted, else false.
  @override
  bool accept(String command) => command.startsWith(getName(VerbEnum.scan));

  /// Returns [Scan] verb.
  @override
  Verb getVerb() {
    return scan;
  }

  /// Process scan Verb. Process the given command and write response to response object.
  ///
  /// [response] - Holds the response from server and sends to the client.
  ///
  /// [verbParams] - Holds the key value pair that matches the regular expression.
  ///
  /// [AtConnection] - The connection which invokes the process verb.
  ///
  /// Throws [UnAuthenticatedException] if forAtSign is not null and connection is not authenticated.
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var atConnectionMetadata =
        atConnection.getMetaData() as InboundConnectionMetadata;
    var forAtSign = verbParams[FOR_AT_SIGN];
    var scanRegex = verbParams[AT_REGEX];
    var showHiddenKeys = verbParams[showHidden] == 'true' ? true : false;

    try {
      var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
      // If forAtSign is set, fetch keys that are sharedBy the "forAtSign" to the currentAtSign
      // If currentAtSign is @alice and forAtSign is @bob, fetch all the keys that @bob has
      // created for @alice.
      if ((forAtSign != null && forAtSign.isNotEmpty) &&
          forAtSign != currentAtSign) {
        // When looking up keys of another atSign and connection is not authenticated,
        // Throw UnAuthenticatedException.
        if (!atConnectionMetadata.isAuthenticated) {
          throw UnAuthenticatedException(
              'Scan to another atSign cannot be performed without auth');
        }
        response.data =
            await _getExternalKeys(forAtSign, scanRegex, atConnection);
      } else {
        response.data = jsonEncode(await _getLocalKeys(
            atConnectionMetadata, scanRegex, showHiddenKeys, currentAtSign));
      }
    } on Exception catch (e) {
      response.isError = true;
      response.errorMessage = e.toString();
      rethrow;
    }
  }

  /// Fetches the keys of another user atSign
  ///
  /// [forAtSign] : The another user atSign to lookup for keys.
  ///
  /// [scanRegex] : The regular expression to filter the keys
  ///
  /// [atConnection] : The inbound connection
  ///
  /// **Returns**
  ///
  /// String : The another atSign keys returned. Returns null if no keys found.
  Future<String?> _getExternalKeys(String forAtSign, String? scanRegex,
      InboundConnection atConnection) async {
    //scan has to be performed for another atSign
    var outBoundClient =
        outboundClientManager.getClient(forAtSign, atConnection);
    var handShake = false;
    // Performs handshake if not done.
    if (!outBoundClient.isHandShakeDone) {
      await outBoundClient.connect(handshake: true);
      handShake = true;
    }
    var scanResult =
        await outBoundClient.scan(handshake: handShake, regex: scanRegex);
    return scanResult;
  }

  /// Returns a filtered list of the
  /// keys where the filtering
  /// depends on the type of authentication
  /// on the inbound connection
  ///
  /// **Parameters**
  ///
  /// [atConnectionMetadata] Metadata of the inbound connection.
  ///
  /// [keys] List of keys from the secondary persistent store.
  ///
  /// **Returns**
  ///
  /// Returns the list of keys of current atSign.
  Future<List<String>> _getLocalKeys(
      InboundConnectionMetadata atConnectionMetadata,
      String? scanRegex,
      bool showHiddenKeys,
      String currentAtSign) async {
    List<String> localKeysList =
        keyStore.getKeys(regex: scanRegex) as List<String>;
    if (atConnectionMetadata.isAuthenticated) {
      // If connection is authenticated, except the private keys, return other keys.
      localKeysList
          .removeWhere((key) => _isPrivateKeyForAtSign(key, showHiddenKeys));
      if (atConnectionMetadata.enrollmentId == null ||
          atConnectionMetadata.enrollmentId!.isEmpty) {
        return localKeysList;
      }
      // If enrollmentId is populated, filter keys based on enrollmentId
      return await _filterKeysBasedOnEnrollmentId(
          atConnectionMetadata, localKeysList, currentAtSign);
    } else if (atConnectionMetadata.isPolAuthenticated) {
      // TODO: Refactor along with atKey and Scan refactoring.
      localKeysList.removeWhere((key) =>
          key.toString().startsWith('${atConnectionMetadata.fromAtSign}:') ==
              false ||
          key.toString().startsWith('public:_'));
      for (int i = 0; i < localKeysList.length; i++) {
        localKeysList[i] = localKeysList[i]
            .replaceAll('${atConnectionMetadata.fromAtSign}:', '');
      }
      return localKeysList;
    } else {
      // Display only public keys. "public:_" are hidden keys. So remove them from list.
      // Also, remove all the other keys that do not start with "public:"
      localKeysList.removeWhere(
          (key) => key.startsWith('public:_') || !key.startsWith('public:'));
      for (int i = 0; i < localKeysList.length; i++) {
        localKeysList[i] = localKeysList[i].replaceAll('public:', '');
      }
      return localKeysList;
    }
  }

  /// Checks if a key starts with `public:_`, `private:`, `privatekey:`.
  /// [key] : The key to check.
  /// Returns true if key starts with pattern, else false.
  ///
  /// When showHidden is set true, display hidden keys.
  bool _isPrivateKeyForAtSign(String key, bool showHiddenKeys) {
    // If showHidden is set to true, display hidden public keys/self hidden keys.
    // So returning false
    // public hidden key: public:__location@alice
    // self hidden key: _location@alice
    if ((key.startsWith('public:__') || key.startsWith('_')) &&
        showHiddenKeys) {
      return false;
    }
    return key.startsWith('private:') ||
        key.startsWith('privatekey:') ||
        key.startsWith('public:_') ||
        key.startsWith('_');
  }

  /// Filter and returns keys whose namespaces are authorized for the given
  /// enrollmentId.
  ///
  ///   - If the enrollment namespace contains ".*", returns all the keys.
  ///
  ///   - Returns all the public keys and the keys whose namespace is authorized
  ///     for the given enrollmentId.
  ///
  ///  - If a key's namespace contain "__manage", the key is ignored.
  Future<List<String>> _filterKeysBasedOnEnrollmentId(
      InboundConnectionMetadata atConnectionMetadata,
      List<String> localKeysList,
      String currentAtSign) async {
    var enrollmentKey =
        '${atConnectionMetadata.enrollmentId}.$newEnrollmentKeyPattern.$enrollManageNamespace$currentAtSign';
    var enrollNamespaces =
        (await getEnrollDataStoreValue(enrollmentKey)).namespaces;
    // No namespace to filter keys. So, return.
    if (enrollNamespaces.isEmpty) {
      logger.finer(
          'For the enrollmentId ${atConnectionMetadata.enrollmentId} no namespaces are enrolled. Returning empty list');
      return [];
    }
    // If enrollment namespace contains ".*" return all keys.
    if (enrollNamespaces.containsKey(allNamespaces)) {
      return localKeysList;
    }
    // Return only keys whose namespace is authorized.
    int index = 0;
    // Iterates through the list of local keys.
    // Removes the key from the list if any of the below condition is met:
    // 1. If a key does not have namespace
    // 2. If key is an enrollment key - key whose namespace is "__manage"
    // 3. If a keys namespace is not authorised in the enrollment.
    // If a key is removed, the length of the list is reduced. To prevent skipping
    // of the keys in the list, do not increment "index". Increment "index" only
    // if key is not removed.
    while (index < localKeysList.length) {
      String key = localKeysList[index];
      // Retain public keys
      if (key.startsWith('public:')) {
        index++;
        continue;
      }
      // If key does not have ".", it indicates key does not have namespace
      // Do not show it in scan result.
      if (!key.contains('.')) {
        localKeysList.remove(key);
        continue;
      }
      // Extract namespace from the key.
      String namespaceFromTheKey = key.toString().substring(
          (key.toString().lastIndexOf('.') + 1),
          key.toString().lastIndexOf('@'));
      if (!enrollNamespaces.containsKey(namespaceFromTheKey) ||
          namespaceFromTheKey == enrollManageNamespace) {
        localKeysList.remove(key);
        continue;
      }
      index++;
    }
    return localKeysList;
  }
}
