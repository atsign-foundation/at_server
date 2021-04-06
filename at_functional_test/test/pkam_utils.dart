import 'dart:convert';

import 'package:crypton/crypton.dart';

import 'at_demo_data.dart';

String generatePKAMDigest(String atsign, String challenge) {
  var privateKey = pkamPrivateKeyMap[atsign];
  privateKey = privateKey.trim();
  var key = RSAPrivateKey.fromString(privateKey);
  challenge = challenge.trim();
  var sign = key.createSHA256Signature(utf8.encode(challenge));
  return base64Encode(sign);
}
