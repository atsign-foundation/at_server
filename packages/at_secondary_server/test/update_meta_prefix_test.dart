import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'atsign_bound_harness.dart';
import 'test_utils.dart';

/// Catalogue: features/keys/update_meta_prefix.feature
void main() {
  setUpAll(() async => await verbTestsSetUpAll());
  setUp(() async {
    await setUpAtSignBound();
    await enMgr.serialiseMutation(() => enMgr.mintPrimary('a pkam key'));
  });
  tearDown(() async => await verbTestsTearDown());

  test('An update of a key whose name starts with meta is stored', () async {
    final Connection client = Connection(InboundConnectionMetadata()
      ..isAuthenticated = true
      ..authType = AuthType.pkamLegacy
      ..enrollmentId = EnrollmentManager.primaryEnrollmentId);

    await send('update:metadata.wavi$alice v', client);
    await send('llookup:metadata.wavi$alice', client);

    expect(client.writes[0], matches(RegExp(r'^data:\d+\n@alice@$')));
    expect(client.writes[1], 'data:v\n@alice@');
  });
}
