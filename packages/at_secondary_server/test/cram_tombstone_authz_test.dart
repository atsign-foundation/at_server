import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// The `privatekey:at_secret_deleted` marker is what stops the CRAM secret
/// being replanted on a later start, so planting it is an irreversible act:
/// [AtSecondaryServerImpl.plantCramSecretIfRequired] refuses forever once it
/// exists. Once the flat PKAM credential is retired, CRAM is the last
/// recovery route an atSign has, which makes "who can plant this marker, and
/// when" an authorisation question rather than bookkeeping.
///
/// The marker used to be written at the top of the delete handler, before the
/// authorisation check and before the removal was attempted. Any connection
/// that reached the handler at all could therefore plant it — and did so even
/// when its delete was refused, and even on an atSign that had no CRAM secret
/// to delete.
///
/// These pin the marker to the deletion it is supposed to record.
void main() {
  AtSignLogger.root_level = 'WARNING';

  group('the CRAM-secret tombstone records a deletion that happened', () {
    late DeleteVerbHandler deleteVerbHandler;

    setUpAll(() async => await verbTestsSetUpAll());

    setUp(() async {
      await verbTestsSetUp();
      deleteVerbHandler = DeleteVerbHandler(
          keyValueStore, statsNotificationService, notificationManager);
    });

    tearDown(() async => await verbTestsTearDown());

    /// Binds an approved enrollment holding exactly [namespaces].
    Future<String> bindEnrollment(Map<String, String> namespaces) async {
      inboundConnection.metadata.isAuthenticated = true;
      final enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      await keyValueStore.put(
          '$enrollId.new.enrollments.__manage$alice',
          AtData()
            ..data = jsonEncode({
              'sessionId': '123',
              'appName': 'wavi',
              'deviceName': 'pixel',
              'namespaces': namespaces,
              'apkamPublicKey': 'testPublicKeyValue',
              'requestType': 'newEnrollment',
              'approval': {'state': 'approved'}
            }));
      return enrollId;
    }

    Future<void> seedSecret() async => await keyValueStore.put(
        AtConstants.atCramSecret, AtData()..data = 'the-activation-secret');

    test('an enrollment refused the delete does NOT plant the marker',
        () async {
      await seedSecret();
      // Nothing but an ordinary namespace: not root, no __manage, no '*'.
      await bindEnrollment({'wavi': 'rw'});

      await expectLater(
          () => deleteVerbHandler.processInternal(
              'delete:${AtConstants.atCramSecret}', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'a scoped enrollment may not delete the CRAM secret');

      expect(await keyValueStore.exists(AtConstants.atCramSecretDeleted),
          isFalse,
          reason: 'and having been refused, it must not have disabled CRAM '
              'replanting either — the marker is irreversible, so a caller '
              'who cannot delete the secret must not be able to close the '
              'atSign\'s last recovery route on the way out');
      expect((await keyValueStore.get(AtConstants.atCramSecret))?.data,
          'the-activation-secret',
          reason: 'the secret itself survives the refusal');
    });

    test('a delete that finds no secret does NOT plant the marker', () async {
      // No seedSecret(): this atSign never had one.
      inboundConnection.metadata
        ..isAuthenticated = true
        ..enrollmentId = null;

      // Removing a key the store does not hold is not an error: it returns a
      // commit id of -1. So nothing about the command's OUTCOME distinguishes
      // this from a real deletion — the handler has to have looked.
      final response = await deleteVerbHandler.processInternal(
          'delete:${AtConstants.atCramSecret}', inboundConnection);
      expect(response.isError, isFalse,
          reason: 'deleting an absent key succeeds; this is the case that '
              'makes the assertion below load-bearing rather than obvious');

      expect(await keyValueStore.exists(AtConstants.atCramSecretDeleted),
          isFalse,
          reason: 'a deletion that did not happen leaves no tombstone — '
              'otherwise one refused command permanently disables CRAM on an '
              'atSign that was never activated');
    });

    test('an owner connection that DOES delete the secret plants the marker',
        () async {
      await seedSecret();
      // No enrollment id: the owner/CRAM shape.
      inboundConnection.metadata
        ..isAuthenticated = true
        ..enrollmentId = null;

      await deleteVerbHandler.processInternal(
          'delete:${AtConstants.atCramSecret}', inboundConnection);

      expect(await keyValueStore.exists(AtConstants.atCramSecret), isFalse,
          reason: 'the secret is gone');
      expect((await keyValueStore.get(AtConstants.atCramSecretDeleted))?.data,
          'true',
          reason: 'and the deletion is recorded, so a later start does not '
              'replant what an owner deliberately destroyed');
    });

    test('the marker keeps a later start from replanting', () async {
      // The property the marker exists for, asserted end to end against the
      // startup guard rather than inferred from the marker's presence.
      await seedSecret();
      inboundConnection.metadata
        ..isAuthenticated = true
        ..enrollmentId = null;
      await deleteVerbHandler.processInternal(
          'delete:${AtConstants.atCramSecret}', inboundConnection);

      await AtSecondaryServerImpl.getInstance()
          .plantCramSecretIfRequired(keyValueStore, 'a-freshly-supplied-secret');

      expect(await keyValueStore.exists(AtConstants.atCramSecret), isFalse,
          reason: 'a restart with -s must not resurrect a secret the owner '
              'deleted');
    });
  });
}
