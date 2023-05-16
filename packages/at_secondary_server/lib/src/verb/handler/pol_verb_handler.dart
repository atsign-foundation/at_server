import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
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
  static final _rootDomain = AtSecondaryConfig.rootServerUrl;
  static final _rootPort = AtSecondaryConfig.rootServerPort;
  final OutboundClientManager outboundClientManager;
  final AtCacheManager cacheManager;

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
    var atConnectionMetadata =
        atConnection.getMetaData() as InboundConnectionMetadata;
    var fromAtSign = atConnectionMetadata.fromAtSign;
    var sessionID = atConnectionMetadata.sessionID;

    logger.info('from : ${atConnectionMetadata.from.toString()}');
    AtAccessLog? atAccessLog = await AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign);
    // Checking whether from: verb executed or not.
    // If true proceed else return error message
    if (atConnectionMetadata.from != true) {
      throw InvalidRequestException('You must execute a '
          'from:'
          ' command before you may run the pol command');
    }

    // Getting secondary server URL
    var secondaryUrl =
        // ignore: deprecated_member_use
        await AtLookupImpl.findSecondary(fromAtSign!, _rootDomain, _rootPort!);
    logger.finer('secondary url : $secondaryUrl');
    if (secondaryUrl != null && secondaryUrl.contains(':')) {
      var lookUpKey = '$sessionID$fromAtSign';
      // Connect to the other secondary server and get the secret
      OutboundClient outBoundClient =
          outboundClientManager.getClient(fromAtSign, atConnection);
      if (!outBoundClient.isConnectionCreated) {
        logger.finer('creating outbound connection $fromAtSign');
        await outBoundClient.connect(handshake: false);
      }
      var signedChallenge =
          await (outBoundClient.lookUp(lookUpKey, handshake: false));
      signedChallenge = signedChallenge?.replaceFirst('data:', '');
      var plookupCommand = 'signing_publickey$fromAtSign';
      var fromPublicKey = await (outBoundClient.plookUp(plookupCommand));
      fromPublicKey = fromPublicKey?.replaceFirst('data:', '');
      // Getting stored secret from this secondary server
      var secret = await keyStore.get('public:${sessionID!}$fromAtSign');
      logger.finer('secret fetch status : ${secret != null}');
      var message = secret?.data;
      if (fromPublicKey != null && signedChallenge != null) {
        // Comparing secretLookup form other secondary and stored secret are same or not
        var isValidChallenge = RSAPublicKey.fromString(fromPublicKey)
            .verifySHA256Signature(utf8.encode(message) as Uint8List,
                base64Decode(signedChallenge));
        logger.finer('isValidChallenge:$isValidChallenge');
        if (isValidChallenge) {
          atConnectionMetadata.isPolAuthenticated = true;
          response.data = 'pol:$fromAtSign@';
          await atAccessLog!.insert(fromAtSign, pol.name());
          logger.info('response : $fromAtSign@');
        } else {
          throw UnAuthenticatedException('Pol Authentication Failed');
        }
      } else {
        logger.finer('fromPublicKey is $fromPublicKey\n'
            'signedChallenge is $signedChallenge');
        throw AtKeyNotFoundException(
            'fromPublicKey or signedChallenge is null');
      }
      outBoundClient.close();
      return;
    } else {
      throw SecondaryNotFoundException(
          'secondary server not found for $fromAtSign');
    }
  }
}
