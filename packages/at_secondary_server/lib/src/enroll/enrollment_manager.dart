import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';

/// Manages enrollment data in the secondary server.
///
/// This class provides methods to retrieve and store enrollment data
/// associated with a given enrollment ID. It interacts with the
/// SecondaryKeyStore to persist and retrieve enrollment information.
class EnrollmentManager {
  final SecondaryKeyStore<String, AtData?, AtMetaData?> keyStore;
  final String atSign;

  /// log messages here are important, so hard-coding level to 'info'
  final AtSignLogger logger = AtSignLogger('EnrollmentManager')..level = 'info';

  /// Creates an instance of [EnrollmentManager].
  ///
  /// The [keyStore] is required to interact with the persistence layer.
  EnrollmentManager(this.keyStore, this.atSign);

  /// Retrieves the enrollment data for a given [enId].
  ///
  /// This method constructs an enrollment key, fetches the corresponding
  /// data from the key store, and returns it as an [EnrollDataStoreValue].
  /// If the key is not found, a [KeyNotFoundException] is thrown.
  ///
  /// If the retrieved enrollment data is no longer active, the status
  /// will be set to `expired`.
  ///
  /// If an enrollment has expired then, while the data is returned to the
  /// caller, we also [remove] the enrollment.
  /// Returns:
  ///   An [EnrollDataStoreValue] containing the enrollment details.
  ///
  /// Throws:
  ///   [KeyNotFoundException] if the enrollment key does not exist or has expired.
  Future<EnrollDataStoreValue> getEnrollmentById(String enId) async {
    return getEnrollmentByFullKey(buildEnrollmentKey(enId));
  }

  /// Constructs the enrollment key based on the provided [enId].
  ///
  /// The key format combines the [enId], a new enrollment key pattern,
  /// and the current AtSign.
  ///
  /// Returns:
  ///   A [String] representing the enrollment key.
  String buildEnrollmentKey(String enId) {
    return '$enId'
        '.${EnrollmentConstants.enrollmentKeyPattern}'
        '.${EnrollmentConstants.enrollManageNamespace}'
        '$atSign';
  }

  /// Stores the enrollment data associated with the given [enId].
  ///
  /// This method constructs an enrollment key and saves the provided [AtData]
  /// to the key store. The skipCommit is set to true, to prevent the enrollment
  /// data being synced to the client(s).
  ///
  /// Parameters:
  ///   - [enId]: The ID associated with the enrollment.
  ///   - [atData]: The [AtData] object to be stored.
  Future<void> put(
      String enId, AtData atData, EnrollmentStatus newStatus) async {
    String ek = buildEnrollmentKey(enId);

    switch (newStatus) {
      case EnrollmentStatus.approved:
        await movePerEnrollmentData(enId,
            to: EnrollmentConstants.perEnrollmentApproved);
        break;
      case EnrollmentStatus.revoked:
        await movePerEnrollmentData(enId,
            to: EnrollmentConstants.perEnrollmentRevoked);
        break;
      default:
        break;
    }

    await keyStore.put(ek, atData, skipCommit: true);
  }

  RegExp reForPerEnrollmentNamespaces =
      RegExp(EnrollmentConstants.regexForPerEnrollmentNamespaces);

  /// Moves everything in `<enId>.[ard].__e` to the required place
  /// Returns list of all the keys which were moved
  @visibleForTesting
  Future<List<String>> movePerEnrollmentData(
    String enId, {
    required String to,
  }) async {
    switch (to) {
      case EnrollmentConstants.perEnrollmentRevoked:
      case EnrollmentConstants.perEnrollmentDeleted:
      case EnrollmentConstants.perEnrollmentApproved:
        List<String> moved = [];
        for (final String fromKey in keyStore.getKeys(
            regex: EnrollmentConstants.regexForPerEnrollmentNamespaces)) {
          final String toKey = fromKey
              .replaceAll(
                  '${EnrollmentConstants.perEnrollmentRevoked}@', '$to@')
              .replaceAll(
                  '${EnrollmentConstants.perEnrollmentDeleted}@', '$to@')
              .replaceAll(
                  '${EnrollmentConstants.perEnrollmentApproved}@', '$to@');
          if (toKey == fromKey) {
            continue;
          }

          AtData data = (await keyStore.get(fromKey))!;
          await keyStore.put(toKey, data, skipCommit: false);
          await keyStore.remove(fromKey);
          moved.add(fromKey);
        }
        return moved;
      default:
        throw ArgumentError('movePerEnrollmentData: Invalid "to": "$to"');
    }
  }

