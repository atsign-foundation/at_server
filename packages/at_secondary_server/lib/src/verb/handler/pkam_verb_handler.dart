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
    // NOTE folded to the keystore's own fold, so every later comparison
    // against the id the connection carries holds.
    var enrollId = EnrollmentManager.canonicalEnrollmentIdOrNull(
        verbParams[AtConstants.enrollmentId]);
    var sessionID = atConnectionMetadata.sessionID;
    var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    AuthType pkamAuthType;
    String? publicKey;
    // NOTE null lets the wire value decide the algorithm, which is what the
    // flat legacy credential needs.
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
      // NOTE an enrollment with no algorithm recorded defaults to RSA
      // explicitly, so the client never picks the verify routine.
      recordSigningAlgo =
          apkamResult.signingAlgo ?? ApkamSignatureVerifier.rsa2048Algo;
    } else {
      // A legacy `pkam:` carries no enrollment id and authenticates as
      // `primary`, verifying against a flat key if the store still holds one.
      pkamAuthType = AuthType.pkamLegacy;
      final EnrollmentManager enMgr =
          AtSecondaryServerImpl.getInstance().enrollmentManager;
      publicKey = await enMgr.legacyPkamPublicKey();
      if (publicKey == null) {
        final EnrollDataStoreValue? primary = await enMgr.primaryEnrollment();
        if (primary == null) {
          logger.warning('Legacy PKAM authentication refused: this atSign '
              'holds neither a flat credential nor a '
              '${EnrollmentManager.primaryEnrollmentId} enrollment');
          throw UnAuthenticatedException(
              'this atSign has no legacy PKAM credential. An atSign onboarded '
              'through enroll:request has none by design: authenticate with '
              'the enrollment id its keyfile carries, as '
              'pkam:enrollmentId:<id>:<signature>');
        }
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
    // NOTE the challenge is spent here whatever the signature turns out to be.
    final String? storedSecret = await consumeChallenge(storedSecretId);
    if (storedSecret == null) {
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
      // Admission is a read-decide-write, so it runs inside the atSign's one
      // enrollment-mutation section.
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
      enrollId = atConnectionMetadata.enrollmentId;

      // NOTE a retrofit predecessor is settled here, on the first
      // authentication proving the successor's private half is usable.
      if (enrollId != null && enrollId.isNotEmpty) {
        final enMgr = AtSecondaryServerImpl.getInstance().enrollmentManager;
        await enMgr.settlePredecessorOnFirstAuth(enrollId);
      }
    } else {
      atConnectionMetadata.isAuthenticated = false;
      logger.severe('pkam authentication failed');
      throw UnAuthenticatedException('pkam authentication failed');
    }
  }

  /// Re-reads the enrollment this connection's identity rests on and marks the
  /// connection authenticated, returning whether it was admitted.
  ///
  /// Must be called inside the atSign's enrollment-mutation section; a refusal
  /// is written into [response] rather than thrown.
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
        // NOTE another login rotated `primary` in between, so the key that
        // verified is no longer the key it holds; refused as a bad signature.
        atConnectionMetadata.isAuthenticated = false;
        logger.severe('pkam authentication failed: the key that verified is '
            'no longer the key ${EnrollmentManager.primaryEnrollmentId} holds');
        throw UnAuthenticatedException('pkam authentication failed');
      }
      enrollId = EnrollmentManager.primaryEnrollmentId;
    } else {
      // NOTE asked again inside the section, as the first ask read the state
      // from before the signature check.
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

  /// Verifies the PKAM signature, under [recordSigningAlgo] when the
  /// enrollment records one and under the wire's claim when it is null.
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
  /// [publicKey] actually is.
  String? signingAlgo;
}
