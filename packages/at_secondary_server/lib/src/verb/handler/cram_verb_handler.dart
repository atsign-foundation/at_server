import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:crypto/crypto.dart';

class CramVerbHandler extends AbstractVerbHandler {
  static Cram cram = Cram();

  final AtAccessLog accessLog;

  CramVerbHandler(super.keyValueStore, {required this.accessLog});

  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.cram)}:');

  @override
  Verb getVerb() {
    return cram;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var sessionID = atConnection.metaData.sessionID;
    final digestFromClient = verbParams[AtConstants.atDigest];
    if (digestFromClient == null) {
      throw UnAuthenticatedException('Authentication Failed');
    }

    var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    AtData? internalSecret = await keyStore.get('privatekey:at_secret');

    // If there is no secret in keystore then return error
    if (internalSecret == null) {
      logger.severe('privatekey:at_secret is null');
      throw UnAuthenticatedException('Authentication Failed');
    }

    //retrieve stored secret using sessionid and atsign
    String storedSecretId = 'private:$sessionID$atSign';
    String? storedSecret = (await keyStore.get(storedSecretId))?.data;
    String expectedDigest = sha512
        .convert(utf8
            .encode('${internalSecret.data}$sessionID$atSign:$storedSecret'))
        .toString();

    // add a bit of jitter so it's impossible to do any timing-based attacks
    // to determine the cram secret
    await Future.delayed(Duration(microseconds: rand.nextInt(1000)));
    // Verify that the expected digest == cram digest from client
    if (digestFromClient == expectedDigest) {
      atConnection.metaData.isAuthenticated = true;
      atConnection.metaData.authType = AuthType.cram;
      try {
        await accessLog.insert(atSign, cram.name());
      } on DataStoreException catch (e) {
        logger.severe('Hive error adding to access log:${e.toString()}');
      }

      // remove the stored secret
      try {
        await keyStore.remove(storedSecretId);
      } catch (e) {
        logger.warning('Failed to immediately remove $storedSecretId');
      }

      response.data = 'success';
    } else {
      atConnection.metaData.isAuthenticated = false;
      throw UnAuthenticatedException('Authentication Failed');
    }
  }
}
