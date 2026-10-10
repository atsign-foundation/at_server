import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// Scenarios: features/enrollment/expired_enrollment_data.feature
void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  final etu = ETU();
  setUp(() async {
    await verbTestsSetUp();
    await etu.init();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  String at(String key, String location) => key.replaceFirst(
      '${EnrollmentConstants.perEnrollmentApproved}@', '$location@');

  Future<void> expectMovedTo(
      String location, List<String> keys, List<String> values) async {
    for (int i = 0; i < keys.length; i++) {
      expect(await keyValueStore.exists(keys[i]), false, reason: keys[i]);
      expect((await keyValueStore.get(at(keys[i], location)))?.data, values[i],
          reason: at(keys[i], location));
    }
  }

  group('removing an enrollment', () {
    test('moves its data to d.__e and commits nothing for it', () async {
      const int ttl = 150;
      final String enId =
          (await etu.createEnrollments(n: 1, m: 1, ttl: ttl)).$1.first;
      final (keys, values) = await etu.createSomePerEnrollmentData(enId);
      await Future.delayed(const Duration(milliseconds: ttl + 1));

      await keyValueStore.deleteExpiredKeys();

      await expectMovedTo(EnrollmentConstants.perEnrollmentDeleted, keys, values);
      for (final String key in keys) {
        expect(atCommitLog.getLatestCommitEntry(key), isNull, reason: key);
        expect(
            atCommitLog.getLatestCommitEntry(
                at(key, EnrollmentConstants.perEnrollmentDeleted)),
            isNull,
            reason: 'no client of a removed enrollment syncs again');
      }
    });

    test('by the sweep and by a delete at once moves its data once', () async {
      const int ttl = 150;
      final String enId =
          (await etu.createEnrollments(n: 1, m: 1, ttl: ttl)).$1.first;
      final (keys, values) = await etu.createSomePerEnrollmentData(enId);
      await Future.delayed(const Duration(milliseconds: ttl + 1));

      await Future.wait([
        keyValueStore.deleteExpiredKeys(),
        enMgr.serialiseMutation(() => enMgr.remove(enId: enId)),
      ]);

      await expectMovedTo(EnrollmentConstants.perEnrollmentDeleted, keys, values);
      expect(await keyValueStore.exists(enMgr.buildEnrollmentKey(enId)), false);
    });
  });

  test('revoking an enrollment still commits the move to r.__e', () async {
    final String enId = (await etu.createEnrollments(n: 1)).$1.first;
    final (keys, values) = await etu.createSomePerEnrollmentData(enId);

    await etu.revokeEnrollment(etu.primaryEnId, enId);

    await expectMovedTo(EnrollmentConstants.perEnrollmentRevoked, keys, values);
    for (final String key in keys) {
      expect(atCommitLog.getLatestCommitEntry(key)?.operation, CommitOp.DELETE,
          reason: key);
      expect(
          atCommitLog.getLatestCommitEntry(
              at(key, EnrollmentConstants.perEnrollmentRevoked)),
          isNotNull,
          reason: 'an unrevoked enrollment syncs its data again');
    }
  });
}