  String keyForPEK(String enId) => '$enId'
      '.${AtConstants.defaultEncryptionPrivateKey}'
      '.${EnrollmentConstants.enrollManageNamespace}'
      '$atSign';

  String keyForSEK(String enId) => '$enId'
      '.${AtConstants.defaultSelfEncryptionKey}'
      '.${EnrollmentConstants.enrollManageNamespace}'
      '$atSign';

  /// ```
  /// public:${enVal.appName}.${enVal.deviceName}
  ///   .pkam.${EnrollmentConstants.pkamNamespace}
  ///   .__public_keys$currentAtSign
  /// ```
  String keyForLegacyPK(EnrollDataStoreValue enVal) => 'public:'
      '${enVal.appName}.${enVal.deviceName}'
      '.pkam.${EnrollmentConstants.pkamNamespace}'
      '.__public_keys$atSign';

  final RegExp ekRegex = RegExp(EnrollmentConstants.regexForEnrollmentKey);

  /// Called before *any* key in the keystore is removed.
  /// Checks if what's being removed is an enrollment and, if so,
  /// moves all per-enrollment data to [perEnrollmentDeleted]
  Future preRemoveHook(String key, {required bool skipCommit}) async {
    if (ekRegex.hasMatch(key)) {
      await _preRemove(ek: key);
    }
  }

  Future<void> _preRemove({
    required String ek,
  }) async {
    if (!keyStore.isKeyExists(ek)) {
      logger.info('_preRemove: $ek no longer exists, nothing to do');
      return;
    }

    logger.info('_preRemove($ek)');

    String enId = getIdFromKey(ek);

    // Delete private encryption key if it's there
    final pekKey = keyForPEK(enId);
    if (keyStore.isKeyExists(pekKey)) {
      logger.info('_preRemove: Removing $pekKey');
      await keyStore.remove(pekKey, skipCommit: true);
    } else {
      logger.info('_preRemove: $pekKey has already been removed');
    }

    // Delete self encryption key if it's there
    final sekKey = keyForSEK(enId);
    if (keyStore.isKeyExists(sekKey)) {
      logger.info('_preRemove: Removing $sekKey');
      await keyStore.remove(sekKey, skipCommit: true);
    } else {
      logger.info('_preRemove: $sekKey has already been removed');
    }

    await movePerEnrollmentData(enId,
        to: EnrollmentConstants.perEnrollmentDeleted);
  }

  /// Deletes the enrollment key from the keystore.
  ///
  /// This method generates an enrollment key using the provided enrollmentId and
  /// removes the enrollment key from the keystore. The skipCommit parameter is
  /// set to true to prevent this deletion from being logged in the commit log,
  /// ensuring it is not synced to the clients.
  ///
  /// Parameters:
  ///  - [enId]: The ID associated with the enrollment.
  Future<void> remove({required String enId}) async {
    if (!keyStore.preRemoveHooks.contains(preRemoveHook)) {
      throw StateError('Managing datastore consistency for enrollments requires'
          ' that the preRemoveHook be active');
    }
    String ek = buildEnrollmentKey(enId);

    await keyStore.remove(ek, skipCommit: true);
  }

  Future<List<String>> getAllEnrollmentKeys() async {
    return keyStore.getKeys(regex: EnrollmentConstants.enrollmentsRegex);
  }

