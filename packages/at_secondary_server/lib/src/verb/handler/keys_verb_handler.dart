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
      hasManageAccess = enrollDataStoreValue
              .namespaces[EnrollmentConstants.enrollManageNamespace] ==
          'rw';
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
        await _handleDeleteOperation(verbParams, response, enrollIdFromMetadata);
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
      if (!_isAuthorizedForKey(keyNameFromParams, value, enrollIdFromMetadata)) {
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

  /// If current enrollment has __manage access then return both __global and __manage keys with visibility [keyVisibility]
  /// Otherwise return only __global keys with visibility [keyVisibility]
  /// Also return the encrypted default encryption private key and encrypted self encryption key for enrollmentId [enId]
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
      throw KeyNotFoundException('key $keyNameFromParams not found in keystore');
    }
    if (!_isAuthorizedForKey(keyNameFromParams, value, enrollIdFromMetadata)) {
      throw UnAuthorizedException(
          'Enrollment $enrollIdFromMetadata is not authorized to delete key'
          ' $keyNameFromParams');
    }
    response.data =
        (await keyStore.remove(keyNameFromParams, skipCommit: true)).toString();
  }

  /// Authorization gate for the by-name `get`/`delete` branches.
  ///
  /// Mirrors the filtered-list branch ([_addKeyIfEnrollmentIdMatches]): a
  /// caller may only touch keys tagged with its own [enId], plus its own
  /// default-encryption-private-key and self-encryption-key. Any other key —
  /// including keys belonging to another enrollment and reserved server
  /// secrets such as `privatekey:at_secret` (which are not keys-verb-managed
  /// JSON values) — is refused.
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
      // Not a keys-verb-managed value (e.g. a raw server secret) -> refuse.
      return false;
    }
  }

  /// List only keys from current enrollment. Do not list keys from another enrollment.
  /// Get the valueJson from keystore for [key].
  /// If the enrollment in valueJson matches [enrollIdFromMetadata], then add [key] to [filteredKeys]
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

  /// Key structure varies based on visibility. Construct and return the key name based on [keyVisibility]
  /// Key name for public visibility - `'public:<keyname>.__public_keys.<namespace>@<atsign>'`
  /// Key name for private visibility - `'private:<appName>.<deviceName>.<keyname>.__private_keys.<namespace>@<atsign>'`
  /// Key name for self visibility  - `'<appName>.<deviceName>.<keyname>.__self_keys.<namespace>@<atsign>'`
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
