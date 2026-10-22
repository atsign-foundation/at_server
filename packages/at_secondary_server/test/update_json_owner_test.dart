import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:test/test.dart';

import 'atsign_bound_harness.dart';
import 'test_utils.dart';

/// Catalogue: features/keys/update_json_owner.feature
void main() {
  setUpAll(() async => await verbTestsSetUpAll());
  setUp(() async => await setUpAtSignBound());
  tearDown(() async => await verbTestsTearDown());

  /// A client of @alice on a connection that is enrollment e1, approved
  /// with `wavi:rw`.
  Future<Connection> e1() async {
    await keyValueStore.put(
        'e1.new.enrollments.__manage$alice',
        AtData()
          ..data = jsonEncode({
            'sessionId': '123',
            'appName': 'wavi',
            'deviceName': 'pixel',
            'namespaces': {'wavi': 'rw'},
            'apkamPublicKey': 'x',
            'requestType': 'newEnrollment',
            'approval': {'state': 'approved'}
          }));
    return Connection(InboundConnectionMetadata()
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..enrollmentId = 'e1');
  }

  Future<Connection> cram() async => aliceClient();

  String updateJson(String atKey) => 'update:json:${jsonEncode({
            'atKey': atKey,
            'value': 'v',
            'metadata': {
              'isPublic': false,
              'isBinary': false,
              'isEncrypted': false
            }
          })}';

  group('update:json refuses an atKey another atSign owns', () {
    for (final (
          String auth,
          Future<Connection> Function() connect,
          String atKey
        ) in [
      ('cram', cram, 'x.new.enrollments.__manage@bob'),
      ('apkam as enrollment e1', e1, 'x.e1.a.__e@bob'),
      ('apkam as enrollment e1', e1, 'x.wavi@bob'),
      ('apkam as enrollment e1', e1, 'public:y.wavi@bob'),
      ('apkam as enrollment e1', e1, '@alice:z.wavi@bob'),
    ]) {
      test('$auth, $atKey', () async {
        final Connection client = await connect();

        await send(updateJson(atKey), client);

        expect(client.writes.first, startsWith('error:AT0016'));
        expect(client.writes.first,
            contains('sharedBy atsign @bob should be same as current atsign'));
        expect(await keyValueStore.exists(atKey), isFalse,
            reason: 'nothing is stored');
      });
    }
  });

  group('update:json stores a record this atSign owns', () {
    for (final String atKey in ['x.wavi@alice', 'x.wavi@ALICE']) {
      test(atKey, () async {
        final Connection client = await e1();

        await send(updateJson(atKey), client);

        expect(client.writes.first, startsWith('data:'));
        expect((await keyValueStore.get('x.wavi@alice'))?.data, 'v');
      });
    }
  });
}
