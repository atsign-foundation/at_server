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
    // Folded to match the keystore, which lowercases every key it is given.
    // Without this an enrollment id spelled in another case resolves to the
    // same RECORD while comparing unequal to the id everything downstream
    // holds — so a revoke would not drop the connection, and the revoked
    // credential would go on authenticating. Ids are server-issued and
    // already lowercase; this rejects nothing, it just stops a non-canonical
    // spelling of one from travelling further than the lookup.
    var enrollId = verbParams[AtConstants.enrollmentId]?.toLowerCase();
    var sessionID = atConnectionMetadata.sessionID;
    var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    AuthType pkamAuthType;
    String? publicKey;
    // Legacy PKAM has no enrollment record to be authoritative about, and may
    // legitimately present ecc_secp256r1, so it goes on using the wire value.
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
      pkamAuthType = AuthType.pkamLegacy;
      // ABSENT is a normal state now, not a broken atSign: retiring the
      // legacy credential removes this key, and that is what retirement IS.
      // `keyStore.get` THROWS for a missing key rather than returning null,
      // so the emptiness guard below never saw that case and a retired
      // credential surfaced a keystore exception where an authentication
      // refusal belongs.
      try {
        publicKey = (await keyStore.get(AtConstants.atPkamPublicKey))?.data;
      } on KeyNotFoundException {
        logger.warning('Legacy PKAM authentication refused: '
            '${AtConstants.atPkamPublicKey} is absent — this atSign has no '
            'legacy credential, or it has been retired');
        throw UnAuthenticatedException(
            'this atSign has no legacy PKAM credential');
      }
    }

    if (publicKey == null || publicKey.isEmpty) {
      throw UnAuthenticatedException('pkam publickey not found');
    }

    String storedSecretId = 'private:$sessionID$atSign';
    bool isValidSignature = await _validateSignature(
      verbParams,
      sessionID,
      atSign,
      publicKey,
      recordSigningAlgo,
      storedSecretId,
    );

    if (isValidSignature) {
      // We're good
      // remove the stored secret
      try {
        await keyStore.remove(storedSecretId);
      } catch (e) {
        logger.warning('Failed to immediately remove $storedSecretId');
      }

      // A legacy connection authenticates AS the housekeeping enrollment.
      // Created here, on the first legacy authentication, rather than at
      // onboarding: almost every atSign predates the record, and this is the
      // one moment the server can prove the legacy credential is live.
      //
      // BEFORE the connection is marked authenticated, so a store fault fails
      // the authentication rather than admitting a connection whose enrollment
      // id names nothing. That is the opposite posture from the cap arming
      // below, deliberately — the cap is bookkeeping about a different record,
      // this is the identity this connection is about to carry.
      //
      // ⚠️ A READ therefore mutates the atSign: the first `enroll:list` over a
      // legacy connection creates this record. Accepted, because the
      // alternative is a credential no roster shows and no verb can retire.
      String? connectionEnrollmentId = enrollId;
      if (pkamAuthType == AuthType.pkamLegacy) {
        final housekeeping = await AtSecondaryServerImpl.getInstance()
            .enrollmentManager
            .ensureHousekeepingEnrollment();
        if (housekeeping == null) {
          // The record is absent AND the legacy key has gone, which together
          // mean the credential was RETIRED — not that this is a first
          // authentication. Re-creating it here would hand the retired
          // keyfile a fresh, unexpiring enrollment and undo the retirement,
          // every time it expired.
          atConnectionMetadata.isAuthenticated = false;
          logger.warning('Refusing legacy PKAM authentication: this atSign\'s '
              'legacy credential has been retired');
          throw UnAuthenticatedException(
              'the legacy credential for this atSign has been retired');
        }

        // The legacy credential is only as live as its enrollment. Revoking
        // that record is what makes revoking the legacy keyfile possible at
        // all — before it there was no verb that could — and an EXPIRED one
        // is the cap having retired it after a successful retrofit. Either
        // way the signature was valid and the credential is not.
        final String? state = housekeeping.approval?.state;
        if (state != EnrollmentStatus.approved.name) {
          atConnectionMetadata.isAuthenticated = false;
          logger.warning('Refusing legacy PKAM authentication: '
              '${EnrollmentManager.housekeepingEnrollmentId} is $state');
          throw UnAuthenticatedException(
              'the legacy credential for this atSign is $state');
        }
        connectionEnrollmentId = EnrollmentManager.housekeepingEnrollmentId;
      }

      atConnectionMetadata.isAuthenticated = true;
      atConnectionMetadata.authType = pkamAuthType;
      atConnectionMetadata.enrollmentId = connectionEnrollmentId;
      response.data = 'success';

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
      // ⛔ `enrollId` — the id PRESENTED ON THE WIRE — and deliberately not
      // `connectionEnrollmentId`. They differ for exactly one case and it is
      // the dangerous one: a legacy authentication presents no id but is
      // given `primary`, whose recorded apkamPublicKey IS
      // `at_pkam_publickey` by construction. Keying this block on the
      // connection's id would therefore hand dropVestigialLegacyKey a perfect
      // value match on every legacy authentication, and it would delete the
      // credential that had just authenticated — killing legacy access on
      // every atSign, at first use, irreversibly, since that record cannot be
      // rewritten over the wire.
      //
      // The two names look interchangeable here and are not. Pinned by
      // `legacy authentication does not delete its own credential`.
      if (enrollId != null && enrollId.isNotEmpty) {
        final enMgr = AtSecondaryServerImpl.getInstance().enrollmentManager;
        await enMgr.armRetrofitCapOnFirstAuth(enrollId);

        // A SIBLING call rather than a step inside the cap arming, which
        // returns early for exactly this population: an enrollment that
        // replaced nothing. That is the whole of the case this addresses — an
        // atSign onboarded by CRAM plus enroll:request, whose first
        // enrollment's APKAM key was copied to `at_pkam_publickey` for old
        // clients and has been a second way in ever since.
        await enMgr.dropVestigialLegacyKey(enrollId, publicKey);
      }
    } else {
      // Nope
      atConnectionMetadata.isAuthenticated = false;
      logger.severe('pkam authentication failed');
      throw UnAuthenticatedException('pkam authentication failed');
    }
  }

  @visibleForTesting
  Future<ApkamVerificationResult> verifyEnrollmentIsActive(
      String enId, String atSign) async {
    late final EnrollDataStoreValue enVal;
    ApkamVerificationResult apkamResult = ApkamVerificationResult();
    EnrollmentStatus? enrollStatus;
    EnrollmentManager enMgr =
        AtSecondaryServerImpl.getInstance().enrollmentManager;

    // The housekeeping enrollment is reachable ONLY by legacy authentication.
    // It exists to give the legacy keyfile a lifecycle, and a credential
    // reachable both with and without an enrollment id would have two: the
    // legacy gates below would be bypassed by naming it, and its retirement
    // could be sidestepped by the very keyfile it retires. It also holds the
    // LEGACY public key, so an APKAM signature could never verify against it
    // — this refuses the attempt in terms of what it is rather than letting
    // it fail as a bad signature.
    if (enId == EnrollmentManager.housekeepingEnrollmentId) {
      apkamResult.response.isError = true;
      apkamResult.response.errorCode = 'AT0009';
      apkamResult.response.errorMessage =
          'enrollment_id: $enId is reachable only by legacy PKAM '
          'authentication';
      return apkamResult;
    }

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
    String storedSecretId,
  ) async {
    var signature = verbParams[AtConstants.atPkamSignature]!;
    var signingAlgo =
        recordSigningAlgo ?? verbParams[AtConstants.atPkamSigningAlgo];
    var hashingAlgo = verbParams[AtConstants.atPkamHashingAlgo];
    bool isValidSignature = false;
    var storedSecretData = await keyStore.get(storedSecretId);
    var storedSecret = storedSecretData?.data;
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
