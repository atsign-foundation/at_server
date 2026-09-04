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
    // Folded to exactly the keystore's own fold, because the id the connection
    // carries is what a revoke's connection drop, the caller-in-cascade
    // refusal and reserved-key ownership are compared against. An unfolded
    // spelling would reach the same record while comparing unequal to all of
    // them, so a revoked credential would go on authenticating.
    var enrollId = EnrollmentManager.canonicalEnrollmentIdOrNull(
        verbParams[AtConstants.enrollmentId]);
    var sessionID = atConnectionMetadata.sessionID;
    var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    AuthType pkamAuthType;
    String? publicKey;
    // Null lets the wire value decide the algorithm, which is what the flat
    // legacy credential needs: it makes no claim about itself and may
    // legitimately be ecc_secp256r1.
    String? recordSigningAlgo;

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
      // The enrollment's own algorithm wins over the wire claim, closing off
      // cross-algorithm confusion where one key blob parses under more than
      // one algorithm. An enrollment with none recorded defaults to RSA
      // EXPLICITLY here: a null would otherwise fall through to the wire
      // claim in [_validateSignature], letting the client pick the verify
      // routine for exactly those enrollments.
      recordSigningAlgo =
          apkamResult.signingAlgo ?? ApkamSignatureVerifier.rsa2048Algo;
    } else {
      // A legacy `pkam:` carries no enrollment id and authenticates as
      // `primary`, the enrollment the flat legacy credential migrates into.
      // A flat key still in the store is one the startup migration has not
      // seen, and is verified against; otherwise `primary`'s recorded key is,
      // under the algorithm the record carries. [_admitUnderLock] settles
      // which of the two verified.
      pkamAuthType = AuthType.pkamLegacy;
      final EnrollmentManager enMgr =
          AtSecondaryServerImpl.getInstance().enrollmentManager;
      publicKey = await enMgr.legacyPkamPublicKey();
      if (publicKey == null) {
        final EnrollDataStoreValue? primary = await enMgr.primaryEnrollment();
        if (primary == null) {
          // The message names the remedy: an atSign onboarded through
          // `enroll:request` has no legacy credential by design, so a caller
          // arriving here almost always holds an enrollment id and did not
          // send it. "No credential" alone reads as an atSign fault.
          logger.warning('Legacy PKAM authentication refused: this atSign '
              'holds neither a flat credential nor a '
              '${EnrollmentManager.primaryEnrollmentId} enrollment');
          throw UnAuthenticatedException(
              'this atSign has no legacy PKAM credential. An atSign onboarded '
              'through enroll:request has none by design: authenticate with '
              'the enrollment id its keyfile carries, as '
              'pkam:enrollmentId:<id>:<signature>');
        }
        // `primary` is judged exactly as an enrollment named on the wire is,
        // so a revoked primary refuses with AT0027.
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
    // One challenge, one attempt, and only while it is live. It is spent here
    // whatever the signature turns out to be, so a caller cannot grind
    // signatures against a single `from:`.
    final String? storedSecret = await consumeChallenge(storedSecretId);
    if (storedSecret == null) {
      // Absent, unreadable or expired, refused with the message and exception
      // a bad signature gets: the wire must not distinguish a stale challenge
      // from a wrong signature, or it becomes an oracle for live session ids.
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
      // Admitting the connection is a read-decide-write like every other
      // enrollment act, so it runs inside the atSign's one
      // enrollment-mutation section. See [_admitUnderLock].
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
      // asks about it like any other enrollment and finds nothing to do.
      enrollId = atConnectionMetadata.enrollmentId;

      // A retrofit's successor caps the enrollment it replaced here, on its
      // first authentication: this is the moment that proves the successor's
      // APKAM private half survived the client-side keyfile write and can be
      // used. Arming it where the successor is stored would start a clock on
      // the predecessor, the only credential that still works, on the
      // strength of a record only the server had written. A no-op for
      // anything that replaced nothing, and it never throws: authentication
      // has already succeeded and must not be undone by bookkeeping.
      if (enrollId != null && enrollId.isNotEmpty) {
        final enMgr = AtSecondaryServerImpl.getInstance().enrollmentManager;
        await enMgr.armRetrofitCapOnFirstAuth(enrollId);
      }
    } else {
      atConnectionMetadata.isAuthenticated = false;
      logger.severe('pkam authentication failed');
      throw UnAuthenticatedException('pkam authentication failed');
    }
  }

  /// The last read of the enrollment state this connection's identity rests
  /// on, and the marking that acts on it, as one enrollment-mutation critical
  /// section. Returns whether the connection was admitted; a refusal with a
  /// wire error code of its own is written into [response] rather than thrown,
  /// as the same refusal is before the signature is checked.
  ///
  /// Read and marking must not be split. An `enroll:revoke` landing between
  /// them is answered `success`, because the revoke sweeps open connections by
  /// the id each one carries and a connection still being authenticated has
  /// none yet. Serialised, only the coherent orders remain: a revoke taking
  /// the section first is seen by the read here and the authentication is
  /// refused; one taking it second finds a connection carrying the id and
  /// closes it. It is the store-wide section because `enroll:delete` and an
  /// elapsed ttl stop an enrollment serving while sweeping no connections at
  /// all.
  ///
  /// It does not stand in for the per-command check:
  /// `AbstractVerbHandler.processInternal` re-reads the enrollment before
  /// every command and closes a connection whose enrollment has left
  /// `approved`. What the section adds is that `success` is never answered on
  /// a state already replaced.
  ///
  /// A legacy authentication is the read-decide-write in full: a flat key
  /// still in the store is absorbed into `primary` here, and the connection is
  /// admitted as `primary` only if `primary` is approved and holds the key
  /// that verified. A second legacy login that waited on the section finds no
  /// flat key and takes that fallback. [verifiedKey] is the key the signature
  /// verified against, [wireSigningAlgo] what the wire said it was.
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
        // Another login rotated `primary` in between, so the key that
        // verified is not the key it holds now. Against the record as it
        // stands that is a bad signature, and is refused as one.
        atConnectionMetadata.isAuthenticated = false;
        logger.severe('pkam authentication failed: the key that verified is '
            'no longer the key ${EnrollmentManager.primaryEnrollmentId} holds');
        throw UnAuthenticatedException('pkam authentication failed');
      }
      enrollId = EnrollmentManager.primaryEnrollmentId;
    } else {
      // Asked again inside the section: the first ask ran before the
      // signature was verified, which is the longest step on this path, so it
      // read the state from before all of it. The refusal is the first ask's
      // refusal code for code, so a client cannot tell which of the two
      // refused it. `isAuthenticated` is left alone, as the first ask leaves
      // it: a failed re-authentication does not end a session already
      // authenticated as something else; only a bad signature does.
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

  /// [recordSigningAlgo] is the algorithm recorded on the enrollment being
  /// authenticated as, and wins over whatever the wire says so that the client
  /// does not choose how its own signature is interpreted. It is null only
  /// when a legacy `pkam:` verifies against the flat credential, which has no
  /// record; the wire value then decides.
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
