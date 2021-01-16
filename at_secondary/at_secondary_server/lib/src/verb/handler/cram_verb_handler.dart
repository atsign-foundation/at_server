import 'dart:collection';
import 'dart:convert';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:crypto/crypto.dart';
import 'package:at_server_spec/at_server_spec.dart';

class CramVerbHandler extends AbstractVerbHandler {
  static Cram cram = Cram();

  CramVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith(getName(VerbEnum.cram) + ':');

  @override
  Verb getVerb() {
    return cram;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {
    var atConnectionMetadata = atConnection.getMetaData();
    var sessionID = atConnectionMetadata.sessionID;
    var digest = verbParams[AT_DIGEST];
    var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    var secret = await keyStore.get('privatekey:at_secret');

    // If there is no secret in keystore then return error
    if (secret == null) {
      logger.finer('privatekey:at_secret is null');
      throw UnAuthenticatedException('Authentication Failed');
    }
    secret = secret.data;
    secret = secret + '$sessionID$atSign';

    //retrieve stored secret using sessionid and atsign
    var storedSecret = await keyStore.get('private:$sessionID$atSign');
    storedSecret = storedSecret?.data;
    secret = '$secret:$storedSecret';
    secret = sha512.convert(utf8.encode(secret));

    // authenticate if retrieved secret is equal to the cram digest passed
    if ('$digest' == '$secret') {
      atConnectionMetadata.isAuthenticated = true;
      var atAccessLog = await AtAccessLogManagerImpl.getInstance()
          .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign);
      await atAccessLog.insert(atSign, cram.name());
      response.data = 'success';
    } else {
      atConnectionMetadata.isAuthenticated = false;
      throw UnAuthenticatedException('Authentication Failed');
    }
  }
}
