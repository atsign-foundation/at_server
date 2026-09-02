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
        // The message NAMES THE REMEDY, because the population that hits this
        // is not a broken atSign but a client sending the wrong shape of
        // authentication. An atSign onboarded through `enroll:request` has no
        // flat credential at all — it never did, once that path stopped
        // writing one — so a caller arriving here is almost always one that
        // holds an enrollment id and did not send it. "No credential" alone
        // reads as an atSign fault and sends the reader looking in the wrong
        // place entirely.
        logger.warning('Legacy PKAM authentication refused: '
            '${AtConstants.atPkamPublicKey} is absent — this atSign has no '
            'legacy credential, or it has been retired');
        throw UnAuthenticatedException(
            'this atSign has no legacy PKAM credential. An atSign onboarded '
            'through enroll:request has none by design: authenticate with the '
            'enrollment id its keyfile carries, as '
            'pkam:enrollmentId:<id>:<signature>');
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
          // The record is absent and must not be created, so this is NOT a
          // first authentication. Either the credential was retired — the key
          // goes with the record, so its absence says so — or this atSign
          // already holds enrollment records, in which case the key at
          // `at_pkam_publickey` did not authenticate before any enrollment
          // existed and so is not a legacy credential. Creating the record in
          // either case would hand a keypair a fresh, unexpiring root
          // identity; in the first it would undo the retirement every time
          // the record expired.
          //
          // The refusal does not say WHICH, because the caller has not
          // authenticated and the two are not its business. The manager logs
          // the distinction, naming what it found. It does name the REMEDY,
          // which is the same either way and is what an operator arriving
          // here actually needs — an established atSign is reached with an
          // enrollment id, not with a flat keyfile.
          atConnectionMetadata.isAuthenticated = false;
          logger.warning('Refusing legacy PKAM authentication: this atSign has '
              'no usable legacy credential');
          throw UnAuthenticatedException(
              'this atSign has no usable legacy PKAM credential. A legacy '
              'credential is adopted only by an atSign that holds no '
              'enrollments: on any other, authenticate with the enrollment id '
              'the keyfile carries, as pkam:enrollmentId:<id>:<signature>, or '
              'enrol this client with enroll:request');
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
      // `enrollId` — the id PRESENTED ON THE WIRE — and deliberately not
      // `connectionEnrollmentId`. They differ for exactly one case: a legacy
      // authentication presents no id but is GIVEN `primary`. Only a wire id
      // names a successor, and `primary` replaced nothing, so keying this on
      // the connection's id would ask the cap to arm a record that can have
      // no predecessor.
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
    // could be sidestepped by the very keyfile it retires.
    //
    // ⚠️ It holds NO public key at all: `apkamPublicKey` is stored EMPTY, and
    // that emptiness is load-bearing rather than an omission. It is what makes
    // an APKAM authentication naming this enrollment fail closed however the
    // id is spelled — the keystore folds ids on the way in, so a spelling that
    // resolves to this record can compare unequal to the literal below, while
    // the empty key does not care. Writing the legacy public key here would
    // reverse that and give one keypair two identities. This refusal is the
    // second guard, not the only one, and it exists to name what the identity
    // IS rather than letting the attempt die at the emptiness check as though
    // the record were broken.
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
