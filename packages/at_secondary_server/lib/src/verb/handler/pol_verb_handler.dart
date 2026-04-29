import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
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
  static final RegExp _dataPrefix = RegExp('^data:');

  final OutboundClientManager outboundClientManager;
  final AtCacheManager cacheManager;
  final HiveAtAccessLog? _accessLogOverride;
  HiveAtAccessLog get accessLog =>
      _accessLogOverride ?? AtSecondaryServerImpl.getInstance().accessLog;
  final _dummyInboundConnection = DummyInboundConnection();

  PolVerbHandler(
      super.keyStore, this.outboundClientManager, this.cacheManager,
      {HiveAtAccessLog? accessLog})
      : _accessLogOverride = accessLog;

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
        atConnection.metaData as InboundConnectionMetadata;
    var fromAtSign = atConnectionMetadata.fromAtSign;
    var sessionID = atConnectionMetadata.sessionID;

    // Check if from: verb is executed
    if (atConnectionMetadata.from != true) {
      throw InvalidRequestException('You must execute a '
          '\'from:\' command before you may run the pol command');
    }
    logger.info('pol from $fromAtSign');

    final OutboundClient oc = await outboundClientManager.getClient(
        fromAtSign!, _dummyInboundConnection,
        handshakeRequired: false);
    if (!oc.isConnectionCreated) {
      try {
        await oc.connect();
      } on Exception catch (e) {
        logger.severe(
            'Exception connecting to $fromAtSign\'s outbound client | $e');
        rethrow;
      }
    }

    final String storedSecretId = 'public:$sessionID$fromAtSign';

    String? signedChallenge, fromPublicKey, message;

    String doing = '';
    try {
      // construct the key that needs to be looked up
      // fetch the challenge from the other secondary
      doing = 'fetching signed challenge from $fromAtSign';
      signedChallenge = (await (oc.lookUp(
        '$sessionID$fromAtSign',
        handshake: false,
      )))
          ?.replaceFirst(_dataPrefix, '');

      // look for the public key on the other secondary
      doing = 'fetching signing_publickey$fromAtSign';
      fromPublicKey = (await (oc.plookUp('signing_publickey$fromAtSign')))
          ?.replaceFirst(_dataPrefix, '');

      // Getting stored secret from this secondary server
      doing = 'fetching stored secret $storedSecretId';
      message = (await keyStore.get(storedSecretId))?.data;
    } on Exception catch (e) {
      logger.severe('Exception while $doing : $e');
      rethrow;
    }

    if (fromPublicKey == null || signedChallenge == null || message == null) {
      logger.severe('Unable to verify signature.'
          ' fromPublicKey is $fromPublicKey'
          ' | signedChallenge is $signedChallenge'
          ' | message is $message');
      throw AtException('Unable to verify signature');
    }

    // pass the result from _fetchSecret() to validateChallenge()
    // validateChallenge() requires the params fetched through _fetchSecret()
    bool isValidChallenge = RSAPublicKey.fromString(fromPublicKey)
        .verifySHA256Signature(
            utf8.encode(message), base64Decode(signedChallenge));
    if (!isValidChallenge) {
      throw UnAuthenticatedException('Pol Authentication Failed');
    }

    // remove the stored secret
    try {
      await keyStore.remove(storedSecretId);
    } catch (e) {
      logger.warning('Failed to immediately remove $storedSecretId');
    }

    atConnectionMetadata.isPolAuthenticated = true;
    response.data = 'pol:$fromAtSign@';
    await _insertIntoAccessLog(fromAtSign, pol.name());
    logger.info('response : $fromAtSign@');

    return;
  }

  Future<void> _insertIntoAccessLog(String key, String value) async {
    await accessLog.insert(key, value);
    return;
  }
}
