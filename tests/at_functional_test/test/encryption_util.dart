import 'dart:typed_data';
import 'dart:convert';

import 'package:crypton/crypton.dart';
import 'package:encrypt/encrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:at_utils/at_logger.dart';

class EncryptionUtil {
  static final _logger = AtSignLogger('EncryptionUtil');

  static IV getIV(String? ivBase64) {
    if (ivBase64 == null) {
      return IV.fromLength(16);
    } else {
      return IV.fromBase64(ivBase64);
    }
  }

  static String generateAESKey() {
    return AES(Key.fromSecureRandom(32)).key.base64;
  }

  static String generateIV({int length = 16}) {
    return IV.fromSecureRandom(length).base64;
  }

  static String encryptValue(String value, String encryptionKey,
      {String? ivBase64}) {
    var aesEncrypter = Encrypter(AES(Key.fromBase64(encryptionKey)));
    var encryptedValue = aesEncrypter.encrypt(value, iv: getIV(ivBase64));
    return encryptedValue.base64;
  }

  static String encryptKey(String aesKey, String publicKey) {
    var rsaPublicKey = RSAPublicKey.fromString(publicKey);
    return rsaPublicKey.encrypt(aesKey);
  }
}
