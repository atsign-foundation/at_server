import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// The two places the server runs the housekeeping sweep, each pinned on its
/// own: one being right says nothing about the other, and a site that
/// stopped calling the sweep would leave expired keys on disk with nothing
/// going red. A test that calls runHousekeepingSweep() directly proves the
/// sweep works, not that anything runs it.
void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  /// A key whose ttl elapsed while nobody was looking, still on disk.
  Future<String> anElapsedKey() async {
    final String key = 'elapsed.wavi$alice';
    await keyValueStore.put(key, AtData()..data = 'x',
        assertedTimestamps: AtAssertedTimestamps(
            expiresAt: DateTime.now().toUtc().subtract(Duration(minutes: 1)),
            deriveTtl: true));
    expect(await keyValueStore.exists(key), isTrue,
        reason: 'precondition: elapsed, and still on disk');
    return key;
  }

  test('the startup path runs the sweep', () async {
    final String key = await anElapsedKey();

    await AtSecondaryServerImpl.getInstance().prepareStoreForFirstConnection();

    expect(await keyValueStore.exists(key), isFalse,
        reason: 'a key that expired while the server was down is reaped on '
            'the way up, by the startup path itself');
  });

  test('the expiry timer\'s callback runs the sweep', () async {
    final String key = await anElapsedKey();

    await AtSecondaryServerImpl.getInstance().onExpirySweepTimerFired();

    expect(await keyValueStore.exists(key), isFalse,
        reason: 'what the timer fires is what reaps; a callback that no '
            'longer ran the sweep would leave every expiry unwatched');
  });
}
