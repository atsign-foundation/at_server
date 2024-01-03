import 'dart:convert';
import 'dart:typed_data';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:crypton/crypton.dart';
import 'package:crypto/crypto.dart';

class AuthenticationUtils {

  static String generatePKAMDigest(String privateKey, String challenge) {
    privateKey = privateKey.trim();
    var key = RSAPrivateKey.fromString(privateKey);
    challenge = challenge.trim();
    var sign =
        key.createSHA256Signature(Uint8List.fromList(utf8.encode(challenge)));
    return base64Encode(sign);
  }

  static String getCRAMDigest(String atSign, String key) {
    var secret = cramKeyMap[atSign];
    secret = secret!.trim();
    var challenge = key;
    challenge = challenge.trim();
    var combo = '$secret$challenge';
    var bytes = utf8.encode(combo);
    var digest = sha512.convert(bytes);

    return digest.toString();
  }
}
