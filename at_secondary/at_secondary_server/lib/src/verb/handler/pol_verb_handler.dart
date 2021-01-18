import 'dart:collection';
import 'dart:convert';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_commons/at_commons.dart';
import 'package:crypton/crypton.dart';

// PolVerbHandler class is used to process Pol verb
// ex: pol\n
class PolVerbHandler extends AbstractVerbHandler {
  static Pol pol = Pol();
  static final _rootDomain = AtSecondaryConfig.rootServerUrl;
  static final _rootPort = AtSecondaryConfig.rootServerPort;

  PolVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

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
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {
    InboundConnectionMetadata atConnectionMetadata = atConnection.getMetaData();
    var fromAtSign = atConnectionMetadata.fromAtSign;
    var sessionID = atConnectionMetadata.sessionID;
    var _from = atConnectionMetadata.from;
    logger.info('from : ${_from.toString()}');
    var atAccessLog = await AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign);
    // Checking whether from: verb executed or not.
    // If true proceed else return error message
    if (_from == true) {
      // Getting secondary server URL
      var secondary_url =
          await AtLookupImpl.findSecondary(fromAtSign, _rootDomain, _rootPort);
      logger.finer('secondary url : $secondary_url');
      if (secondary_url != null && secondary_url.contains(':')) {
        var lookUpKey = '$sessionID$fromAtSign';
        // Connect to the other secondary server and get the secret
        var outBoundClient = OutboundClientManager.getInstance()
            .getClient(fromAtSign, atConnection);
        if (outBoundClient == null) {
          logger.severe('max outbound limit reached');
          throw AtConnectException('max outbound limit reached');
        }
        if (!outBoundClient.isConnectionCreated) {
          logger.finer('creating outbound connection ${fromAtSign}');
          await outBoundClient.connect(handshake: false);
        }
        var signedChallenge =
            await outBoundClient.lookUp(lookUpKey, handshake: false);
        signedChallenge = signedChallenge.replaceFirst('data:', '');
        var plookupCommand = 'signing_publickey${fromAtSign}';
        var fromPublicKey = await outBoundClient.plookUp(plookupCommand);
        fromPublicKey = fromPublicKey.replaceFirst('data:', '');
        // Getting stored secret from this secondary server
        var secret = await keyStore.get('public:' + sessionID + fromAtSign);
        var message = secret?.data;
        var isValidChallenge = RSAPublicKey.fromString(fromPublicKey)
            .verifySHA256Signature(
                utf8.encode(message), base64Decode(signedChallenge));
        logger.finer('isValidChallenge:$isValidChallenge');
        // Comparing secretLookup form other secondary and stored secret are same or not
        if (isValidChallenge) {
          atConnectionMetadata.isPolAuthenticated = true;
          response.data = 'pol:$fromAtSign@';
          await atAccessLog.insert(fromAtSign, pol.name());
          logger.info('response : $fromAtSign@');
        } else {
          throw UnAuthenticatedException('Pol Authentication Failed');
        }

        return;
      } else {
        throw SecondaryNotFoundException(
            'secondary server not found for ${fromAtSign}');
      }
    } else {
      response.isError = true;
      response.errorMessage =
          'pol command run without using the from: verb first.';
      return;
    }
  }
}
