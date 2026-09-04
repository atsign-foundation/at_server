import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:crypton/crypton.dart';

/// Handles `pol`, which proves the atSign named by an earlier `from:` signed
/// this connection's challenge.
class PolVerbHandler extends AbstractVerbHandler {
  static Pol pol = Pol();
  static final RegExp _dataPrefix = RegExp('^data:');

  final OutboundClientManager outboundClientManager;
  final AtCacheManager cacheManager;
  final AtAccessLog accessLog;
  final _dummyInboundConnection = DummyInboundConnection();

  PolVerbHandler(super.keyStore, this.outboundClientManager, this.cacheManager,
      {required this.accessLog});

  @override
  bool accept(String command) => command == getName(VerbEnum.pol);

  @override
  HashMap<String, String> parse(String command) {
    return HashMap();
  }

  @override
  Verb getVerb() {
    return pol;
  }

  /// Throws an [AtConnectException] if unable to establish connection to
  /// another secondary.
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    InboundConnectionMetadata atConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    var fromAtSign = atConnectionMetadata.fromAtSign;
    var sessionID = atConnectionMetadata.sessionID;

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
      doing = 'fetching signed challenge from $fromAtSign';
      signedChallenge = (await (oc.lookUp(
        '$sessionID$fromAtSign',
        handshake: false,
      )))
          ?.replaceFirst(_dataPrefix, '');

      doing = 'fetching signing_publickey$fromAtSign';
      fromPublicKey = (await (oc.plookUp('signing_publickey$fromAtSign')))
          ?.replaceFirst(_dataPrefix, '');

      // Spent on read, whatever the verification below decides: this
      // challenge was handed to ANOTHER atSign to sign, so one that survived
      // a failed verification would leave the replay window for a captured
      // signature bounded by nothing at all.
      doing = 'fetching stored secret $storedSecretId';
      message = await consumeChallenge(storedSecretId);
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

    bool isValidChallenge = RSAPublicKey.fromString(fromPublicKey)
        .verifySHA256Signature(
            utf8.encode(message), base64Decode(signedChallenge));
    if (!isValidChallenge) {
      throw UnAuthenticatedException('Pol Authentication Failed');
    }
    // The challenge was already spent by consumeChallenge.

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
