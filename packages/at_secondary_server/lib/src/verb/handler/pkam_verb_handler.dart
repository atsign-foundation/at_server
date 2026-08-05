import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:meta/meta.dart';

class PkamVerbHandler extends AbstractVerbHandler {
  static Pkam pkam = Pkam();
  static const String _eccAlgo = 'ecc_secp256r1';
  static const String _rsa2048Algo = 'rsa2048';
  static const String _mlDsa65Algo = 'mldsa65';
  static const String _sha256 = 'sha256';
  static const String _sha512 = 'sha512';
  AtChops? atChops;

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
    var enrollId = verbParams[AtConstants.enrollmentId];
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
      recordSigningAlgo = apkamResult.signingAlgo ?? _rsa2048Algo;
    } else {
      pkamAuthType = AuthType.pkamLegacy;
      var publicKeyData = await keyStore.get(AtConstants.atPkamPublicKey);
      publicKey = publicKeyData?.data;
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

      atConnectionMetadata.isAuthenticated = true;
      atConnectionMetadata.authType = pkamAuthType;
      atConnectionMetadata.enrollmentId = enrollId;
      response.data = 'success';
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

    Uint8List? inputSignature = base64Decode(signature);
    SigningAlgoType signingAlgoEnum = _getSigningAlgoType(signingAlgo);
    logger.finer('signingAlgoEnum: $signingAlgoEnum');

    HashingAlgoType hashingAlgoEnum = _getHashingAlgoType(hashingAlgo);
    logger.finer('hashingAlgoEnum: $hashingAlgoEnum');

    final verificationInput = AtSigningVerificationInput(
        utf8.encode('$sessionId$atSign:$storedSecret'),
        inputSignature,
        publicKey);
    verificationInput.signingAlgoType = signingAlgoEnum;
    verificationInput.hashingAlgoType = hashingAlgoEnum;
    verificationInput.signingMode = AtSigningMode.pkam;
    try {
      atChops ??= AtChopsImpl(AtChopsKeys.create(null, null));
      final verificationResult = atChops!.verify(verificationInput);
      isValidSignature = verificationResult.result;
    } on Exception catch (e) {
      logger.finer('Exception in pkam signature verification: ${e.toString()}');
    }
    logger.finer('PKAM auth: $isValidSignature');
    return isValidSignature;
  }

  SigningAlgoType _getSigningAlgoType(String? signingAlgo) {
    // if no signature algorithm is passed, default to RSA verification. This preserves
    // backward compatibility for old pkam messages without signing algo.
    logger.finer('signingAlgo: $signingAlgo');
    if (signingAlgo == _eccAlgo) {
      return SigningAlgoType.ecc_secp256r1;
    } else if (signingAlgo == _rsa2048Algo) {
      return SigningAlgoType.rsa2048;
    } else if (signingAlgo == _mlDsa65Algo) {
      // Without this branch a post-quantum APKAM keypair falls through to the
      // RSA default below and can never authenticate at all — the signature is
      // well-formed, just interpreted under the wrong algorithm.
      return SigningAlgoType.mldsa65;
    }
    return SigningAlgoType.rsa2048;
  }

  HashingAlgoType _getHashingAlgoType(String? hashingAlgo) {
    logger.finer('hashingAlgo: $hashingAlgo');
    if (hashingAlgo == _sha256) {
      return HashingAlgoType.sha256;
    } else if (hashingAlgo == _sha512) {
      return HashingAlgoType.sha512;
    }
    // defaults to SHA-256
    return HashingAlgoType.sha256;
  }
}

class ApkamVerificationResult {
  Response response = Response();
  String? publicKey;

  /// The signing algorithm recorded on the enrollment, which is what
  /// [publicKey] actually is. Null on a legacy enrollment predating the field.
  String? signingAlgo;
}