  /// Fetch an enrollment key from the keystore.
  /// If key is available returns [EnrollDataStoreValue],
  /// else throws [KeyNotFoundException]
  Future<EnrollDataStoreValue> getEnrollmentByFullKey(
    String ek,
  ) async {
    AtData enrollData = (await keyStore.get(ek))!;
    EnrollDataStoreValue value =
        EnrollDataStoreValue.fromJson(jsonDecode(enrollData.data!));
    if (!SecondaryUtil.isActiveKey(enrollData)) {
      // When an expired enrollment is encountered, delete it immediately
      logger.warning('getEnrollmentByFullKey:'
          ' Enrollment $ek has expired - removing it');
      await remove(enId: getIdFromKey(ek));

      value.approval = EnrollApproval(EnrollmentStatus.expired.name);
    }
    return value;
  }

  /// Fetch enrollments whose keys are in the [ekList], and filter them to
  /// enrollments whose status is in the [statuses] list.
  ///
  /// When [ekList] is null, fetch and filter all enrollments.
  /// When [statuses] is null, do not filter by status.
  Future<Map<String, Map<String, dynamic>>> getEnrollmentsAsJson(
      {List<String>? ekList, List<EnrollmentStatus>? statuses}) async {
    // set default values for optional arguments - all enrollments, all statuses
    ekList ??= await getAllEnrollmentKeys();

    Map<String, Map<String, dynamic>> ejList = {};
    for (var ek in ekList) {
      EnrollDataStoreValue enVal = await getEnrollmentByFullKey(ek);
      if (statuses == null ||
          statuses.contains(
              EnrollmentStatus.values.byName(enVal.approval!.state))) {
        ejList[ek] = enVal.toJsonExtended();
      }
    }
    return ejList;
  }

  /// iterate all enrollments, remove key which leaks appName and deviceName
  Future<List<String>> removeLegacyApkamPublicKeys() async {
    final List<String> deletedLegacyKeys = [];
    final eks = await getAllEnrollmentKeys();
    for (final ek in eks) {
      final EnrollDataStoreValue ev = await getEnrollmentByFullKey(ek);
      final lk = keyForLegacyPK(ev);
      if (keyStore.isKeyExists(lk)) {
        logger.warning('removeLegacyApkamPublicKeys: DELETING $lk');
        await keyStore.remove(lk, skipCommit: true);
        deletedLegacyKeys.add(ek);
      }
    }
    return deletedLegacyKeys;
  }

  /// Called upon server startup. Removes encryption keys of enrollments which
  /// no longer exist (expired or otherwise). Previously these encryption keys
  /// were stored without a ttl even if there was a valid ttl, therefore they
  /// would never be harvested.
  Future<List<String>> removeOrphanedApkamEncryptionKeys() async {
    final List<String> deletedOrphanedKeys = [];
    final List<String> enIds = [];
    for (final ek in await getAllEnrollmentKeys()) {
      enIds.add(getIdFromKey(ek));
    }
    final List<String> candidates = [];
    candidates.addAll(keyStore.getKeys(regex: EnrollmentConstants.regexForPEK));
    candidates.addAll(keyStore.getKeys(regex: EnrollmentConstants.regexForSEK));
    for (final candidateKey in candidates) {
      String candidateId = getIdFromKey(candidateKey);
      if (!enIds.contains(candidateId)) {
        logger.warning('DELETING orphaned key $candidateKey');
        deletedOrphanedKeys.add(candidateKey);
        await keyStore.remove(candidateKey, skipCommit: true);
      } else {
        logger.info('NOT deleting $candidateKey - not orphaned');
      }
    }
    return deletedOrphanedKeys;
  }

  /// Get the enrollmentId from any key where enrollmentId is the first part
  String getIdFromKey(String ek) => ek.substring(0, ek.indexOf('.'));
}
