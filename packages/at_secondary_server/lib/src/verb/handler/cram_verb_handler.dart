import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:crypto/crypto.dart';

class CramVerbHandler extends AbstractVerbHandler {
  static Cram cram = Cram();

  final AtAccessLog accessLog;

  CramVerbHandler(super.keyStore, {required this.accessLog});

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

    if (internalSecret == null ||
        internalSecret.data == null ||
        internalSecret.data!.isEmpty) {
      logger.severe('privatekey:at_secret is null or empty');
      throw UnAuthenticatedException('Authentication Failed');
    }

    String storedSecretId = 'private:$sessionID$atSign';
    // NOTE the challenge is spent on read, so one `from:` buys one attempt.
    String? storedSecret = await consumeChallenge(storedSecretId);
    if (storedSecret == null) {
      atConnection.metaData.isAuthenticated = false;
      logger.severe('cram authentication failed: no live challenge for'
          ' session $sessionID');
      throw UnAuthenticatedException('Authentication Failed');
    }
    String expectedDigest = sha512
        .convert(utf8
            .encode('${internalSecret.data}$sessionID$atSign:$storedSecret'))
        .toString();

    // NOTE the jitter keeps the comparison's duration from leaking the secret.
    await Future.delayed(Duration(microseconds: rand.nextInt(1000)));
    if (digestFromClient == expectedDigest) {
      atConnection.metaData.isAuthenticated = true;
      atConnection.metaData.authType = AuthType.cram;
      // NOTE a CRAM connection stands over no enrollment, so any id left by an
      // earlier `pkam:` on this connection is cleared.
      (atConnection.metaData as InboundConnectionMetadata).enrollmentId = null;
      try {
        await accessLog.insert(atSign, cram.name());
      } on DataStoreException catch (e) {
        logger.severe('Hive error adding to access log:${e.toString()}');
      }

      response.data = 'success';
    } else {
      atConnection.metaData.isAuthenticated = false;
      throw UnAuthenticatedException('Authentication Failed');
    }
  }
}
