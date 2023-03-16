import 'dart:convert';
import 'dart:typed_data';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';
import 'package:crypton/crypton.dart';

class SecondaryUtil {
  static var logger = AtSignLogger('Secondary_Util');

  static Future<void> saveCookie(
      String key, String value, String? atSign) async {
    logger.finer('In Secondary Util saveCookie');
    logger.finer('saveCookie key : $key');
    logger.finer('signed challenge : $value');
    var atData = AtData();
    atData.data = value;

    var secondaryPersistenceStore =
        SecondaryPersistenceStoreFactory.getInstance()
            .getSecondaryPersistenceStore(atSign)!;
    var keystoreManager =
        secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
    SecondaryKeyStore keyStore = keystoreManager.getKeyStore();
    await keyStore.put('public:$key', atData,
        time_to_live: 60 * 1000); //expire in 1 min
  }

  static List<String> getSecondaryInfo(String url) {
    var result = <String>[];
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
    logger.info('proof : $proof');
    List listAnswer = proof.split(':');
    return listAnswer as List<String>;
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

  /// Checks if this record is 'active' i.e. it is non-null, it's been 'born', and it is still 'alive'.
  /// * If [Metadata.availableAt] is set, and we've not reached that time yet, return `false`,
  ///   as the record hasn't yet been 'born'
  /// * If [Metadata.expiresAt] is set, and we've passed that time, return `false`,
  ///   as the record is no longer 'alive'
  /// * Otherwise return `true`
  static bool isActiveKey(AtData? atData) {
    if (atData == null) {
      return false;
    }
    var now = DateTime.now().toUtc().millisecondsSinceEpoch;
    if (atData.metaData != null) {
      var birthTime = atData.metaData!.availableAt;
      var endOfLifeTime = atData.metaData!.expiresAt;
      if (birthTime == null && endOfLifeTime == null) return true;
      if (birthTime != null) {
        var ttbMillis = birthTime.toUtc().millisecondsSinceEpoch;
        if (ttbMillis > now) {
          return false;
        }
      }
      if (endOfLifeTime != null) {
        var ttlMillis = endOfLifeTime.toUtc().millisecondsSinceEpoch;
        if (ttlMillis < now) {
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
    var signature =
        key.createSHA256Signature(utf8.encode(challenge) as Uint8List);
    return base64Encode(signature);
  }

  /// When [key] is supplied, it will be used even if the [atData] already has a key.
  /// This is relevant in the lookup and plookup verb handlers when we need the
  /// client to be able to determine from the response whether the data was
  /// served from cache or not
  static String? prepareResponseData(String? operation, AtData? atData, {String? key}) {
    String? result;
    if (atData == null) {
      return result;
    }
    switch (operation) {
      case 'meta':
        result = json.encode(atData.metaData!.toJson());
        break;
      case 'all':
        var atDataAsMap = atData.toJson();
        if (key != null) {
          atDataAsMap['key'] = key;
        }
        result = json.encode(atDataAsMap);
        break;
      default:
        result = atData.data;
        break;
    }
    logger.finer('prepareResponseData result : $result');
    return result;
  }

  static NotificationPriority getNotificationPriority(String? arg1) {
    if (arg1 == null) {
      return NotificationPriority.low;
    }
    switch (arg1.toLowerCase()) {
      case 'low':
        return NotificationPriority.low;
      case 'medium':
        return NotificationPriority.medium;
      case 'high':
        return NotificationPriority.high;
      default:
        return NotificationPriority.low;
    }
  }

  static MessageType getMessageType(String? arg1) {
    if (arg1 == null) {
      return MessageType.key;
    }
    switch (arg1.toLowerCase()) {
      case 'key':
        return MessageType.key;
      case 'text':
        return MessageType.text;
      default:
        return MessageType.key;
    }
  }

  static OperationType getOperationType(String? type) {
    if (type == null) {
      return OperationType.update;
    }
    switch (type.toLowerCase()) {
      case 'update':
        return OperationType.update;
      case 'delete':
        return OperationType.delete;
      default:
        return OperationType.update;
    }
  }

  static bool getBoolFromString(String? arg1) {
    if ((arg1 != null && arg1.isNotEmpty) && arg1.toLowerCase() == 'true') {
      return true;
    }
    return false;
  }
}
