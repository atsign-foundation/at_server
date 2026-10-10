import 'dart:convert';

import 'package:test/test.dart';
import 'package:version/version.dart';

import 'e2e_test_utils.dart' as e2e;

/// Scenarios: features/caching/cache_upkeep.feature
///
/// atSign_1 owns the records and atSign_2 looks them up, so what is cached
/// and committed is decided by atSign_2's atServer.
void main() {
  late String atSign_1;
  late e2e.SimpleOutboundConnection sh1;

  late String atSign_2;
  late e2e.SimpleOutboundConnection sh2;
  late Version readerVersion;

  setUpAll(() async {
    List<String> atSigns = e2e.knownAtSigns();
    atSign_1 = atSigns[0];
    sh1 = await e2e.getSocketHandler(atSign_1);
    atSign_2 = atSigns[1];
    sh2 = await e2e.getSocketHandler(atSign_2);
    readerVersion = Version.parse(await sh2.getVersion());
  });

  tearDownAll(() {
    sh1.close();
    sh2.close();
  });

  setUp(() {
    sh1.clear();
    sh2.clear();
  });

  Future<String> send(e2e.SimpleOutboundConnection sh, String command) async {
    await sh.writeCommand(command);
    return sh.read();
  }

  /// The reader's last commit id, from `stats:3`, whose value is itself JSON.
  Future<int> readerCommitId() async {
    final stats =
        jsonDecode((await send(sh2, 'stats:3')).replaceAll('data:', '').trim());
    final value = jsonDecode(stats[0]['value'].toString());
    return value is int ? value : int.parse(value.toString());
  }

  test(
      'Looking up a record that does not exist commits nothing when no copy is held',
      () async {
    if (readerVersion < Version(3, 17, 1)) {
      markTestSkipped('the reader\'s atServer, $readerVersion, predates '
          '3.17.1 and commits a DELETE for every miss');
      return;
    }
    // A first lookup to atSign_1 caches its encryption public key, which
    // commits; a warm-up keeps that out of the measured window.
    await send(sh2, 'plookup:no-such-warmup$atSign_1');
    final String record =
        'email-${DateTime.now().microsecondsSinceEpoch}$atSign_1';
    final int before = await readerCommitId();

    expect(await send(sh2, 'plookup:$record'), contains('AT0015'));

    expect(await readerCommitId(), before,
        reason: 'there was no copy, so nothing should have been committed');
  }, timeout: Timeout(Duration(seconds: 120)));

  test('Looking up a record that no longer exists deletes the copy held',
      () async {
    final String record =
        'email-${DateTime.now().microsecondsSinceEpoch}$atSign_1';
    expect(await send(sh1, 'update:ttr:1:public:$record bobs-value'),
        startsWith('data:'));
    expect(await send(sh2, 'plookup:$record'), 'data:bobs-value');
    expect(await send(sh2, 'llookup:cached:public:$record'), 'data:bobs-value');
    await Future.delayed(const Duration(milliseconds: 1100));
    expect(await send(sh1, 'delete:public:$record'), startsWith('data:'));

    expect(await send(sh2, 'plookup:$record'), contains('AT0015'));

    expect(await send(sh2, 'llookup:cached:public:$record'), contains('AT0015'),
        reason: 'the reader\'s copy goes once the owner no longer has it');
  }, timeout: Timeout(Duration(seconds: 120)));
}
