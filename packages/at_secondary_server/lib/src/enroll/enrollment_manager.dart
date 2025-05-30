import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_utils/at_logger.dart';

/// Manages enrollment data in the secondary server.
///
/// This class provides methods to retrieve and store enrollment data
/// associated with a given enrollment ID. It interacts with the
/// SecondaryKeyStore to persist and retrieve enrollment information.
class EnrollmentManager {
  final SecondaryKeyStore keyStore;
  final String atSign;
  final logger = AtSignLogger('AtSecondaryServer');

  /// Creates an instance of [EnrollmentManager].
  ///
  /// The [keyStore] is required to interact with the persistence layer.
  EnrollmentManager(this.keyStore, this.atSign);

  /// Retrieves the enrollment data for a given [enrollmentId].
  ///
  /// This method constructs an enrollment key, fetches the corresponding
  /// data from the key store, and returns it as an [EnrollDataStoreValue].
  /// If the key is not found, a [KeyNotFoundException] is thrown.
  ///
  /// If the retrieved enrollment data is no longer active, the status
  /// will be set to `expired`.
  ///
  /// Returns:
  ///   An [EnrollDataStoreValue] containing the enrollment details.
  ///
  /// Throws:
  ///   [KeyNotFoundException] if the enrollment key does not exist.
  Future<EnrollDataStoreValue> getEnrollmentById(String enrollmentId) async {
    return getEnrollmentByFullKey(buildEnrollmentKey(enrollmentId));
  }

  /// Constructs the enrollment key based on the provided [enrollmentId].
  ///
  /// The key format combines the [enrollmentId], a new enrollment key pattern,
  /// and the current AtSign.
  ///
  /// Returns:
  ///   A [String] representing the enrollment key.
  String buildEnrollmentKey(String enrollmentId) {
    return '$enrollmentId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$atSign';
  }

  /// Stores the enrollment data associated with the given [enrollmentId].
  ///
  /// This method constructs an enrollment key and saves the provided [AtData]
  /// to the key store. The skipCommit is set to true, to prevent the enrollment
  /// data being synced to the client(s).
  ///
  /// Parameters:
  ///   - [enrollmentId]: The ID associated with the enrollment.
  ///   - [atData]: The [AtData] object to be stored.
  Future<void> put(String enrollmentId, AtData atData) async {
    String enrollmentKey = buildEnrollmentKey(enrollmentId);
    await keyStore.put(enrollmentKey, atData, skipCommit: true);
  }

  /// Deletes the enrollment key from the keystore.
  ///
  /// This method generates an enrollment key using the provided enrollmentId and
  /// removes the enrollment key from the keystore. The skipCommit parameter is
  /// set to true to prevent this deletion from being logged in the commit log,
  /// ensuring it is not synced to the clients.
  ///
  /// Parameters:
  ///  - [enrollmentId]: The ID associated with the enrollment.
  Future<void> remove({
    required String enrollmentId,
    EnrollDataStoreValue? enrollValue,
  }) async {
    // Delete private encryption key
    await keyStore.remove(
        '$enrollmentId.${AtConstants.defaultEncryptionPrivateKey}.${EnrollmentConstants.enrollManageNamespace}$atSign',
        skipCommit: true);

    // Delete self encryption key
    await keyStore.remove(
        '$enrollmentId.${AtConstants.defaultSelfEncryptionKey}.${EnrollmentConstants.enrollManageNamespace}$atSign',
        skipCommit: true);

    enrollValue ??= await getEnrollmentById(enrollmentId);
    // Delete the APKAM Public key, legacy slightly info-leaky format
    var apkamPublicKeyInKeyStore =
        'public:${enrollValue.appName}.${enrollValue.deviceName}.pkam.${EnrollmentConstants.pkamNamespace}.__public_keys$atSign';
    await keyStore.remove(apkamPublicKeyInKeyStore, skipCommit: true);

    String enrollmentKey = buildEnrollmentKey(enrollmentId);
    await keyStore.remove(enrollmentKey, skipCommit: true);
  }

