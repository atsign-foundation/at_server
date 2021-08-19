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
    var pageId = verbParams['pageId'];
    print('pageId : $pageId');
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
        if (pageId == null) {
          response.data =
              await _getExternalKeys(forAtSign, scanRegex, atConnection);
        } else {
          var keysString =
              await _getExternalKeys(forAtSign, scanRegex, atConnection);
          response.data =
              _prepareExternalKeysResponse(int.parse(pageId), keysString);
        }
        print('external keys : ${response.data}');
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
        print('keysArray : ${keysArray.runtimeType}');
        if (pageId == null) {
          response.data = keyString;
        } else {
          response.data =
              _prepareLocalKeysResponse(int.parse(pageId), keysArray);
        }
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
    print(
        'scan result in _getExternalKeys : $scanResult, ${scanResult.runtimeType}');
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
      // keyString = keys.toString();
      keyString = jsonEncode(keys);
    } else {
      //When pol is performed, display keys that are private to the atsign.
      if (atConnectionMetadata.isPolAuthenticated) {
        keys.removeWhere((test) =>
            (test
                    .toString()
                    .startsWith('${atConnectionMetadata.fromAtSign}:') ==
                false) ||
            test.toString().startsWith('public:_'));
        // keyString = keys
        //     .toString()
        //     .replaceAll('${atConnectionMetadata.fromAtSign}:', '');
        keyString = jsonEncode(keys)
            .replaceAll('${atConnectionMetadata.fromAtSign}:', '');
      } else {
        // When pol is not performed, display only public keys
        keys.removeWhere((test) =>
            test.toString().startsWith('public:_') ||
            !test.toString().startsWith('public:'));
        // keyString = keys.toString().replaceAll('public:', '');
        keyString = jsonEncode(keys).replaceAll('public:', '');
      }
    }
    print('keys type : ${keys.runtimeType}');
    return keyString;
  }

  String? _prepareExternalKeysResponse(int pageId, String? keyString) {
    if (keyString == null || keyString.isEmpty) {
      return keyString;
    }
    var result = <String, dynamic>{};
    print('keysString in _prepareExternalKeysResponse: $keyString');
    keyString = keyString.replaceFirst('data:', '');
    var keys = jsonDecode(keyString);
    var start_index = (pageId - 1) * 10;
    if (start_index < keys.length) {
      var end_index = (start_index + 10 > keys.length)
          ? keys.length - 1
          : (start_index + 10);
      result['keys'] = jsonEncode(keys.sublist(start_index, end_index));
    } else {
      result['keys'] = jsonEncode([]);
    }
    result['totalPages'] =
        ((keys.length) / 10).toInt() + ((keys.length) % 10 > 0 ? 1 : 0);
    result['keysPerPage'] = 10;
    result['pageId'] = pageId;
    return jsonEncode(result);
  }

  String? _prepareLocalKeysResponse(int pageId, List<dynamic>? keys) {
    var result = <String, dynamic>{};
    if (keys == null || keys.isEmpty) {
      return null;
    }
    var start_index = (pageId - 1) * 10;
    if (start_index < keys.length) {
      var end_index = (start_index + 10 > keys.length)
          ? keys.length - 1
          : (start_index + 10);
      result['keys'] = jsonEncode(keys.sublist(start_index, end_index));
    } else {
      result['keys'] = jsonEncode([]);
    }
    result['totalPages'] =
        (keys.length) ~/ 10 + ((keys.length) % 10 > 0 ? 1 : 0);
    result['keysPerPage'] = 10;
    result['pageId'] = pageId;
    return jsonEncode(result);
  }
}
