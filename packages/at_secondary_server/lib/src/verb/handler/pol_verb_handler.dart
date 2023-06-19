import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:crypton/crypton.dart';

// PolVerbHandler class is used to process Pol verb
// ex: pol\n
class PolVerbHandler extends AbstractVerbHandler {
  static Pol pol = Pol();
  final OutboundClientManager outboundClientManager;
  final AtCacheManager cacheManager;
  OutboundClient? _outboundClient;

  PolVerbHandler(
      SecondaryKeyStore keyStore, this.outboundClientManager, this.cacheManager)
      : super(keyStore);

  // Method to verify whether command is accepted or not
  // Input: command
  @override
  bool accept(String command) => command == getName(VerbEnum.pol);

  @override
  HashMap<String, String> parse(String command) {
    return HashMap();
  }

  // Method to return Instance of verb belongs to this VerbHandler
  @override
  Verb getVerb() {
    return pol;
  }

  // Method which will process pol Verb
  // This will process given verb and write response to response object
  // Input : Response, verbParams, AtConnection
  /// Throws an [AtConnectException] if unable to establish connection to another secondary
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    InboundConnectionMetadata atConnectionMetadata =
        atConnection.getMetaData() as InboundConnectionMetadata;
    var fromAtSign = atConnectionMetadata.fromAtSign;
    var sessionID = atConnectionMetadata.sessionID;

    logger.info('from : ${atConnectionMetadata.from.toString()}');
    // Check if from: verb is executed
    if (atConnectionMetadata.from != true) {
      throw InvalidRequestException('You must execute a '
          '\'from:\' command before you may run the pol command');
    }

    await _createOutboundConnection(fromAtSign, atConnection);
    HashMap<String, String> fetchSecretResult =
        await _fetchSecret(fromAtSign!, sessionID!);
    // pass the result from _fetchSecret() to validateChallenge()
    // validateChallenge() requires the params fetched through _fetchSecret()
    _validateChallenge(fetchSecretResult);

    atConnectionMetadata.isPolAuthenticated = true;
    response.data = 'pol:$fromAtSign@';
    await _insertIntoAccessLog(fromAtSign, pol.name());
    logger.info('response : $fromAtSign@');

    _outboundClient?.close();
    return;
  }

  Future<void> _createOutboundConnection(
      String? fromAtsign, var atConnection) async {
    // Connect to the other secondary server
    _outboundClient =
        outboundClientManager.getClient(fromAtsign!, atConnection);
    if (!_outboundClient!.isConnectionCreated) {
      try {
        await _outboundClient!.connect(handshake: false);
      } on Exception catch (e) {
        logger.finer(
            'Exception connecting to $fromAtsign\'s outbound client | $e');
        rethrow;
      }
    }
    return;
  }

  /// fetches signedChallenge and publicKey from the other secondary
  /// and secret from this secondary
  /// throws an exception if any of these could not be fetched
  Future<HashMap<String, String>> _fetchSecret(
      String fromAtSign, String sessionID) async {
    String? signedChallenge, fromPublicKey, message;
    HashMap<String, String> response = HashMap();
    try {
      // construct the key that needs to be looked up
      var lookUpKey = '$sessionID$fromAtSign';
      // fetch the challenge from the other secondary
      signedChallenge =
          await (_outboundClient?.lookUp(lookUpKey, handshake: false));
      signedChallenge = signedChallenge?.replaceFirst('data:', '');

      // look for the public key on the other secondary
      var plookupCommand = 'signing_publickey$fromAtSign';
      fromPublicKey = await (_outboundClient?.plookUp(plookupCommand));
      fromPublicKey = fromPublicKey?.replaceFirst('data:', '');

      // Getting stored secret from this secondary server
      var secret = await keyStore.get('public:$sessionID$fromAtSign');
      logger.finer('Secret fetch status : ${secret != null}');
      message = secret?.data;
    } on Exception catch (e) {
      logger.finer('Exception fetching secret: $e');
      rethrow;
    }

    if (fromPublicKey == null || signedChallenge == null || message == null) {
      logger.finer(
          'Invalid OutboundClient status: ${_outboundClient.toString()}');
      logger
          .severe('Unable to verify signature. fromPublicKey is $fromPublicKey'
              ' | signedChallenge is $signedChallenge | message is $message');
      throw AtException('Unable to verify signature');
    }
    response['signedChallenge'] = signedChallenge;
    response['fromPublicKey'] = fromPublicKey;
    response['message'] = message;

    return response;
  }

  void _validateChallenge(HashMap<String, String> inputs) {
    // Comparing secretLookup form other secondary and stored secret are same or not
    bool isValidChallenge = RSAPublicKey.fromString(inputs['fromPublicKey']!)
        .verifySHA256Signature(utf8.encode(inputs['message']!) as Uint8List,
            base64Decode(inputs['signedChallenge']!));
    logger.finer('isValidChallenge: $isValidChallenge');
    if (!isValidChallenge) {
      throw UnAuthenticatedException('Pol Authentication Failed');
    }
    return;
  }

  Future<void> _insertIntoAccessLog(String key, String value) async {
    AtAccessLog? atAccessLog = await AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign);

    await atAccessLog!.insert(key, value);
    return;
  }
}
