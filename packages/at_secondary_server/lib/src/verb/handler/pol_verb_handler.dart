import 'dart:collection';
import 'dart:convert';

import 'package:at_chops/at_chops_ffi.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/crypto/pq_constants.dart';
import 'package:at_secondary/src/crypto/pq_signing_public_record.dart';
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

    // The UUID challenge we issued and stored at FROM time.
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

    // Fetch the peer's signed challenge (its cookie) and the public key needed
    // to verify it, over an unauthenticated outbound connection.
    //
    // A pooled outbound client to the peer may be reused here. If its socket
    // died without a detectable close (e.g. the peer restarted), the reuse
    // fails with a timeout rather than a connect error. So on failure we
    // discard the client and retry once with a fresh connection before giving
    // up.
    //
    // The prover marks a PQ-signed cookie with a 'pq:<algo>:' prefix; from
    // that we know whether to fetch its PQ signing public-key record or its
    // legacy RSA signing_publickey.
    late OutboundClient oc;
    String? fetchedChallenge, fromRsaPublicKey, fromPqRecord;
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
        // fetch the signed challenge (peer's cookie) from the other secondary
        doing = 'fetching challenge from $fromAtSign';
        fetchedChallenge = (await oc.lookUp('$sessionID$fromAtSign',
                handshake: false))
            ?.replaceFirst(_dataPrefix, '');

        if (fetchedChallenge != null &&
            fetchedChallenge.startsWith(_pqPrefix)) {
          doing = 'fetching PQ signing public key for $fromAtSign';
          fromPqRecord = (await oc
                  .plookUp('$pqSigningPublicKeyRecordNamePart$fromAtSign'))
              ?.replaceFirst(_dataPrefix, '');
        } else {
          doing = 'fetching signing_publickey$fromAtSign';
          fromRsaPublicKey = (await oc.plookUp('signing_publickey$fromAtSign'))
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
      throw AtException(
          'Unable to verify pol: no challenge returned from $fromAtSign');
    }

    if (fetchedChallenge.startsWith(_pqPrefix)) {
      await _verifyPqSignature(
          fromAtSign, message, fetchedChallenge, fromPqRecord);
    } else {
      // Legacy RSA path.
      if (fromRsaPublicKey == null) {
        throw AtException(
            'Unable to verify pol: signing_publickey not found for $fromAtSign');
      }
      final bool isValidChallenge = RSAPublicKey.fromString(fromRsaPublicKey)
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

  /// Verify a PQ-signed pol challenge.
  ///
  /// [signedCookie] is the peer's cookie of the form
  /// `pq:<algo>:<base64 signature>`; [challenge] is the UUID we issued and
  /// stored; [peerRecord] is the peer's published PQ signing public-key record
  /// (JSON keyed by algorithm id). Throws [UnAuthenticatedException] /
  /// [AtException] on any verification failure.
  Future<void> _verifyPqSignature(String fromAtSign, String challenge,
      String signedCookie, String? peerRecord) async {
    // 'pq:<algo>:<base64 sig>' — base64 contains no ':', so a plain split
    // yields exactly three fields; anything else is malformed.
    final parts = signedCookie.split(':');
    if (parts.length != 3 || parts[0] != 'pq') {
      throw UnAuthenticatedException(
          'Pol Authentication Failed: malformed PQ cookie');
    }
    final algo = parts[1];
    if (!pqSupportedSigningAlgosByPreference.contains(algo)) {
      throw UnAuthenticatedException(
          'Pol Authentication Failed: unsupported PQ algorithm "$algo"');
    }
    if (peerRecord == null) {
      throw AtException(
          'Unable to verify pol: PQ signing public key not found for $fromAtSign');
    }
    final publicKey = pqSigningKeyForAlgo(peerRecord, algo);
    if (publicKey == null) {
      throw UnAuthenticatedException(
          'Pol Authentication Failed: no "$algo" key in $fromAtSign record');
    }
    // Only ml-dsa-65 is in the supported set today; a new algorithm adds a
    // branch here alongside its entry in pqSupportedSigningAlgosByPreference.
    final isValid = await AtPqc.mlDsa65.verifyBytes(utf8.encode(challenge),
        signature: base64Decode(parts[2]), publicKey: publicKey);
    if (!isValid) {
      throw UnAuthenticatedException(
          'Pol Authentication Failed: PQ signature invalid');
    }
  }
}
