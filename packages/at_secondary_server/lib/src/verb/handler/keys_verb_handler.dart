import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

/// Handles `keys:`, which answers only an enrollment's own two encryption
/// keys: `keys:get:keyName:<enrollmentId>.default_enc_private_key.__manage@<atSign>`
/// and `keys:get:keyName:<enrollmentId>.default_self_enc_key.__manage@<atSign>`,
/// on a connection authenticated as that enrollment.
///
/// Every other `keys:` request is refused with [UnAuthorizedException]
/// before the store is read or written.
class KeysVerbHandler extends AbstractVerbHandler {
  static Keys keys = Keys();

  final EnrollmentManager enMgr;
  final Atsign atSign;
  KeysVerbHandler(super.keyStore, this.enMgr, this.atSign);

  /// The request fields a `keys:get` of one of the two keys may not carry.
  static const List<String> _fieldsBesideKeyName = [
    AtConstants.visibility,
    AtConstants.namespace,
    AtConstants.appName,
    AtConstants.deviceName,
    AtConstants.keyType,
    AtConstants.encryptionKeyName,
    AtConstants.keyValue,
  ];

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
    final connectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    final String? enrollmentId = connectionMetadata.enrollmentId;
    if (enrollmentId == null) {
      throw AtEnrollmentException(
          'Keys verb cannot be accessed without an enrollmentId');
    }
    final String? keyName = _ownEncryptionKeyAskedFor(verbParams, enrollmentId);
    if (keyName == null) {
      throw UnAuthorizedException('keys: answers only keys:get:keyName: of '
          'enrollment $enrollmentId\'s own default_enc_private_key or '
          'default_self_enc_key');
    }

    try {
      final EnrollDataStoreValue enrollment =
          await AtSecondaryServerImpl.getInstance()
              .enrollmentManager
              .getEnrollmentById(enrollmentId);
      if (enrollment.approval?.state != EnrollmentStatus.approved.name) {
        throw AtEnrollmentException('Enrollment Id $enrollmentId is not '
            'approved. current state: ${enrollment.approval?.state}');
      }
    } on KeyNotFoundException {
      logger.severe('Enrollment details not found for the enrollmentId: '
          '$enrollmentId');
    }

    final AtData? value;
    try {
      value = await keyStore.get(keyName);
    } on KeyNotFoundException {
      throw KeyNotFoundException('key $keyName not found in keystore');
    }
    response.data = value?.data;
  }

  /// The stored name of the key [verbParams] asks for when the request is a
  /// `keys:get` by keyName alone of [enrollmentId]'s own encryption private
  /// key or self encryption key; null for every other request.
  String? _ownEncryptionKeyAskedFor(
      HashMap<String, String?> verbParams, String enrollmentId) {
    if (verbParams[AtConstants.operation] != 'get') return null;
    for (final String field in _fieldsBesideKeyName) {
      final String? given = verbParams[field];
      if (given != null && given.isNotEmpty) return null;
    }
    final String? keyName = verbParams[AtConstants.keyName];
    if (keyName == null) return null;
    final String folded = canonicalAtKey(keyName);
    for (final String own in [
      enMgr.keyForPEK(enrollmentId),
      enMgr.keyForSEK(enrollmentId),
    ]) {
      if (folded == own) return own;
    }
    return null;
  }
}
