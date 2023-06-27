import 'dart:collection';
import 'dart:math';
import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:convert/convert.dart';
import 'abstract_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:crypto/crypto.dart';
import 'package:intl/intl.dart';
import 'dart:convert';
import 'package:expire_cache/expire_cache.dart';

class TotpVerbHandler extends AbstractVerbHandler {
  static Totp totpVerb = Totp();
  //#TODO replace sharedSecret
  static String sharedSecret = 'HelloTotp';
  static final expireDuration = Duration(seconds: 90);
  static ExpireCache<String, String> cache =
      ExpireCache<String, String>(expireDuration: expireDuration);
  TotpVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command == 'totp:get' || command.startsWith('totp:validate');

  @override
  Verb getVerb() => totpVerb;

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    final operation = verbParams['operation'];
    switch (operation) {
      case 'get':
        if (!atConnection.getMetaData().isAuthenticated) {
          throw UnAuthenticatedException(
              'totp:get requires authenticated connection');
        }
        var totp = generateTOTP(sharedSecret);
        response.data = totp;
        await cache.set(totp, totp);
        break;
      case 'validate':
        String? totp = verbParams['totp'];
        if (totp != null && (await cache.get(totp)) == totp) {
          response.data = 'valid';
        } else {
          response.data = 'invalid';
        }
        break;
    }
  }

  String generateTOTP(String secretKey) {
    final epochTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final timeStep = 90; // Time step in seconds
    final time = (epochTime ~/ timeStep).toRadixString(16).padLeft(16, '0');

    final secretKeyBytes = utf8.encode(secretKey);
    final hmacSha1 = Hmac(sha1, secretKeyBytes);
    final digest = hmacSha1.convert(hex.decode(time));

    final offset = digest.bytes[digest.bytes.length - 1] & 0xf;
    final truncatedBytes = digest.bytes.sublist(offset, offset + 4);
    final truncatedCode = bytesToInt(truncatedBytes) & 0x7fffffff;

    final totpLength = 6; // TOTP code length
    final totpCode = (truncatedCode % pow(10, totpLength))
        .toString()
        .padLeft(totpLength, '0');

    return totpCode;
  }

  int bytesToInt(List<int> bytes) {
    int result = 0;
    for (final b in bytes) {
      result = result * 256 + b;
    }
    return result;
  }
}
