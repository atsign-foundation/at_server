import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
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

    // Throw UnAuthenticatedException.
    // When looking up keys of another atsign and connection is not authenticated,
    if (forAtSign != null && !atConnectionMetadata.isAuthenticated) {
      throw UnAuthenticatedException(
          'Scan to another atsign cannot be performed without auth');
    }
    try {
      // If forAtSign is not null and connection is authenticated, scan keys of another user's atsign,
      // else scan local keys.
      var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
      var enrollnamespaces = {};
      if (forAtSign != null &&
          atConnectionMetadata.isAuthenticated &&
          forAtSign != currentAtSign) {
        response.data =
            await _getExternalKeys(forAtSign, scanRegex, atConnection);
      } else {
        List<String> keys = keyStore.getKeys(regex: scanRegex) as List<String>;
        List<String> filteredKeys = [];
        final enrollmentId = atConnectionMetadata.enrollApprovalId;
        logger.finer('inside scan: $enrollmentId');
        if (enrollmentId != null && enrollmentId.isNotEmpty) {
          enrollnamespaces =
              await getEnrollmentNamespaces(enrollmentId, currentAtSign);
          logger.finer('scan namespaces: $enrollnamespaces');
        }
        List<String> keyString =
            _getLocalKeys(atConnectionMetadata, keys, showHiddenKeys);
        for (var key in keyString) {
          for (var namespace in enrollnamespaces.keys) {
            var namespaceRegex = namespace.name;
            if (!namespaceRegex.startsWith('.')) {
              namespaceRegex = '.$namespaceRegex';
            }
            if (key.contains(RegExp(namespaceRegex)) ||
                key.startsWith('public:')) {
              filteredKeys.add(key);
            }
          }
        }
        // Apply regex on keyString to remove unnecessary characters and spaces.
        logger.finer('response.data : $keyString');
        var keysArray = keyString;
        logger.finer('keysArray : $keysArray, ${keysArray.length}');
        if (enrollnamespaces.isNotEmpty) {
          response.data = json.encode(filteredKeys);
        } else {
          response.data = json.encode(keysArray);
        }
      }
    } on Exception catch (e) {
      response.isError = true;
      response.errorMessage = e.toString();
      rethrow;
    }
  }

  /// Fetches the keys of another user atsign
  ///
  /// [forAtSign] : The another user atsign to lookup for keys.
  ///
  /// [scanRegex] : The regular expression to filter the keys
  ///
  /// [atConnection] : The inbound connection
  ///
  /// **Returns**
  ///
  /// String : The another atsign keys returned. Returns null if no keys found.
  Future<String?> _getExternalKeys(String forAtSign, String? scanRegex,
      InboundConnection atConnection) async {
    //scan has to be performed for another atsign
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
  /// Returns the list of keys of current atsign.
  List<String> _getLocalKeys(InboundConnectionMetadata atConnectionMetadata,
      List<String> keys, bool showHiddenKeys) {
    List<String> keysList = [];
    // Verify if the current user is authenticated or not
    // If authenticated get all the keys except for private keys
    // If not, get only public keys
    if (atConnectionMetadata.isAuthenticated) {
      //display all keys except private
      keys.removeWhere((key) => _isPrivateKeyForAtSign(key, showHiddenKeys));
      keysList = keys;
    } else {
      // When pol is performed, display keys that are private to the atsign.
      if (atConnectionMetadata.isPolAuthenticated) {
        // TODO: Refactor along with atKey and Scan refactoring.
        keys.removeWhere((key) =>
            key.toString().startsWith('${atConnectionMetadata.fromAtSign}:') ==
                false ||
            key.toString().startsWith('public:_'));
        // Remove the atSigns from the inbound connection
        // keys and add the modified key to the list.
        // @murali:phone@sitaram => phone@sitaram
        for (var key in keys) {
          var modifiedKey =
              key.replaceAll('${atConnectionMetadata.fromAtSign}:', '');
          keysList.add(modifiedKey);
        }
      } else {
        // When pol is not performed, display only public keys
        keys.removeWhere((key) => _getNonPublicKeys(key));
        for (var key in keys) {
          var modifiedKey = key.toString().replaceAll('public:', '');
          keysList.add(modifiedKey);
        }
      }
    }
    return keysList;
  }

  /// Check if a key is not public.
  /// [key] : The key to check.
  /// Returns true if key starts with pattern, else false.
  bool _getNonPublicKeys(String key) {
    return key.toString().startsWith('public:_') ||
        !key.toString().startsWith('public:');
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
}
