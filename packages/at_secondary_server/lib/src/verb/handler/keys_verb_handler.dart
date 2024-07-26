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

  KeysVerbHandler(super.keyStore);

  @override
  bool accept(String command) => command.startsWith('keys:');

  @override
  Verb getVerb() {
    return keys;
  }

  @override
  Future<void> processVerb(
    Response response,
    HashMap<String, String?> verbParams,
    InboundConnection atConnection,
  ) async {
    final keyVisibility = verbParams[AtConstants.visibility];
    final atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    bool hasManageAccess = false;
    var connectionMetadata = atConnection.metaData as InboundConnectionMetadata;
    final enrollIdFromMetadata = connectionMetadata.enrollmentId;
    if (enrollIdFromMetadata == null) {
      throw AtEnrollmentException(
          'Keys verb cannot be accessed without an enrollmentId');
    }
    logger.finer('enrollIdFromMetadata:$enrollIdFromMetadata');
    final key =
        '$enrollIdFromMetadata.$newEnrollmentKeyPattern.$enrollManageNamespace';

    var enrollData = await _getEnrollData(key, atSign);
    if (enrollData != null) {
      final enrollDataStoreValue =
          EnrollDataStoreValue.fromJson(jsonDecode(enrollData.data!));
      if (enrollDataStoreValue.approval?.state != 'approved') {
        throw AtEnrollmentException(
            'Enrollment Id $enrollIdFromMetadata is not approved. current state: ${enrollDataStoreValue.approval?.state}');
      }
      hasManageAccess =
          enrollDataStoreValue.namespaces[enrollManageNamespace] == 'rw';
    }

    final value = verbParams[AtConstants.keyValue];
    final valueJson = {
      'value': value,
      'keyType': verbParams[AtConstants.keyType],
      AtConstants.enrollmentId: enrollIdFromMetadata
    };
    final operation = verbParams[AtConstants.operation];

    switch (operation) {
      case 'put':
        await _handlePutOperation(
            verbParams, atSign, keyVisibility, valueJson, response);
        break;
      case 'get':
        await _handleGetOperation(verbParams, keyVisibility, hasManageAccess,
            response, enrollIdFromMetadata);
        break;
      case 'delete':
        await _handleDeleteOperation(verbParams, response);
        break;
    }
  }

  Future<AtData?> _getEnrollData(String key, String atSign) async {
    try {
      return await keyStore.get('$key$atSign');
    } on KeyNotFoundException {
      logger.warning('enrollment key not found in keystore $key');
      throw AtEnrollmentException('Enrollment Id $key not found in keystore');
    }
  }

  Future<void> _handlePutOperation(
    HashMap<String, String?> verbParams,
    String atSign,
    String? keyVisibility,
    Map<String, dynamic> valueJson,
    Response response,
  ) async {
    final keyName = _getKeyName(verbParams, atSign, keyVisibility);
    if (keyName != null) {
      valueJson['encryptionKeyName'] =
          verbParams[AtConstants.encryptionKeyName];
      final atData = AtData()..data = jsonEncode(valueJson);
      final result = await keyStore.put(keyName, atData, skipCommit: true);
      response.data = result.toString();
    }
  }

  Future<void> _handleGetOperation(
    HashMap<String, String?> verbParams,
    String? keyVisibility,
    bool hasManageAccess,
    Response response,
    String enrollIdFromMetadata,
  ) async {
    final keyNameFromParams = verbParams[AtConstants.keyName];
    var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    if (keyNameFromParams != null && keyNameFromParams.isNotEmpty) {
      try {
        final value = await keyStore.get(keyNameFromParams);
        response.data = value.data;
        return;
      } on KeyNotFoundException {
        throw KeyNotFoundException(
            'key $keyNameFromParams not found in keystore');
      }
    }
    final filteredKeys = await _getFilteredKeys(
        keyVisibility, hasManageAccess, enrollIdFromMetadata, atSign);
    response.data = jsonEncode(filteredKeys);
  }

  /// If current enrollment has __manage access then return both __global and __manage keys with visibility [keyVisibility]
  /// Otherwise return only __global keys with visibility [keyVisibility]
  /// Also return the encrypted default encryption private key and encrypted self encryption key for enrollmentId [enrollIdFromMetadata]
  Future<List<String>> _getFilteredKeys(String? keyVisibility,
      bool hasManageAccess, String enrollIdFromMetadata, String atSign) async {
    final result = keyVisibility != null && keyVisibility.isNotEmpty
        ? hasManageAccess
            ? keyStore.getKeys(
                regex:
                    '.*$keyVisibility.*__global$atSign\$|.*$keyVisibility.*__manage$atSign\$')
            : keyStore.getKeys(
                regex: '.*__${keyVisibility}_keys.__global$atSign\$')
        : <String>[];

    final filteredKeys = <String>[];
    for (final key in result) {
      await _addKeyIfEnrollmentIdMatches(
          filteredKeys, key, enrollIdFromMetadata);
    }

    final keyMap = {
      'private':
          '$enrollIdFromMetadata.${AtConstants.defaultEncryptionPrivateKey}.$enrollManageNamespace$atSign',
      'self':
          '$enrollIdFromMetadata.${AtConstants.defaultSelfEncryptionKey}.$enrollManageNamespace$atSign',
    };

    final keyString = keyMap[keyVisibility];
    if (keyString != null) {
      try {
        final value = await keyStore.get(keyString);
        if (value?.data != null) {
          filteredKeys.add(keyString);
        }
      } on KeyNotFoundException {
        logger.warning('key $keyString not found');
      }
    }
    return filteredKeys;
  }

  Future<void> _handleDeleteOperation(
    HashMap<String, String?> verbParams,
    Response response,
  ) async {
    final keyNameFromParams = verbParams[AtConstants.keyName];
    response.data =
        (await keyStore.remove(keyNameFromParams, skipCommit: true)).toString();
  }

  /// List only keys from current enrollment. Do not list keys from another enrollment.
  /// Get the valueJson from keystore for [key].
  /// If the enrollment in valueJson matches [enrollIdFromMetadata], then add [key] to [filteredKeys]
  Future<void> _addKeyIfEnrollmentIdMatches(List<dynamic> filteredKeys,
      String key, String enrollIdFromMetadata) async {
    final value = await keyStore.get(key);
    if (value != null && value.data != null) {
      final valueJson = jsonDecode(value.data);
      if (valueJson[AtConstants.enrollmentId] == enrollIdFromMetadata) {
        filteredKeys.add(key);
      }
    }
  }

  /// Key structure varies based on visibility. Construct and return the key name based on [keyVisibility]
  /// Key name for public visibility - 'public:<keyname>.__public_keys.<namespace>@<atsign>'
  /// Key name for private visibility - 'private:<appName>.<deviceName>.<keyname>.__private_keys.<namespace>@<atsign>'
  /// Key name for self visibility  - '<appName>.<deviceName>.<keyname>.__self_keys.<namespace>@<atsign>'
  /// returns null, if [keyVisibility] is not public|private|self
  String? _getKeyName(HashMap<String, String?> verbParams, String atSign,
      String? keyVisibility) {
    if (keyVisibility == 'public') {
      return _getPublicKeyName(verbParams, atSign);
    } else if (keyVisibility == 'private') {
      return _getPrivateKeyName(verbParams, atSign);
    } else if (keyVisibility == 'self') {
      return _getSelfKeyName(verbParams, atSign);
    }
    return null;
  }

  String _getPublicKeyName(HashMap<String, String?> verbParams, String atSign) {
    return '${verbParams[AtConstants.visibility]}:${verbParams[AtConstants.keyName]}.__${verbParams[AtConstants.visibility]}_keys.${verbParams[AtConstants.namespace]}$atSign';
  }

  String _getPrivateKeyName(
      HashMap<String, String?> verbParams, String atSign) {
    return '${verbParams[AtConstants.visibility]}:${verbParams[AtConstants.appName]}.${verbParams[AtConstants.deviceName]}.${verbParams[AtConstants.keyName]}.__${verbParams[AtConstants.visibility]}_keys.${verbParams[AtConstants.namespace]}$atSign';
  }

  String _getSelfKeyName(HashMap<String, String?> verbParams, String atSign) {
    return '${verbParams[AtConstants.appName]}.${verbParams[AtConstants.deviceName]}.${verbParams[AtConstants.keyName]}.__${verbParams[AtConstants.visibility]}_keys.${verbParams[AtConstants.namespace]}$atSign';
  }
}
