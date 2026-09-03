import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/apkam_signature_verifier.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:meta/meta.dart';

class PkamVerbHandler extends AbstractVerbHandler {
  static Pkam pkam = Pkam();

  PkamVerbHandler(super.keyStore);

  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.pkam)}:');

  @override
  Verb getVerb() {
    return pkam;
  }

  @override
  Future<void> processVerb(Response response,
      HashMap<String, String?> verbParams, AtConnection atConnection) async {
    var atConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    // Folded to EXACTLY the keystore's own fold — trimmed, lowercased, spaces
    // stripped — because that is what decides which record an id addresses.
    // Without this a non-canonical spelling resolves to the same RECORD while
    // comparing unequal to the id everything downstream holds, so a revoke
    // would not drop the connection and the revoked credential would go on
    // authenticating: the connection's id is what the revoke's connection
    // drop, the caller-in-cascade refusal and ownership of this enrollment's
    // own reserved keys are all compared against.
    //
    // Lowercasing alone was not enough, and the gap it left is the dangerous
    // half: case is the spelling a real client sends by accident, while
    // whitespace is the one an attacker sends on purpose.
    //
    // Ids are server-issued uuids and already canonical, so this rejects
    // nothing that works today; it stops a non-canonical spelling of one from
    // travelling further than the lookup.
    var enrollId = EnrollmentManager.canonicalEnrollmentIdOrNull(
        verbParams[AtConstants.enrollmentId]);
    var sessionID = atConnectionMetadata.sessionID;
    var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    AuthType pkamAuthType;
    String? publicKey;
    // Null lets the wire value decide the algorithm, which is what a legacy
    // PKAM has always done: the flat key made no claim about itself, and may
    // legitimately be ecc_secp256r1.
    String? recordSigningAlgo;

    // Use APKAM public key for verification if enrollId is passed.
    // Otherwise use legacy pkam public key.
    if (enrollId != null && enrollId.isNotEmpty) {
      pkamAuthType = AuthType.apkam;
      ApkamVerificationResult apkamResult =
          await verifyEnrollmentIsActive(enrollId, atSign);
      if (apkamResult.response.isError) {
        response.isError = apkamResult.response.isError;
        response.errorCode = apkamResult.response.errorCode;
        response.errorMessage = apkamResult.response.errorMessage;
        return;
      }
      publicKey = apkamResult.publicKey;
      // Record-authoritative: an APKAM keypair's algorithm is a property of
      // the enrollment it was registered under, not something the client
      // restates on each connect. Hardening rather than a fix — the signature
      // is checked against the stored public key either way, so a client that
      // misstates the algorithm only fails its own verification — but it
      // closes off cross-algorithm confusion, where one key blob parses under
      // more than one algorithm. A legacy enrollment predating the field has
      // none recorded, so it keeps the existing default EXPLICITLY here: a
      // null must not fall through to the wire claim in _validateSignature,
      // or the claim picks the verify routine for exactly the enrollments
      // that predate the field (an RSA record verified as ML-DSA fails a
      // legitimate legacy client; the wire fallback exists for legacy
      // no-enrollment PKAM, which may present ecc_secp256r1).
      recordSigningAlgo =
          apkamResult.signingAlgo ?? ApkamSignatureVerifier.rsa2048Algo;
    } else {
      // A legacy `pkam:` carries no enrollment id, and authenticates as the
      // enrollment the flat legacy credential migrates into: `primary`. The
      // flat key is read first — a key still in the store is one the startup
      // migration has not yet seen, or that a test fixture installed — and
      // otherwise `primary`'s recorded key is what the signature is checked
      // against, under the algorithm the record carries. Which of the two
      // verified is settled again inside the section, in [_admitUnderLock],
      // where the flat key is absorbed into `primary` and the connection is
      // given `primary` to carry.
      pkamAuthType = AuthType.pkamLegacy;
      final EnrollmentManager enMgr =
          AtSecondaryServerImpl.getInstance().enrollmentManager;
      publicKey = await enMgr.legacyPkamPublicKey();
      if (publicKey == null) {
        final EnrollDataStoreValue? primary = await enMgr.primaryEnrollment();
        if (primary == null) {
          // The message NAMES THE REMEDY, because the population that hits
          // this is not a broken atSign but a client sending the wrong shape
          // of authentication. An atSign onboarded through `enroll:request`
          // has no legacy credential at all — it never did — so a caller
          // arriving here is almost always one that holds an enrollment id
          // and did not send it. "No credential" alone reads as an atSign
          // fault and sends the reader looking in the wrong place entirely.
          logger.warning('Legacy PKAM authentication refused: this atSign '
              'holds neither a flat credential nor a '
              '${EnrollmentManager.primaryEnrollmentId} enrollment');
          throw UnAuthenticatedException(
              'this atSign has no legacy PKAM credential. An atSign onboarded '
              'through enroll:request has none by design: authenticate with '
              'the enrollment id its keyfile carries, as '
              'pkam:enrollmentId:<id>:<signature>');
        }
        // `primary` is judged exactly as an enrollment named on the wire is:
        // a revoked primary refuses with AT0027, and the refusal names no
        // other enrollment.
        final ApkamVerificationResult primaryResult =
            await verifyEnrollmentIsActive(
                EnrollmentManager.primaryEnrollmentId, atSign);
        if (primaryResult.response.isError) {
          response.isError = true;
          response.errorCode = primaryResult.response.errorCode;
          response.errorMessage = primaryResult.response.errorMessage;
          return;
        }
        publicKey = primaryResult.publicKey;
        recordSigningAlgo = primaryResult.signingAlgo;
      }
    }

    if (publicKey == null || publicKey.isEmpty) {
      throw UnAuthenticatedException('pkam publickey not found');
    }

    String storedSecretId = 'private:$sessionID$atSign';
    // One challenge, one attempt, and only while it is live. The challenge is
    // spent here whatever the signature turns out to be, so a caller cannot
    // grind signatures against a single `from:`.
    final String? storedSecret = await consumeChallenge(storedSecretId);
    if (storedSecret == null) {
      // Absent, unreadable or expired. Refused with the same message and the
      // same exception a bad signature gets: the wire must not distinguish
      // "your challenge went stale" from "your signature was wrong", or it
      // becomes an oracle for which session ids are live.
      atConnectionMetadata.isAuthenticated = false;
      logger.severe('pkam authentication failed: no live challenge for'
          ' session $sessionID');
      throw UnAuthenticatedException('pkam authentication failed');
    }
    bool isValidSignature = await _validateSignature(
      verbParams,
      sessionID,
      atSign,
      publicKey,
      recordSigningAlgo,
      storedSecret,
    );

    if (isValidSignature) {
      // We're good. The challenge was already spent by consumeChallenge.

      // Admitting the connection is a read-decide-write like every other
      // enrollment act — the write is the connection's identity rather than a
      // record — so it runs inside the atSign's one enrollment-mutation
      // critical section. See [_admitUnderLock].
      final bool admitted = await AtSecondaryServerImpl.getInstance()
          .enrollmentManager
          .serialiseMutation(() => _admitUnderLock(
              atConnectionMetadata,
              pkamAuthType,
              enrollId,
              atSign,
              response,
              verifiedKey: publicKey!,
              wireSigningAlgo: verbParams[AtConstants.atPkamSigningAlgo]));
      if (!admitted) {
        return;
      }
      response.data = 'success';
      // A legacy login carries `primary` from here on, so the arming below
      // asks about it like any other enrollment; it replaced nothing, so the
      // ask is a no-op.
      enrollId = atConnectionMetadata.enrollmentId;

      // A retrofit's successor arms the expiry cap on the enrollment it
      // replaced HERE, on its first authentication and never again — this is
      // the moment that proves the successor's APKAM private half survived the
      // client-side keyfile write and can actually be used. Arming it where
      // the successor is stored would start a clock on the predecessor, the
      // only credential that still works, on the strength of a record only the
      // server had written.
      //
      // A no-op for every enrollment that replaced nothing, and it never
      // throws: authentication has already succeeded by this point and must
      // not be undone by bookkeeping.
      if (enrollId != null && enrollId.isNotEmpty) {
        final enMgr = AtSecondaryServerImpl.getInstance().enrollmentManager;
        await enMgr.armRetrofitCapOnFirstAuth(enrollId);
      }
    } else {
      // Nope
      atConnectionMetadata.isAuthenticated = false;
      logger.severe('pkam authentication failed');
      throw UnAuthenticatedException('pkam authentication failed');
    }
  }

  /// The last read of the enrollment state this connection's identity rests
  /// on, and the marking that acts on it, as ONE enrollment-mutation critical
  /// section. Returns whether the connection was admitted; a refusal that has
  /// a wire error code of its own is written into [response] instead of being
  /// thrown, exactly as the same refusal is before the signature is checked.
  ///
  /// The decision is a read-decide-write like every other enrollment act —
  /// what it writes is the connection's identity rather than a record — so it
  /// belongs in the same section for the same reason. Taken outside it, an
  /// `enroll:revoke` landing between the read and the marking is answered
  /// `success`: the revoke sweeps open connections by the enrollment id each
  /// one CARRIES, and a connection still being authenticated has not been
  /// given one, so the sweep passes over it and the marking then happens on a
  /// state the revoke has already replaced.
  ///
  /// Serialising it leaves only the two orders that are coherent. A revoke
  /// that takes the section first is seen by the read here, and the
  /// authentication is refused; one that takes it second finds a connection
  /// already carrying the id, and closes it.
  ///
  /// It is the store-wide section rather than an understanding with the
  /// revoke path because revocation is not the only way an enrollment stops
  /// serving: `enroll:delete` and an elapsed ttl sweep no connections at all,
  /// and only a read taken inside the section is ordered against them.
  ///
  /// The cost is that an authentication waits for an enrollment mutation in
  /// flight. That is the right trade — the answer it is about to give is
  /// exactly what that mutation decides — and it is bounded by how long a
  /// mutation takes, on a store where mutations are rare next to
  /// authentications.
  ///
  /// This does not stand in for the per-command check. A credential revoked
  /// after a connection is admitted is caught by
  /// `AbstractVerbHandler.processInternal`, which re-reads the enrollment
  /// before every command and closes a connection whose enrollment has left
  /// `approved`. What the section adds is that the `success` answer itself is
  /// never given on a state that has already been replaced.
  ///
  /// A LEGACY authentication is the read-decide-write in full. The signature
  /// was verified against the flat key or against `primary`'s recorded key,
  /// whichever the caller found; here, inside the section, a flat key still
  /// in the store is absorbed into `primary` — minted from it or rotated onto
  /// it, and deleted — and the connection is admitted as `primary` only if
  /// `primary` is approved and holds the key that verified. A second legacy
  /// login that waited on the section finds no flat key and takes exactly
  /// that fallback. [verifiedKey] is the key the signature verified against,
  /// [wireSigningAlgo] what the wire said it was.
  Future<bool> _admitUnderLock(
      InboundConnectionMetadata atConnectionMetadata,
      AuthType pkamAuthType,
      String? enrollId,
      String atSign,
      Response response,
      {required String verifiedKey,
      String? wireSigningAlgo}) async {
    if (pkamAuthType == AuthType.pkamLegacy) {
      final EnrollmentManager enMgr =
          AtSecondaryServerImpl.getInstance().enrollmentManager;
      await enMgr.absorbFlatKeyIntoPrimary(signingAlgo: wireSigningAlgo);
      final ApkamVerificationResult primary = await verifyEnrollmentIsActive(
          EnrollmentManager.primaryEnrollmentId, atSign);
      if (primary.response.isError) {
        logger.warning('Refusing legacy PKAM authentication: '
            '${EnrollmentManager.primaryEnrollmentId} is not serving — '
            '${primary.response.errorMessage}');
        response.isError = true;
        response.errorCode = primary.response.errorCode;
        response.errorMessage = primary.response.errorMessage;
        return false;
      }
      if (!EnrollmentManager.sameApkamKeyMaterial(verifiedKey, wireSigningAlgo,
          primary.publicKey!, primary.signingAlgo)) {
        // The key that verified is not the key primary holds now: another
        // login rotated primary in between. Refused as a bad signature is,
        // because against the record as it stands that is what it is.
        atConnectionMetadata.isAuthenticated = false;
        logger.severe('pkam authentication failed: the key that verified is '
            'no longer the key ${EnrollmentManager.primaryEnrollmentId} holds');
        throw UnAuthenticatedException('pkam authentication failed');
      }
      enrollId = EnrollmentManager.primaryEnrollmentId;
    } else {
      // Asked again, inside the section, over the record the connection is
      // about to be admitted as. The first ask ran before the signature was
      // verified, because it is where the public key comes from, and
      // verifying a signature is the longest step on this path — so the state
      // it read is the state from before all of it.
      //
      // The refusal is the FIRST ask's refusal, code for code: the two are
      // one check made at two moments, and a client must not be able to tell
      // which of them refused it from the answer it gets back.
      //
      // `isAuthenticated` is deliberately left alone here, exactly as the
      // first ask leaves it. A failed re-authentication over a connection
      // that is already authenticated as something else does not end that
      // session; only a bad signature does.
      final ApkamVerificationResult recheck =
          await verifyEnrollmentIsActive(enrollId!, atSign);
      if (recheck.response.isError) {
        logger.warning('Refusing APKAM authentication: enrollment $enrollId '
            'stopped serving while the signature was being verified — '
            '${recheck.response.errorMessage}');
        response.isError = true;
        response.errorCode = recheck.response.errorCode;
        response.errorMessage = recheck.response.errorMessage;
        return false;
      }
    }

    atConnectionMetadata.isAuthenticated = true;
    atConnectionMetadata.authType = pkamAuthType;
    atConnectionMetadata.enrollmentId = enrollId;
    return true;
  }

  @visibleForTesting
  Future<ApkamVerificationResult> verifyEnrollmentIsActive(
      String enId, String atSign) async {
    late final EnrollDataStoreValue enVal;
    ApkamVerificationResult apkamResult = ApkamVerificationResult();
    EnrollmentStatus? enrollStatus;
    EnrollmentManager enMgr =
        AtSecondaryServerImpl.getInstance().enrollmentManager;

    try {
      enVal = await enMgr.getEnrollmentById(enId);
      enrollStatus = EnrollmentStatus.values.byName(enVal.approval!.state);
    } on KeyNotFoundException catch (_) {
      apkamResult.response.isError = true;
      apkamResult.response.errorCode = 'AT0028';
      apkamResult.response.errorMessage =
          'enrollment_id: $enId is expired or invalid';
      return apkamResult;
    }

    apkamResult.response = _getApprovalStatus(enrollStatus, enId);
    if (apkamResult.response.isError) {
      return apkamResult;
    }
    apkamResult.publicKey = enVal.apkamPublicKey;
    apkamResult.signingAlgo = enVal.signingAlgo;
    return apkamResult;
  }

  Response _getApprovalStatus(EnrollmentStatus enrollStatus, enrollId) {
    Response response = Response();
    switch (enrollStatus) {
      case EnrollmentStatus.denied:
        response.isError = true;
        response.errorCode = 'AT0025';
        response.errorMessage = 'enrollment_id: $enrollId is denied';
        break;
      case EnrollmentStatus.pending:
        response.isError = true;
        response.errorCode = 'AT0026';
        response.errorMessage = 'enrollment_id: $enrollId is pending';
        break;
      case EnrollmentStatus.approved:
        // do nothing when enrollment is approved
        break;
      case EnrollmentStatus.revoked:
        response.isError = true;
        response.errorCode = 'AT0027';
        response.errorMessage = 'enrollment_id: $enrollId is revoked';
        break;
      case EnrollmentStatus.expired:
        response.isError = true;
        response.errorCode = 'AT0028';
        response.errorMessage =
            'enrollment_id: $enrollId is expired or invalid';
        break;
    }
    return response;
  }

  /// [recordSigningAlgo] is the algorithm recorded on the enrollment, when
  /// this connection authenticates as one. It wins over whatever the wire
  /// says, so the client stops choosing how its own signature is interpreted.
  /// Null for legacy PKAM — there is no record — in which case the wire value
  /// still decides, as it always has.
  Future<bool> _validateSignature(
    var verbParams,
    var sessionId,
    String atSign,
    String publicKey,
    String? recordSigningAlgo,
    String storedSecret,
  ) async {
    var signature = verbParams[AtConstants.atPkamSignature]!;
    var signingAlgo =
        recordSigningAlgo ?? verbParams[AtConstants.atPkamSigningAlgo];
    var hashingAlgo = verbParams[AtConstants.atPkamHashingAlgo];
    bool isValidSignature = false;
    if (signature == null || signature.isEmpty) {
      logger.severe('inputSignature is null/empty');
      return false;
    }

    logger.finer('signingAlgo: $signingAlgo, hashingAlgo: $hashingAlgo');
    isValidSignature = await ApkamSignatureVerifier.verify(
      message: utf8.encode('$sessionId$atSign:$storedSecret'),
      base64Signature: signature,
      publicKey: publicKey,
      signingAlgo: ApkamSignatureVerifier.signingAlgoTypeOf(signingAlgo),
      hashingAlgo: ApkamSignatureVerifier.hashingAlgoTypeOf(hashingAlgo),
    );
    logger.finer('PKAM auth: $isValidSignature');
    return isValidSignature;
  }
}

class ApkamVerificationResult {
  Response response = Response();
  String? publicKey;

  /// The signing algorithm recorded on the enrollment, which is what
  /// [publicKey] actually is. Null on a legacy enrollment predating the field.
  String? signingAlgo;
}
