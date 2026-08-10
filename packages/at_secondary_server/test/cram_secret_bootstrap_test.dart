import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Covers [AtSecondaryServerImpl.plantCramSecretIfRequired] — the startup
/// guard that decides whether to write `privatekey:at_secret`. This is the
/// server-side half of the CRAM-resurrection fix (the CRAM verb handler's
/// empty-secret rejection is the other half): the guard must plant on
/// first-time activation only, and must never resurrect a deleted secret or
/// overwrite an existing one with an empty value on a restart started without
/// `-s`. Without these, the whole suite would still pass if the guard were
/// reverted to the old unconditional planting.
void main() {
  AtSignLogger.root_level = 'WARNING';

  group('CRAM secret bootstrap planting', () {
    late AtSecondaryServerImpl server;

    setUp(() async {
      await verbTestsSetUp();
      server = AtSecondaryServerImpl.getInstance();
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    test('plants the secret on first activation (non-empty, no marker, absent)',
        () async {
      expect(await keyValueStore.exists(AtConstants.atCramSecret), isFalse);

      await server.plantCramSecretIfRequired(
          keyValueStore, 'super-secret-cram-value');

      expect((await keyValueStore.get(AtConstants.atCramSecret))!.data,
          'super-secret-cram-value');
    });

    test('does NOT plant an empty secret (the null/empty CRAM backdoor)',
        () async {
      await server.plantCramSecretIfRequired(keyValueStore, '');
      expect(await keyValueStore.exists(AtConstants.atCramSecret), isFalse);
    });

    test('does NOT plant when no secret was supplied (restart without -s)',
        () async {
      await server.plantCramSecretIfRequired(keyValueStore, null);
      expect(await keyValueStore.exists(AtConstants.atCramSecret), isFalse);
    });

    test('does NOT clobber an existing secret on a restart without -s',
        () async {
      await keyValueStore.put(
          AtConstants.atCramSecret, AtData()..data = 'real-secret');

      // Restart without -s -> sharedSecret is null: the existing secret stands.
      await server.plantCramSecretIfRequired(keyValueStore, null);
      expect((await keyValueStore.get(AtConstants.atCramSecret))!.data,
          'real-secret');

      // A restart WITH a different -s must not replace an existing secret either.
      await server.plantCramSecretIfRequired(
          keyValueStore, 'a-different-secret');
      expect((await keyValueStore.get(AtConstants.atCramSecret))!.data,
          'real-secret');
    });

    test(
        'does NOT resurrect a deleted secret (deleted-marker suppresses plant)',
        () async {
      // Onboarding deleted the secret and left the tombstone marker behind.
      await keyValueStore.put(
          AtConstants.atCramSecretDeleted, AtData()..data = 'true');

      await server.plantCramSecretIfRequired(
          keyValueStore, 'attempted-resurrection');

      expect(await keyValueStore.exists(AtConstants.atCramSecret), isFalse);
    });
  });
}
