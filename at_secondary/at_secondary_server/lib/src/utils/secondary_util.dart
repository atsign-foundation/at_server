import 'dart:convert';
import 'package:at_utils/at_logger.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:crypton/crypton.dart';

class SecondaryUtil {
  static var logger = AtSignLogger('Secondary_Util');

  static void saveCookie(String key, String value, String atSign) {
    logger.finer('In Secondary Util saveCookie');
    logger.finer('saveCookie key : ' + key);
    logger.finer('signed challenge : ' + value);
    var atData = AtData();
    atData.data = value;

    var secondaryPersistenceStore =
        SecondaryPersistenceStoreFactory.getInstance()
            .getSecondaryPersistenceStore(atSign);
    var keystoreManager =
        secondaryPersistenceStore.getSecondaryKeyStoreManager();
    SecondaryKeyStore keyStore = keystoreManager.getKeyStore();
    keyStore.put('public:$key', atData,
        time_to_live: 60 * 1000); //expire in 1 min
  }

  static List<String> getSecondaryInfo(String url) {
    List<String> result = [];
    if (url.contains(':')) {
      var arr = url.split(':');
      result.add(arr[0]);
      result.add(arr[1]);
    }
    return result;
  }

  static List<String> getCookieParams(String fromResult) {
    var proof = fromResult.replaceFirst('\n@', '');
    proof = proof.trim();
    logger.info('proof : ' + proof);
    List listAnswer = proof.split(':');
    return listAnswer;
  }

  static String convertCommand(String command) {
    var index = command.indexOf(':');
    // For verbs that does not have ':'. For example verbs like scan, pol.
    if (index == -1) {
      command = command.toLowerCase();
      return command;
    }
    var verb = command.substring(0, index);
    var key = command.substring(index, command.length);
    verb = verb.toLowerCase().replaceAll(' ', '');
    command = verb + key;
    return command;
  }

  static bool isActiveKey(AtData atData) {
    if (atData == null) {
      return false;
    }
    var now = DateTime.now().toUtc().millisecondsSinceEpoch;
    if (atData.metaData != null) {
      var ttb = atData.metaData.availableAt;
      var ttl = atData.metaData.expiresAt;
      if (ttb == null && ttl == null) return true;
      if (ttb != null) {
        var ttb_ms = ttb.toUtc().millisecondsSinceEpoch;
        if (ttb_ms > now) {
          return false;
        }
      }
      if (ttl != null) {
        var ttl_ms = ttl.toUtc().millisecondsSinceEpoch;
        if (ttl_ms < now) {
          return false;
        }
      }
      return true;
    } else {
      return true;
    }
  }

  static String signChallenge(String challenge, String privateKey) {
    var key = RSAPrivateKey.fromString(privateKey);
    challenge = challenge.trim();
    var signature = key.createSHA256Signature(utf8.encode(challenge));
    return base64Encode(signature);
  }

  static String prepareResponseData(String operation, AtData atData) {
    var result;
    if (atData == null) {
      return result;
    }
    switch (operation) {
      case 'meta':
        result = json.encode(atData.metaData.toJson());
        break;
      case 'all':
        result = json.encode(atData.toJson());
        break;
      default:
        result = atData.data;
        break;
    }
    logger.finer('result : $result');
    return result;
  }
}
