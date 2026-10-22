import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

import 'atsign_bound_harness.dart';
import 'test_utils.dart';

void main() {
  setUpAll(() async => await verbTestsSetUpAll());
  setUp(() async => await setUpAtSignBound());
  tearDown(() async => await verbTestsTearDown());

  group('Given @alice\'s authenticated client', () {
    test(
        'when it scans @alice spelled in capitals, '
        'then it lists this atServer\'s keys without asking the atDirectory',
        () async {
      await keyValueStore.put('public:phone.wavi@alice', AtData()..data = '1');
      final connection = aliceClient();
      await send('scan:@Alice', connection);
      expect(connection.writes.single, contains('public:phone.wavi@alice'));
      expectNothingLookedUp();
    });

    test(
        'when it sends a notify that names no recipient, '
        'then it is refused with AT0003 before anything is stored', () async {
      final connection = aliceClient();
      final before = await footprint();
      await send('notify:update:public:phone.wavi@alice:v', connection);
      expect(connection.writes, [
        'error:AT0003-Invalid syntax : invalid @sign: must include one @'
            ' character and at least one character on the right\n@alice@'
      ]);
      expect(await footprint(), before);
      expect(connection.closeCount, 0);
    });
  });
}