  Future<List<String>> getAllEnrollmentKeys() async {
    return keyStore.getKeys(regex: EnrollmentConstants.enrollmentsRegex)
        as List<String>;
  }

  /// Fetch an enrollment key from the keystore.
  /// If key is available returns [EnrollDataStoreValue],
  /// else throws [KeyNotFoundException]
  Future<EnrollDataStoreValue> getEnrollmentByFullKey(
    String enrollmentKey,
  ) async {
    try {
      AtData enrollData = await keyStore.get(enrollmentKey);
      EnrollDataStoreValue enrollDataStoreValue =
          EnrollDataStoreValue.fromJson(jsonDecode(enrollData.data!));
      if (!SecondaryUtil.isActiveKey(enrollData)) {
        // TODO Whenever an expired enrollment is encountered, delete it immediately
        enrollDataStoreValue.approval?.state = EnrollmentStatus.expired.name;
      }
      return enrollDataStoreValue;
    } on KeyNotFoundException {
      logger.severe('$enrollmentKey does not exist in the keystore');
      rethrow;
    }
  }

  Future<Map<String, Map<String, dynamic>>> getEnrollmentsAsJson(
      {List<String>? enrollmentKeysList,
      List<EnrollmentStatus>? enrollmentStatusFilter}) async {
    // set default values for optional arguments - all enrollments, all statuses
    enrollmentKeysList ??= await getAllEnrollmentKeys();
    enrollmentStatusFilter ??= EnrollmentStatus.values;

    Map<String, Map<String, dynamic>> enrollments = {};
    for (var enrollmentKey in enrollmentKeysList) {
      EnrollDataStoreValue enrollDataStoreValue =
          await getEnrollmentByFullKey(enrollmentKey);
      EnrollmentStatus enrollmentStatus =
          getEnrollStatusFromString(enrollDataStoreValue.approval!.state);
      if (enrollmentStatusFilter.contains(enrollmentStatus)) {
        enrollments[enrollmentKey] = enrollDataStoreValue.toJsonExtended();
      }
    }
    return enrollments;
  }

  /// Delete expired enrollments to keep the datastore clean.
  /// Called upon server startup and periodically thereafter.
  Future<List<EnrollDataStoreValue>> removeAllExpiredEnrollments() async {
    final List<EnrollDataStoreValue> expiredSoDeleted = [];
    final l = await getAllEnrollmentKeys();
    for (final ek in l) {
      final EnrollDataStoreValue ev = await getEnrollmentByFullKey(ek);
      if (ev.approval?.state == EnrollmentStatus.expired.name) {
        final eId = ek.substring(0, ek.indexOf('.'));
        await remove(enrollmentId: eId, enrollValue: ev);
        expiredSoDeleted.add(ev);
      }
    }
    return expiredSoDeleted;
  }

  /// iterate all enrollments, remove key which leaks appName and deviceName
  /// `public:${enrollDataStoreValue.appName}.${enrollDataStoreValue.deviceName}.pkam.${EnrollmentConstants.pkamNamespace}.__public_keys$currentAtSign`
  Future<List<String>> removeLegacyApkamPublicKeys() async {
    final List<String> deletedLegacyKeys = [];
    final l = await getAllEnrollmentKeys();
    for (final ek in l) {
      final EnrollDataStoreValue ev = await getEnrollmentByFullKey(ek);
      final lk = 'public:${ev.appName}.${ev.deviceName}'
          '.pkam.${EnrollmentConstants.pkamNamespace}'
          '.__public_keys$atSign';
      if (keyStore.isKeyExists(lk)) {
        await keyStore.remove(lk, skipCommit: true);
        deletedLegacyKeys.add(ek);
      }
    }
    return deletedLegacyKeys;
  }
}
