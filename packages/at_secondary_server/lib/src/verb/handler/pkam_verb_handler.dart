import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:crypton/crypton.dart';
import 'package:at_server_spec/at_server_spec.dart';

class PkamVerbHandler extends AbstractVerbHandler {
  static Pkam pkam = Pkam();

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
    var atSignPub = RSAPublicKey.fromString(publicKey);

    //retrieve stored secret using sessionid and atsign
    var storedSecret = await keyStore.get('private:$sessionID$atSign');
    storedSecret = storedSecret?.data;

    bool isValidSignature;
    //Throws format exception when signature is not in multiples of 4.
    //Throws error when digest is wrong.
    try {
      isValidSignature = atSignPub.verifySHA256Signature(
          utf8.encode('$sessionID$atSign:$storedSecret') as Uint8List,
          base64Decode(signature));
    } on FormatException {
      logger.severe('invalid pkam signature');
      throw UnAuthenticatedException('pkam authentication failed');
    } on Error {
      logger.severe('pkam authentication failed');
      throw UnAuthenticatedException('pkam authentication failed');
    }
    logger.finer('pkam auth:$isValidSignature');
    // authenticate if signature is valid
    if (isValidSignature) {
      atConnectionMetadata.isAuthenticated = true;
      response.data = 'success';
    } else {
      atConnectionMetadata.isAuthenticated = false;
      response.data = 'failure';
      logger.severe('pkam authentication failed');
      throw UnAuthenticatedException('pkam authentication failed');
    }
  }
}
