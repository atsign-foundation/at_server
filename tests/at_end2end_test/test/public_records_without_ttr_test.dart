import 'package:test/test.dart';
import 'package:version/version.dart';

import 'e2e_test_utils.dart' as e2e;

/// Scenarios: features/caching/public_records_without_ttr.feature
///
/// atSign_1 owns the records and atSign_2 reads them, so whether a copy is
/// kept is decided by atSign_2's atServer.
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

  Future<void> ownerWrites(String command) async {
    await sh1.writeCommand(command);
    final String response = await sh1.read();
    expect(response, startsWith('data:'), reason: '$command: $response');
  }

  Future<String> readerSends(String command) async {
    await sh2.writeCommand(command);
    return sh2.read();
  }

  group('Looking up a public record with no ttr leaves nothing behind', () {
    for (final List<String> row in [
      ['phone', ''],
      ['phone', 'ttr:0:'],
      ['__nskey.app', ''],
    ]) {
      final String name = row[0];
      final String ttr = row[1];
      test('$name with ${ttr.isEmpty ? 'no ttr' : ttr}', () async {
        if (readerVersion < Version(3, 17, 1)) {
          markTestSkipped('the reader\'s atServer, $readerVersion, predates '
              '3.17.1 and still keeps a 24-hour copy');
          return;
        }
        final String record =
            '$name-${DateTime.now().microsecondsSinceEpoch}$atSign_1';
        await ownerWrites('update:${ttr}public:$record bobs-value');

        expect(await readerSends('plookup:$record'), 'data:bobs-value');

        final String copy = await readerSends('llookup:cached:public:$record');
        expect(copy, startsWith('error:'),
            reason: 'the reader\'s atServer keeps no copy, but answered $copy');
        expect(copy, contains('AT0015'));
      }, timeout: Timeout(Duration(seconds: 120)));
    }
  });

  test('A record with a ttr is still copied, and served within it', () async {
    final String record =
        'phone-${DateTime.now().microsecondsSinceEpoch}$atSign_1';
    await ownerWrites('update:ttr:3600:public:$record bobs-value');

    expect(await readerSends('plookup:$record'), 'data:bobs-value');

    expect(await readerSends('llookup:cached:public:$record'),
        'data:bobs-value');
  }, timeout: Timeout(Duration(seconds: 120)));
}
