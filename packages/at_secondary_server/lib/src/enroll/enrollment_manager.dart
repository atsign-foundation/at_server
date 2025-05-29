import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_utils/at_logger.dart';

/// Manages enrollment data in the secondary server.
///
/// This class provides methods to retrieve and store enrollment data
/// associated with a given enrollment ID. It interacts with the
/// SecondaryKeyStore to persist and retrieve enrollment information.
class EnrollmentManager {
  final SecondaryKeyStore _keyStore;

  final logger = AtSignLogger('AtSecondaryServer');

  /// Creates an instance of [EnrollmentManager].
  ///
  /// The [keyStore] is required to interact with the persistence layer.
  EnrollmentManager(this._keyStore);

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
  Future<EnrollDataStoreValue> get(String enrollmentId) async {
    String enrollmentKey = buildEnrollmentKey(enrollmentId);
    try {
      AtData enrollData = await _keyStore.get(enrollmentKey);
      EnrollDataStoreValue enrollDataStoreValue =
          EnrollDataStoreValue.fromJson(jsonDecode(enrollData.data!));

      if (!SecondaryUtil.isActiveKey(enrollData)) {
        enrollDataStoreValue.approval?.state = EnrollmentStatus.expired.name;
      }

      return enrollDataStoreValue;
    } on KeyNotFoundException {
      logger.severe('$enrollmentKey does not exist in the keystore');
      rethrow;
    }
  }

  /// Constructs the enrollment key based on the provided [enrollmentId].
  ///
  /// The key format combines the [enrollmentId], a new enrollment key pattern,
  /// and the current AtSign.
  ///
  /// Returns:
  ///   A [String] representing the enrollment key.
  String buildEnrollmentKey(String enrollmentId) {
    return '$enrollmentId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}${AtSecondaryServerImpl.getInstance().currentAtSign}';
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
    await _keyStore.put(enrollmentKey, atData, skipCommit: true);
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
  Future<void> remove(String enrollmentId) async {
    String enrollmentKey = buildEnrollmentKey(enrollmentId);
    await _keyStore.remove(enrollmentKey, skipCommit: true);
  }

  Future<List<String>> getAllEnrollmentKeys() async {
    return _keyStore.getKeys(regex: EnrollmentConstants.enrollmentsRegex)
        as List<String>;
  }

  /// Fetch an enrollment by enrollment ID
  /// - Constructs key using [buildEnrollmentKey]
  /// - Calls [getEnrollDataStoreValue]
  Future<EnrollDataStoreValue> getEnrollDataStoreValueById(
    String enrollmentId,
  ) async {
    return getEnrollDataStoreValue(buildEnrollmentKey(enrollmentId));
  }

  /// Fetch an enrollment key from the keystore.
  /// If key is available returns [EnrollDataStoreValue],
  /// else throws [KeyNotFoundException]
  Future<EnrollDataStoreValue> getEnrollDataStoreValue(
    String enrollmentKey,
  ) async {
    try {
      AtData enrollData = await _keyStore.get(enrollmentKey);
      EnrollDataStoreValue enrollDataStoreValue =
          EnrollDataStoreValue.fromJson(jsonDecode(enrollData.data!));
      if (!SecondaryUtil.isActiveKey(enrollData)) {
        enrollDataStoreValue.approval?.state = EnrollmentStatus.expired.name;
      }
      return enrollDataStoreValue;
    } on KeyNotFoundException {
      logger.severe('$enrollmentKey does not exist in the keystore');
      rethrow;
    }
  }

  Future<Map<String, Map<String, dynamic>>> fetchEnrollments(
      {List<String>? enrollmentKeysList,
      List<EnrollmentStatus>? enrollmentStatusFilter}) async {
    enrollmentKeysList ??= await getAllEnrollmentKeys();
    Map<String, Map<String, dynamic>> enrollments = {};
    enrollmentStatusFilter ??= EnrollmentStatus.values;
    for (var enrollmentKey in enrollmentKeysList) {
      EnrollDataStoreValue enrollDataStoreValue =
          await getEnrollDataStoreValue(enrollmentKey);
      EnrollmentStatus enrollmentStatus =
          getEnrollStatusFromString(enrollDataStoreValue.approval!.state);
      if (enrollmentStatusFilter.contains(enrollmentStatus)) {
        enrollments[enrollmentKey] = {
          'appName': enrollDataStoreValue.appName,
          'deviceName': enrollDataStoreValue.deviceName,
          'namespace': enrollDataStoreValue.namespaces,
          'encryptedAPKAMSymmetricKey':
              enrollDataStoreValue.encryptedAPKAMSymmetricKey,
          'status': enrollDataStoreValue.approval?.state
        };
      }
    }
    return enrollments;
  }

  /// Delete expired enrollments to keep the datastore clean.
  /// Called upon server startup and periodically thereafter.
  Future<List<EnrollDataStoreValue>> deleteAllExpiredEnrollments() async {
    // TODO move the list stuff to a list method in this class, and use it here
    return [];
  }

  /// iterate all enrollments, remove key which leaks appName and deviceName
  /// `public:${enrollDataStoreValue.appName}.${enrollDataStoreValue.deviceName}.pkam.${EnrollmentConstants.pkamNamespace}.__public_keys$currentAtSign`
  Future<List<String>> deleteLegacyApkamPublicKeys() async {
    return [];
  }

// TODO Move code here from EnrollVerbHandler re deleting an enrollment
// TODO When an enrollment is revoked, move stuff from .a to .r
// TODO Unrevoke: move stuff from .r to .a
// TODO Delete: move stuff from .a and/or .r to .d
// TODO Whenever an expired enrollment is encountered, delete it immediately
}
