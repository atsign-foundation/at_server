import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_secondary/src/enroll/enrollment_access.dart';

class KeysVerbHandler extends AbstractVerbHandler {
  static Keys keys = Keys();

  final EnrollmentManager enMgr;
  final Atsign atSign;
  KeysVerbHandler(super.keyStore, this.enMgr, this.atSign);

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

    try {
      EnrollDataStoreValue enrollDataStoreValue =
          await AtSecondaryServerImpl.getInstance()
              .enrollmentManager
              .getEnrollmentById(connectionMetadata.enrollmentId!);

      if (enrollDataStoreValue.approval?.state != 'approved') {
        throw AtEnrollmentException(
            'Enrollment Id $enrollIdFromMetadata is not approved. current state: ${enrollDataStoreValue.approval?.state}');
      }
      hasManageAccess = EnrollmentAccess.allowsWrite(enrollDataStoreValue
          .namespaces[EnrollmentConstants.enrollManageNamespace]);
    } on KeyNotFoundException {
      logger.severe(
          'Enrollment details not found for the enrollmentId: ${connectionMetadata.enrollmentId}');
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
        await _handleDeleteOperation(
            verbParams, response, enrollIdFromMetadata);
        break;
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
    if (keyNameFromParams != null && keyNameFromParams.isNotEmpty) {
      final AtData value;
      try {
        value = (await keyStore.get(keyNameFromParams))!;
      } on KeyNotFoundException {
        throw KeyNotFoundException(
            'key $keyNameFromParams not found in keystore');
      }
      if (!_isAuthorizedForKey(
          keyNameFromParams, value, enrollIdFromMetadata)) {
        throw UnAuthorizedException(
            'Enrollment $enrollIdFromMetadata is not authorized to access key'
            ' $keyNameFromParams');
      }
      response.data = value.data;
      return;
    }
    final filteredKeys = await _getFilteredKeys(
        keyVisibility, hasManageAccess, enrollIdFromMetadata);
    response.data = jsonEncode(filteredKeys);
  }

  /// The keys of visibility [keyVisibility] enrollment [enId] may see.
  Future<List<String>> _getFilteredKeys(
      String? keyVisibility, bool hasManageAccess, String enId) async {
    final List<String> result = keyVisibility != null &&
            keyVisibility.isNotEmpty
        ? hasManageAccess
            ? await (await keyStore.getKeys(
                    regex:
                        '.*$keyVisibility.*__global$atSign\$|.*$keyVisibility.*__manage$atSign\$'))
                .toList()
            : await (await keyStore.getKeys(
                    regex: '.*__${keyVisibility}_keys.__global$atSign\$'))
                .toList()
        : <String>[];

    final filteredKeys = <String>[];
    for (final key in result) {
      await _addKeyIfEnrollmentIdMatches(filteredKeys, key, enId);
    }

    final keyMap = {
      'private': enMgr.keyForPEK(enId),
      'self': enMgr.keyForSEK(enId),
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
    String enrollIdFromMetadata,
  ) async {
    final keyNameFromParams = verbParams[AtConstants.keyName]!;
    AtData? value;
    try {
      value = await keyStore.get(keyNameFromParams);
    } on KeyNotFoundException {
      value = null;
    }
    if (value == null) {
      throw KeyNotFoundException(
          'key $keyNameFromParams not found in keystore');
    }
    if (!_isAuthorizedForKey(keyNameFromParams, value, enrollIdFromMetadata)) {
      throw UnAuthorizedException(
          'Enrollment $enrollIdFromMetadata is not authorized to delete key'
          ' $keyNameFromParams');
    }
    response.data =
        (await keyStore.remove(keyNameFromParams, skipCommit: true)).toString();
  }

  /// Authorisation gate for the by-name `get` and `delete` branches: a caller
  /// may touch only keys tagged with its own [enId].
  bool _isAuthorizedForKey(String keyName, AtData value, String enId) {
    if (keyName == enMgr.keyForPEK(enId) || keyName == enMgr.keyForSEK(enId)) {
      return true;
    }
    final data = value.data;
    if (data == null) {
      return false;
    }
    try {
      final decoded = jsonDecode(data);
      return decoded is Map && decoded[AtConstants.enrollmentId] == enId;
    } catch (_) {
      return false;
    }
  }

  /// Adds [key] to [filteredKeys] only when its stored value is tagged with
  /// [enrollIdFromMetadata].
  Future<void> _addKeyIfEnrollmentIdMatches(List<dynamic> filteredKeys,
      String key, String enrollIdFromMetadata) async {
    final value = await keyStore.get(key);
    final data = value?.data;
    if (data != null) {
      final valueJson = jsonDecode(data);
      if (valueJson[AtConstants.enrollmentId] == enrollIdFromMetadata) {
        filteredKeys.add(key);
      }
    }
  }

  /// The stored key name for [keyVisibility], or null when it is not one of
  /// public, private or self.
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
