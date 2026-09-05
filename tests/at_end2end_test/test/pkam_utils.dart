import 'dart:convert';
import 'dart:typed_data';

import 'package:at_auth/at_auth.dart';
// ignore: depend_on_referenced_packages
import 'package:crypton/crypton.dart';
import 'at_demo_data.dart';

/// Enrollment ids read off local keyfiles, by atSign; absent for an atSign
/// whose key came from [pkamPrivateKeyMap].
final Map<String, String> enrollmentIdMap = {};

Future<void> _loadKeyfile(String atSign) async {
  AtKeys keys = await FileAtKeysIo().read(atSign);
  pkamPrivateKeyMap[atSign] = keys.apkamPrivateKey!.toString();
  final String? id = keys.enrollmentId;
  if (id != null && id.isNotEmpty) enrollmentIdMap[atSign] = id;
}

/// The enrollment id [atSign] authenticates as, or null for a legacy `pkam:`.
Future<String?> enrollmentIdOf(String atSign) async {
  if (!pkamPrivateKeyMap.containsKey(atSign)) await _loadKeyfile(atSign);
  return enrollmentIdMap[atSign];
}

/// ⚠️ WIRE PIN: the two spellings of the pkam verb; frozen, the atServer
/// parses them by shape.
String pkamCommand(String digest, String? enrollmentId) => enrollmentId == null
    ? 'pkam:$digest'
    : 'pkam:enrollmentId:$enrollmentId:$digest';

Future<String> generatePKAMDigest(String atSign, String challenge) async {
  if (!pkamPrivateKeyMap.containsKey(atSign)) await _loadKeyfile(atSign);
  String privateKey = pkamPrivateKeyMap[atSign]!;
  privateKey = privateKey.trim();
  var key = RSAPrivateKey.fromString(privateKey);
  challenge = challenge.trim();
  var sign =
      key.createSHA256Signature(Uint8List.fromList(utf8.encode(challenge)));
  return base64Encode(sign);
}
