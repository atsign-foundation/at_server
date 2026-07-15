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

// PolVerbHandler class is used to process Pol verb
// ex: pol\n
class PolVerbHandler extends AbstractVerbHandler {
  static Pol pol = Pol();
  static final RegExp _dataPrefix = RegExp('^data:');
  static final RegExp _pqPrefix = RegExp('^pq:');

  final OutboundClientManager outboundClientManager;
  final AtCacheManager cacheManager;
  final AtAccessLog accessLog;
  final _dummyInboundConnection = DummyInboundConnection();

  static const _maxOutboundAttempts = 2;

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

    final String storedSecretId = 'public:$sessionID$fromAtSign';

    // Fetch locally stored secret first to detect mode (pq: prefix = PQ mode).
    String? message;
    try {
      message = (await keyStore.get(storedSecretId))?.data;
    } on KeyNotFoundException {
      // Key doesn't exist; message remains null
    } on Exception catch (e) {
      logger.severe('Exception fetching stored secret $storedSecretId : $e');
      rethrow;
    }

    if (message == null) {
      logger.severe('No stored secret found at $storedSecretId');
      throw UnAuthenticatedException('Unable to verify pol: no stored secret');
    }

    // 'pq:' = PQ mode: both sides hold an HKDF key-confirmation tag and compare
    // them for equality. Only the legacy (RSA/UUID) path needs the remote
    // signing public key.
    final isPqMode = message.startsWith('pq:');

    // Fetch the challenge (and, for RSA, the signing key) from the peer over an
    // unauthenticated outbound connection.
    //
    // A pooled outbound client to the peer may be reused here. If its socket
    // died without a detectable close (e.g. the peer restarted, or — in the PQ
    // flow — FROM served a cached cert so no fresh connection was made this
    // exchange), the reuse fails with a timeout rather than a connect error.
    // So on failure we discard the client and retry once with a fresh
    // connection before giving up.
    late OutboundClient oc;
    String? fetchedChallenge, fromPublicKey;
    for (int attempt = 0;; attempt++) {
      oc = await outboundClientManager.getClient(
          fromAtSign!, // Non-null: guaranteed by the from: check above.
          _dummyInboundConnection,
          handshakeRequired: false);
      String doing = '';
      try {
        if (!oc.isConnectionCreated) {
          doing = 'connecting to $fromAtSign';
          await oc.connect();
        }
        // fetch the challenge from the other secondary
        doing = 'fetching challenge from $fromAtSign';
        fetchedChallenge = (await oc.lookUp('$sessionID$fromAtSign',
                handshake: false))
            ?.replaceFirst(_dataPrefix, '');

        // Only the non-PQ (RSA/UUID) path needs the remote signing public key.
        if (!isPqMode) {
          doing = 'fetching signing_publickey$fromAtSign';
          fromPublicKey = (await oc.plookUp('signing_publickey$fromAtSign'))
              ?.replaceFirst(_dataPrefix, '');
        }
        break; // success
      } on Exception catch (e) {
        // Close the (possibly stale) client so the next getClient evicts it
        // from the pool and establishes a fresh connection.
        await oc.outboundConnection?.close();
        if (attempt >= _maxOutboundAttempts - 1) {
          logger.severe('Exception while $doing (final attempt) : $e');
          rethrow;
        }
        logger.info(
            'Exception while $doing; retrying with a fresh outbound connection : $e');
      }
    }

    if (fetchedChallenge == null) {
      throw AtException('Unable to verify pol: no challenge returned from $fromAtSign');
    }

    if (isPqMode) {
      // PQ path: compare key-confirmation tags. The peer may have stored more
      // than one candidate tag ('pq:tagCurrent,tagPrev') when it retains a
      // rotation grace-period key — X-Wing implicit rejection gives no other
      // signal for which key it decapsulated against, so any match is valid.
      final storedTag = message.replaceFirst(_pqPrefix, '');
      final candidateTags =
          fetchedChallenge.replaceFirst(_pqPrefix, '').split(',');
      if (!candidateTags.contains(storedTag)) {
        throw UnAuthenticatedException(
            'Pol Authentication Failed: PQ sharedSecret mismatch');
      }
    } else {
      // Legacy RSA path.
      if (fromPublicKey == null) {
        throw AtException('Unable to verify pol: signing_publickey not found for $fromAtSign');
      }
      final bool isValidChallenge = RSAPublicKey.fromString(fromPublicKey)
          .verifySHA256Signature(
              utf8.encode(message), base64Decode(fetchedChallenge));
      if (!isValidChallenge) {
        throw UnAuthenticatedException('Pol Authentication Failed');
      }
    }

    // Remove the stored secret.
    try {
      await keyStore.remove(storedSecretId);
    } catch (e) {
      logger.warning('Failed to immediately remove $storedSecretId');
    }

    atConnectionMetadata.isPolAuthenticated = true;
    response.data = 'pol:$fromAtSign@';
    await accessLog.insert(fromAtSign.toString(), pol.name());
    logger.info('response : $fromAtSign@');
  }
}
