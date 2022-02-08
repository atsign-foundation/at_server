import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:crypton/crypton.dart';

import 'at_demo_data.dart';

String generatePKAMDigest(String atsign, String challenge) {
  var privateKey = pkamPrivateKeyMap[atsign];
  privateKey = privateKey!.trim();
  var key = RSAPrivateKey.fromString(privateKey);
  challenge = challenge.trim();
  var sign =
      key.createSHA256Signature(Uint8List.fromList(utf8.encode(challenge)));
  return base64Encode(sign);
}

/// Returns the digest of the user.
String getDigest(String atsign, String key) {
  var secret = cramKeyMap[atsign];
  secret = secret!.trim();
  var challenge = key;
  challenge = challenge.trim();
  var combo = '$secret$challenge';
  var bytes = utf8.encode(combo);
  var digest = sha512.convert(bytes);

  return digest.toString();
}
