import 'dart:convert';
import 'dart:typed_data';
import 'package:crypton/crypton.dart';
import 'at_demo_data.dart';

String generatePKAMDigest(String atSign, String challenge) {
  var privateKey = pkamPrivateKeyMap[atSign];
  privateKey = privateKey!.trim();
  var key = RSAPrivateKey.fromString(privateKey);
  challenge = challenge.trim();
  var sign =
      key.createSHA256Signature(Uint8List.fromList(utf8.encode(challenge)));
  return base64Encode(sign);
}
