import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:test/test.dart';

void main() {
  group('Given a connection', () {
    InboundConnectionMetadata session() =>
        InboundConnectionMetadata()..sessionID = 's1';

    test('when it has not authenticated, then it is named as such', () {
      expect(describeInboundConnection(session()),
          'session s1 (not authenticated)');
    });

    test('when it authenticated with cram, then it is named CRAM', () {
      expect(
          describeInboundConnection(session()
            ..isAuthenticated = true
            ..authType = AuthType.cram),
          'session s1 (CRAM)');
    });

    test('when it authenticated with a legacy pkam, then it names primary', () {
      expect(
          describeInboundConnection(session()
            ..isAuthenticated = true
            ..authType = AuthType.pkamLegacy
            ..enrollmentId = 'primary'),
          'session s1 (legacy pkam, enrollment primary)');
    });

    test('when it authenticated with apkam, then it names the enrollment', () {
      expect(
          describeInboundConnection(session()
            ..isAuthenticated = true
            ..authType = AuthType.apkam
            ..enrollmentId = 'e1'),
          'session s1 (apkam, enrollment e1)');
    });

    test('when a peer proved itself by pol, then it names the peer', () {
      expect(
          describeInboundConnection(session()
            ..isPolAuthenticated = true
            ..fromAtSign = '@bob'.toAtsign()),
          'session s1 (pol as @bob)');
    });

    test(
        'when its pkam failed after an enrollment, then it names both the state and the enrollment',
        () {
      expect(
          describeInboundConnection(session()
            ..authType = AuthType.apkam
            ..enrollmentId = 'e1'),
          'session s1 (not authenticated, enrollment e1)');
    });
  });
}
