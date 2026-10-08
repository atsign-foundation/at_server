import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Each of the two places the server runs the housekeeping sweep, pinned.
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

  /// The level of each record the server logs about the injected failure
  /// while the expiry timer's callback runs against a store that throws
  /// [failure].
  Future<List<Level>> sweepLogLevels(Object failure) async {
    final failing = MockAtKeyValueStore();
    when(() => failing.deleteExpiredKeys()).thenThrow(failure);
    final AtSecondaryServerImpl server = AtSecondaryServerImpl.getInstance();
    server.keyValueStore = failing;
    final Level prior = server.logger.logger.level;
    server.logger.level = 'warning';
    final List<Level> levels = [];
    final sub = server.logger.logger.onRecord.listen((LogRecord r) {
      if (r.message.contains('injected')) levels.add(r.level);
    });
    try {
      await expectLater(server.onExpirySweepTimerFired(), completes,
          reason: 'what escapes the callback escapes the timer');
    } finally {
      await sub.cancel();
      server.logger.logger.level = prior;
    }
    return levels;
  }

  test(
      'the expiry timer\'s callback survives an Error from the sweep, and '
      'logs it at severe', () async {
    expect(await sweepLogLevels(StateError('injected')), [Level.SEVERE],
        reason: 'an Error is a bug, not a passing failure');
  });

  test('control: an Exception from the sweep is logged at warning', () async {
    expect(await sweepLogLevels(Exception('injected')), [Level.WARNING]);
  });
}
