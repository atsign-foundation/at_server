import 'dart:convert';
import 'dart:typed_data';

import 'package:at_auth/at_auth.dart';
// ignore: depend_on_referenced_packages
import 'package:crypton/crypton.dart';
import 'at_demo_data.dart';

Future<String> generatePKAMDigest(String atSign, String challenge) async {
  if (!pkamPrivateKeyMap.containsKey(atSign)) {
    // look for local atKeys file, and load it
    AtKeys keys = await FileAtKeysIo().read(atSign);
    pkamPrivateKeyMap[atSign] = keys.apkamPrivateKey!.toString();
  }
  String privateKey = pkamPrivateKeyMap[atSign]!;
  privateKey = privateKey.trim();
  var key = RSAPrivateKey.fromString(privateKey);
  challenge = challenge.trim();
  var sign =
      key.createSHA256Signature(Uint8List.fromList(utf8.encode(challenge)));
  return base64Encode(sign);
}
