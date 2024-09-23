import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_utils/at_logger.dart';

class EnrollmentManager {
  final SecondaryKeyStore _keyStore;

  final logger = AtSignLogger('AtSecondaryServer');

  EnrollmentManager(this._keyStore);

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

  String buildEnrollmentKey(String enrollmentId) {
    return '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace${AtSecondaryServerImpl.getInstance().currentAtSign}';
  }

  Future<void> put(String enrollmentId, AtData atData) async {
    String enrollmentKey = buildEnrollmentKey(enrollmentId);
    await _keyStore.put(enrollmentKey, atData, skipCommit: true);
  }
}
