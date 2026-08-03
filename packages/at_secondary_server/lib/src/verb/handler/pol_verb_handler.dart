import 'dart:collection';

import 'package:at_chops/at_chops.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/crypto/pol_signing_algos.dart';
import 'package:at_secondary/src/crypto/signing_key_constants.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

// PolVerbHandler class is used to process Pol verb
// ex: pol\n
class PolVerbHandler extends AbstractVerbHandler {
  static Pol pol = Pol();

  final OutboundClientManager outboundClientManager;
  final AtCacheManager cacheManager;
  final AtAccessLog accessLog;
  final _dummyInboundConnection = DummyInboundConnection();

  static const _maxOutboundAttempts = 2;

  PolVerbHandler(super.keyStore, this.outboundClientManager, this.cacheManager,
      {required this.accessLog});

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

    final String storedSecretId = 'public:$sessionID$fromAtSign';

    // Our own record of what we issued at FROM time: the challenge, and —
    // never anything read off the wire — the algorithm we chose to demand (if
    // any) and the peer's key for it. This is what makes verification below
    // authoritative rather than trusting the cookie's own `<type>:` tag.
    StoredPolChallenge? stored;
    try {
      final raw = (await keyStore.get(storedSecretId))?.data;
      if (raw != null) {
        stored = StoredPolChallenge.decode(raw);
      }
    } on KeyNotFoundException {
      // Key doesn't exist; stored remains null
    } on Exception catch (e) {
      logger.severe('Exception fetching stored secret $storedSecretId : $e');
      rethrow;
    }

    if (stored == null) {
      logger.severe('No stored secret found at $storedSecretId');
      throw UnAuthenticatedException('Unable to verify pol: no stored secret');
    }

    // Fetch the peer's cookie, over an unauthenticated outbound connection.
    // When we demanded a negotiable type, its key was already cached at FROM
    // time — no record fetch needed here. Only the legacy RSA path (nothing
    // demanded) still needs one, since that key is never cached in advance.
    //
    // A pooled client may be reused here; if its socket died without a
    // detectable close (peer restart) the reuse times out rather than failing
    // to connect, so on failure we discard it and retry once with a fresh
    // connection.
    final bool needsLegacyKey = stored.chosenAlgo == null;
    late OutboundClient oc;
    String? fetchedCookie, legacyPublicKey;
    for (int attempt = 0;; attempt++) {
      // Reset per attempt, so a partial result from a failed attempt (cookie
      // fetched, key lookup failed) can't leak into verification below.
      fetchedCookie = null;
      legacyPublicKey = null;
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
        // fetch the signed challenge (peer's cookie) from the other secondary
        doing = 'fetching challenge from $fromAtSign';
        fetchedCookie = stripDataPrefix(
            await oc.lookUp('$sessionID$fromAtSign', handshake: false));

        if (needsLegacyKey) {
          doing =
              'fetching $legacyRsaSigningPublicKeyRecordName from $fromAtSign';
          legacyPublicKey = stripDataPrefix(await oc.plookUp(
              '$legacyRsaSigningPublicKeyRecordName$fromAtSign'));
        }
        break; // success
      } on Exception catch (e) {
        // Close the possibly-stale client so the next getClient evicts it and
        // connects afresh.
        await oc.outboundConnection?.close();
        if (attempt >= _maxOutboundAttempts - 1) {
          logger.severe('Exception while $doing (final attempt) : $e');
          rethrow;
        }
        logger.info(
            'Exception while $doing; retrying with a fresh outbound connection : $e');
      }
    }

    if (fetchedCookie == null) {
      throw AtException(
          'Unable to verify pol: no challenge returned from $fromAtSign');
    }

    await _verifySignedCookie(
        fromAtSign, stored, fetchedCookie, legacyPublicKey);

    // remove the stored secret
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

  /// Verify the peer's signed cookie against the challenge we issued and the
  /// algorithm *we* chose to demand.
  ///
  /// [stored] is this server's own FROM-time record — the challenge, the
  /// algorithm demanded (`null` for "nothing demanded, legacy RSA"), and the
  /// peer's key for it. [legacyPublicKey] is the peer's RSA key, fetched fresh
  /// at POL time; present and used only when [stored].chosenAlgo is null.
  ///
  /// The cookie's own `<type>:` tag is never consulted — only its signature
  /// bytes are. A prover that signs with a weaker or different type than
  /// demanded still lands here and simply fails verification, because we
  /// verify against the type and key *we* chose, not whatever the cookie
  /// claims. That is the core property this design exists for: the verifier's
  /// choice is authoritative, the cookie's tag is not.
  ///
  /// The two branches are genuinely different paths, not one path with flags:
  /// legacy RSA is untagged, keyed from its own record fetched fresh every
  /// time, and never negotiated. What they share is failure handling — both
  /// raise [FormatException] for unusable peer material, so one catch turns
  /// every malformed-input case into an authentication failure rather than a
  /// shout-logged internal server error.
  Future<void> _verifySignedCookie(String fromAtSign, StoredPolChallenge stored,
      String signedCookie, String? legacyPublicKey) async {
    final signature = parseSignedCookie(signedCookie).signature;
    final chosenAlgo = stored.chosenAlgo;
    final type = chosenAlgo ?? polAlgoRsaSha256;

    final AtSignatureAlgorithm? algo;
    final String? publicKey;
    if (chosenAlgo == null) {
      algo = null;
      publicKey = legacyPublicKey;
    } else {
      algo = negotiableSigningAlgos[chosenAlgo];
      if (algo == null) {
        // The registry shrank between FROM and POL — a type we ourselves
        // chose no longer exists. Should not happen absent a live algorithm
        // retirement mid-handshake; fail the auth rather than crash.
        throw UnAuthenticatedException('Pol Authentication Failed: '
            'algorithm "$chosenAlgo" no longer supported');
      }
      publicKey = stored.peerPublicKey;
    }

    if (publicKey == null) {
      throw AtException(
          'Unable to verify pol: no $type signing public key for $fromAtSign');
    }

    final bool isValid;
    try {
      isValid = algo == null
          ? await verifyLegacyRsaSignature(
              stored.challenge, signature, publicKey)
          : await algo.verifyB64(stored.challenge, signature, publicKey);
    } catch (e) {
      logger.warning('$type verification for $fromAtSign errored: $e');
      throw UnAuthenticatedException(
          'Pol Authentication Failed: $type signature could not be verified');
    }
    if (!isValid) {
      throw UnAuthenticatedException(
          'Pol Authentication Failed: $type signature invalid');
    }
  }
}
