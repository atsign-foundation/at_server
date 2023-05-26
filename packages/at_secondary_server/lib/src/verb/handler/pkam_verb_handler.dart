import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_server_spec/src/connection/at_connection.dart';
import 'package:at_chops/at_chops.dart';
import 'package:at_server_spec/at_server_spec.dart';

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
    var atConnectionMetadata = atConnection.getMetaData();
    var sessionID = atConnectionMetadata.sessionID;
    var signature = verbParams[AT_PKAM_SIGNATURE]!;
    var signingAlgo = verbParams[AT_PKAM_SIGNING_ALGO];
    var hashingAlgo = verbParams[AT_PKAM_HASHING_ALGO];
    var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    var publicKeyData = await keyStore.get(AT_PKAM_PUBLIC_KEY);

    // If there is no public key in the keystore then throw an exception
    if (publicKeyData == null) {
      response.data = 'failure';
      response.isError = true;
      response.errorMessage = 'pkam publickey not found';
      throw UnAuthenticatedException('pkam publickey not found');
    }
    var publicKey = publicKeyData.data;
    var isValidSignature = false;

    //retrieve stored secret using sessionid and atsign
    var storedSecret = await keyStore.get('private:$sessionID$atSign');
    storedSecret = storedSecret?.data;

    var signingAlgoEnum;
    var inputSignature;
    // if no signature algorithm is passed, default to RSA verification. This preserves
    // backward compatibility for old pkam messages without signing algo.
    logger.finer('signingAlgo: $signingAlgo');
    logger.finer('in process verb of branch issue#1229');
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
        utf8.encode('$sessionID$atSign:$storedSecret') as Uint8List,
        inputSignature,
        publicKey);
    //
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
    // authenticate if signature is valid
    if (isValidSignature) {
      atConnectionMetadata.isAuthenticated = true;
      atConnectionMetadata.authType = AuthType.pkam_legacy;
      response.data = 'success';
    } else {
      atConnectionMetadata.isAuthenticated = false;
      response.data = 'failure';
      logger.severe('pkam authentication failed');
      throw UnAuthenticatedException('pkam authentication failed');
    }
  }
}
