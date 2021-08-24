import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
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

  ScanVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  /// Verifies whether command is accepted or not
  /// @param - command: Input to scan verb
  /// @return - bool: Return true if command is accepted, else false.
  @override
  bool accept(String command) => command.startsWith(getName(VerbEnum.scan));

  /// Returns [Scan] verb.
  @override
  Verb getVerb() {
    return scan;
  }

  /// Process scan Verb.
  /// Process the given command and write response to response object.
  /// Throws [UnAuthenticatedException] if forAtSign is not null and connection is not authenticated.
  /// @param - response - Holds the response from server and sends to the client.
  /// @param - verbParams - Holds the key value pair that matches the regular expression.
  /// @param - AtConnection - The connection which invokes the process verb.
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var atConnectionMetadata =
        atConnection.getMetaData() as InboundConnectionMetadata;
    var forAtSign = verbParams[FOR_AT_SIGN];
    var scanRegex = verbParams[AT_REGEX];

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
      if (forAtSign != null &&
          atConnectionMetadata.isAuthenticated &&
          forAtSign != currentAtSign) {
        response.data =
            await _getExternalKeys(forAtSign, scanRegex, atConnection);
      } else {
        String keyString;
        var keys = keyStore!.getKeys(regex: scanRegex) as List<String?>;
        keyString = _getLocalKeys(atConnectionMetadata, keys);
        // Apply regex on keyString to remove unnecessary characters and spaces
        keyString = keyString.replaceFirst(RegExp(r'^\['), '');
        keyString = keyString.replaceFirst(RegExp(r'\]$'), '');
        keyString = keyString.replaceAll(', ', ',');
        response.data = keyString;
        logger.finer('response.data : ${response.data}');
        var keysArray = (response.data != null && response.data!.isNotEmpty)
            ? response.data?.split(',')
            : [];
        logger.finer('keysArray : $keysArray, ${keysArray?.length}');
        response.data = json.encode(keysArray);
      }
    } on Exception catch (e) {
      response.isError = true;
      response.errorMessage = e.toString();
      rethrow;
    }
  }

  /// Fetches the keys of another user atsign
  /// @param - forAtSign : The another user atsign to lookup for keys.
  /// @param - scanRegex : The regular expression to filter the keys
  /// @param - atConnection : The inbound connection
  /// @return - Future<String> : The another atsign keys returned.
  Future<String?> _getExternalKeys(String forAtSign, String? scanRegex,
      InboundConnection atConnection) async {
    //scan has to be performed for another atsign
    var outBoundClient =
        OutboundClientManager.getInstance().getClient(forAtSign, atConnection)!;
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

  /// Returns the current atsign keys.
  /// @param - atConnectionMetadata: Metadata of the inbound connection
  /// @param - List<String>: List of keys from the secondary persistent store
  /// @return - String: Returns the keys of current atsign
  String _getLocalKeys(
      InboundConnectionMetadata atConnectionMetadata, List<String?> keys) {
    var keyString;
    // Verify if the current user is authenticated or not
    // If authenticated get all the keys except for private keys
    // If not, get only public keys
    if (atConnectionMetadata.isAuthenticated) {
      //display all keys except private
      keys.removeWhere((key) =>
          key.toString().startsWith('privatekey:') ||
          key.toString().startsWith('public:_') ||
          key.toString().startsWith('private:'));
      keyString = keys.toString();
    } else {
      //When pol is performed, display keys that are private to the atsign.
      if (atConnectionMetadata.isPolAuthenticated) {
        keys.removeWhere((test) =>
            (test
                    .toString()
                    .startsWith('${atConnectionMetadata.fromAtSign}:') ==
                false) ||
            test.toString().startsWith('public:_'));
        keyString = keys
            .toString()
            .replaceAll('${atConnectionMetadata.fromAtSign}:', '');
      } else {
        // When pol is not performed, display only public keys
        keys.removeWhere((test) =>
            test.toString().startsWith('public:_') ||
            !test.toString().startsWith('public:'));
        keyString = keys.toString().replaceAll('public:', '');
      }
    }
    return keyString;
  }
}
