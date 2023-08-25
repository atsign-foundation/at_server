import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_server_spec/src/connection/at_connection.dart';
import 'package:at_chops/at_chops.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:meta/meta.dart';

class PkamVerbHandler extends AbstractVerbHandler {
  static Pkam pkam = Pkam();
  static const String _eccAlgo = 'ecc_secp256r1';
  static const String _rsa2048Algo = 'rsa2048';
  static const String _sha256 = 'sha256';
  static const String _sha512 = 'sha512';
  AtChops? atChops;

  PkamVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

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
        atConnection.getMetaData() as InboundConnectionMetadata;
    var enrollId = verbParams[enrollmentId];
    var sessionID = atConnectionMetadata.sessionID;
    var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    AuthType pkamAuthType;
    String? publicKey;

    // Use APKAM public key for verification if enrollId is passed.
    // Otherwise use legacy pkam public key.
    if (enrollId != null && enrollId.isNotEmpty) {
      pkamAuthType = AuthType.apkam;
      ApkamVerificationResult apkamResult =
          await handleApkamVerification(enrollId, atSign);
      if (apkamResult.response.isError) {
        response.isError = apkamResult.response.isError;
        response.errorCode = apkamResult.response.errorCode;
        response.errorMessage = apkamResult.response.errorMessage;
        return;
      }
      publicKey = apkamResult.publicKey;
    } else {
      pkamAuthType = AuthType.pkamLegacy;
      var publicKeyData = await keyStore.get(AT_PKAM_PUBLIC_KEY);
      publicKey = publicKeyData.data;
    }

    if (publicKey == null || publicKey.isEmpty) {
      throw UnAuthenticatedException('pkam publickey not found');
    }
    var isValidSignature =
        await _validateSignature(verbParams, sessionID, atSign, publicKey);
    // authenticate if signature is valid
    if (isValidSignature) {
      atConnectionMetadata.isAuthenticated = true;
      atConnectionMetadata.authType = pkamAuthType;
      atConnectionMetadata.enrollmentId = enrollId;
      response.data = 'success';
    } else {
      atConnectionMetadata.isAuthenticated = false;
      logger.severe('pkam authentication failed');
      throw UnAuthenticatedException('pkam authentication failed');
    }
  }

  @visibleForTesting
  Future<ApkamVerificationResult> handleApkamVerification(
      String enrollId, String atSign) async {
    String enrollmentKey =
        '$enrollId.$newEnrollmentKeyPattern.$enrollManageNamespace$atSign';
    var enrollData = await keyStore.get(enrollmentKey);
    final atData = enrollData.data;
    final enrollDataStoreValue =
        EnrollDataStoreValue.fromJson(jsonDecode(atData));
    EnrollStatus enrollStatus =
        EnrollStatus.values.byName(enrollDataStoreValue.approval!.state);

    ApkamVerificationResult apkamResult = ApkamVerificationResult();
    apkamResult.response = _getApprovalStatus(
        enrollStatus, enrollId, enrollDataStoreValue.approval!.state);
    if (apkamResult.response.isError) {
      return apkamResult;
    }
    apkamResult.publicKey = enrollDataStoreValue.apkamPublicKey;
    return apkamResult;
  }

  Response _getApprovalStatus(
      EnrollStatus enrollStatus, enrollId, approvalState) {
    Response response = Response();
    switch (enrollStatus) {
      case EnrollStatus.denied:
        response.isError = true;
        response.errorCode = 'AT0025';
        response.errorMessage = 'enrollment_id: $enrollId is not approved |'
            ' Status: $approvalState';
        break;
      case EnrollStatus.pending:
        response.isError = true;
        response.errorCode = 'AT0026';
        response.errorMessage = 'enrollment_id: $enrollId is not approved |'
            ' Status: $approvalState';
        break;
      case EnrollStatus.approved:
        // do nothing when enrollment is approved
        break;
      case EnrollStatus.revoked:
        response.isError = true;
        response.errorCode = 'AT0027';
        response.errorMessage = 'enrollment_id: $enrollId is not approved |'
            ' Status: $approvalState';
        break;
      default:
        response.isError = true;
        response.errorCode = 'AT0026';
        response.errorMessage =
            'Could not fetch enrollment status for enrollment_id: $enrollId';
        break;
    }
    return response;
  }

  Future<bool> _validateSignature(
      var verbParams, var sessionId, String atSign, String publicKey) async {
    var signature = verbParams[AT_PKAM_SIGNATURE]!;
    var signingAlgo = verbParams[AT_PKAM_SIGNING_ALGO];
    var hashingAlgo = verbParams[AT_PKAM_HASHING_ALGO];
    var signingAlgoEnum;
    var inputSignature;
    bool isValidSignature = false;
    var storedSecret = await keyStore.get('private:$sessionId$atSign');
    storedSecret = storedSecret?.data;
    // if no signature algorithm is passed, default to RSA verification. This preserves
    // backward compatibility for old pkam messages without signing algo.
    logger.finer('signingAlgo: $signingAlgo');
    if (signingAlgo == null || signingAlgo.isEmpty) {
      signingAlgoEnum = SigningAlgoType.rsa2048;
      inputSignature = base64Decode(signature);
    } else if (signingAlgo == _eccAlgo) {
      signingAlgoEnum = SigningAlgoType.ecc_secp256r1;
      // inputSignature = Uint8List.fromList(signature.codeUnits);
      inputSignature = base64Decode(signature);
    } else if (signingAlgo == _rsa2048Algo) {
      signingAlgoEnum = SigningAlgoType.rsa2048;
      inputSignature = base64Decode(signature);
    }
    logger.finer('signingAlgoEnum: $signingAlgoEnum');
    var hashingAlgoEnum;
    logger.finer('hashingAlgo: $hashingAlgo');
    if (hashingAlgo == null || hashingAlgo.isEmpty) {
      hashingAlgoEnum = HashingAlgoType.sha256;
    } else if (hashingAlgo == _sha256) {
      hashingAlgoEnum = HashingAlgoType.sha256;
    } else if (hashingAlgo == _sha512) {
      hashingAlgoEnum = HashingAlgoType.sha512;
    }
    logger.finer('hashingAlgoEnum: $hashingAlgoEnum');
    final verificationInput = AtSigningVerificationInput(
        utf8.encode('$sessionId$atSign:$storedSecret') as Uint8List,
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
    logger.finer('pkam auth:$isValidSignature');
    return isValidSignature;
  }
}

class ApkamVerificationResult {
  Response response = Response();
  String? publicKey;
}
