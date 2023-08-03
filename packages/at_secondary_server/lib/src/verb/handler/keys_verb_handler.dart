import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class KeysVerbHandler extends AbstractVerbHandler {
  static Keys keys = Keys();

  KeysVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  // Method to verify whether command is accepted or not
  // Input: command
  @override
  bool accept(String command) => command.startsWith('keys:');

  // Method to return Instance of verb belongs to this VerbHandler
  @override
  Verb getVerb() {
    return keys;
  }

  // Method which will process update Verb
  // This will process given verb and write response to response object
  // Input : Response, verbParams, AtConnection
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    final keyVisibility = verbParams[visibility];
    final atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    bool hasManageAccess = false;
    var connectionMetadata =
        atConnection.getMetaData() as InboundConnectionMetadata;
    final enrollIdFromMetadata = connectionMetadata.enrollApprovalId;
    logger.finer('enrollIdFromMetadata:$enrollIdFromMetadata');
    final key =
        '$enrollIdFromMetadata.$newEnrollmentKeyPattern.$enrollManageNamespace';
    var enrollData;
    try {
      enrollData = await keyStore.get('$key$atSign');
    } on KeyNotFoundException {
      logger.warning('enrollment key not found in keystore $key');
      throw AtEnrollmentException(
          'Enrollment Id $enrollIdFromMetadata not found in keystore');
    }
    if (enrollData != null) {
      final enrollDataStoreValue =
          EnrollDataStoreValue.fromJson(jsonDecode(enrollData.data));
      if (enrollDataStoreValue.approval!.state != 'approved') {
        throw AtEnrollmentException(
            'Enrollment Id $enrollmentId is not approved. current state :${enrollDataStoreValue.approval!.state}');
      }
      hasManageAccess =
          enrollDataStoreValue.namespaces.containsKey(enrollManageNamespace) &&
              enrollDataStoreValue.namespaces[enrollManageNamespace] == 'rw';
    }
    final value = verbParams[keyValue];
    final valueJson = {};
    valueJson['value'] = value;
    valueJson['keyType'] = verbParams[keyType];
    valueJson[enrollmentId] = enrollIdFromMetadata;
    final operation = verbParams[AT_OPERATION];
    switch (operation) {
      case 'put':
        try {
          logger.finer('value:$valueJson');
          // update the key in data store
          final atData = AtData();
          atData.data = jsonEncode(valueJson);
          var result;
          // for backward compatibility, store the default encryption public key as ref key to public:publickey
          // for now skip commit log for keys created through this verb. If we update/create other keys in the future e.g publickey@alice, @bob:shared_key@alice, change the impl
          if (keyVisibility == 'public') {
            final publicKeyName = _getPublicKeyName(verbParams, atSign);
            result =
                await keyStore.put(publicKeyName, atData, skipCommit: true);
            logger.finer('publicKeyName:$publicKeyName');
          } else if (keyVisibility == 'private') {
            final privateKeyName = _getPrivateKeyName(verbParams, atSign);
            logger.finer('privateKeyName:$privateKeyName');
            valueJson['encryptionKeyName'] = verbParams[encryptionKeyName];
            atData.data = jsonEncode(valueJson);
            result =
                await keyStore.put(privateKeyName, atData, skipCommit: true);
          } else if (keyVisibility == 'self') {
            final selfKeyName = _getSelfKeyName(verbParams, atSign);
            logger.finer('selfKeyName:$selfKeyName');
            valueJson['encryptionKeyName'] = verbParams[encryptionKeyName];
            atData.data = jsonEncode(valueJson);
            result = await keyStore.put(selfKeyName, atData, skipCommit: true);
          }
          response.data = result.toString();
        } catch (e, st) {
          logger.warning('$e\n$st');
        }
        break;
      case 'get':
        final keyVisibility = verbParams[visibility];
        final keyNameFromParams = verbParams[keyName];
        logger.finer('keyVisibility: $keyVisibility');
        logger.finer('keyNameFromParams: $keyNameFromParams');
        var result;
        final filteredKeys = [];
        if (keyNameFromParams != null && keyNameFromParams.isNotEmpty) {
          var value;
          try {
            value = await keyStore.get(keyNameFromParams);
            response.data = value.data;
          } on KeyNotFoundException {
            throw KeyNotFoundException(
                'key $keyNameFromParams not found in keystore');
          }
        }
        if (hasManageAccess) {
          result = await keyStore.getKeys(
              regex:
                  '.*$keyVisibility.*__global$atSign\$|.*$keyVisibility.*__manage$atSign\$');
          logger.finer('get keys result:$result');

          for (String key in result) {
            filteredKeys.add(key);
          }
          response.data = jsonEncode(filteredKeys);
        } else {
          if (keyVisibility == 'private') {
            final value = await keyStore.get(
                '$enrollIdFromMetadata.$defaultEncryptionPrivateKey.$enrollManageNamespace$atSign');
            if (value != null && value.data != null) {
              filteredKeys.add(
                  '$enrollIdFromMetadata.$defaultEncryptionPrivateKey.$enrollManageNamespace$atSign');
            }
          } else if (keyVisibility == 'self') {
            final value = await keyStore.get(
                '$enrollIdFromMetadata.$defaultSelfEncryptionKey.$enrollManageNamespace$atSign');
            if (value != null && value.data != null) {
              filteredKeys.add(
                  '$enrollIdFromMetadata.$defaultSelfEncryptionKey.$enrollManageNamespace$atSign');
            }
          }
          response.data = jsonEncode(filteredKeys);
        }
        break;
      case 'delete':
        final keyNameFromParams = verbParams[keyName];
        logger.finer('keyNameFromParams: $keyNameFromParams');
        response.data =
            (await keyStore.remove(keyNameFromParams, skipCommit: true))
                .toString();
        break;
    }
  }

  String _getPublicKeyName(HashMap<String, String?> verbParams, String atSign) {
    return '${verbParams[visibility]}:${verbParams[keyName]}.__${verbParams[visibility]}_keys.${verbParams[namespace]}$atSign';
  }

  String _getPrivateKeyName(
      HashMap<String, String?> verbParams, String atSign) {
    return '${verbParams[visibility]}:${verbParams[APP_NAME]}.${verbParams[deviceName]}.${verbParams[keyName]}.__${verbParams[visibility]}_keys.${verbParams[namespace]}$atSign';
  }

  String _getSelfKeyName(HashMap<String, String?> verbParams, String atSign) {
    return '${verbParams[APP_NAME]}.${verbParams[deviceName]}.${verbParams[keyName]}.__${verbParams[visibility]}_keys.${verbParams[namespace]}$atSign';
  }
}
