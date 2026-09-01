import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';

/// The atSign's oldest credential — the legacy keyfile, which authenticates
/// with no enrollment id — driven end to end over the wire.
///
/// The unit suite pins the handler's decisions directly. Only here is the
/// surrounding machinery observable: that a real legacy signature creates the
/// housekeeping enrollment, that the roster shows it, that the credential can
/// upgrade itself without an approver, and — the part no unit test reaches —
/// that the successor's FIRST AUTHENTICATION is what arms the expiry cap on
/// the credential it replaced.
///
/// ⚠️ Runs against its own atSign, and must. Retrofitting a legacy credential
/// is ONE-SHOT: the successor exists for ever, the housekeeping enrollment is
/// capped, and a second retrofit is refused from then on. Against the shared
/// atSign this would poison every other file in the pack, and would pass on a
/// fresh virtualenv while failing on any re-run against the same container.
void main() {
  String atSign = ConfigUtil.getYaml()!['thirdAtSignServer']['thirdAtSignName'];
  String host = ConfigUtil.getYaml()!['thirdAtSignServer']['thirdAtSignUrl'];
  int port = ConfigUtil.getYaml()!['thirdAtSignServer']['thirdAtSignPort'];

  /// The id the server gives the housekeeping enrollment. A RAW LITERAL rather
  /// than an import: it is at-rest and cross-repo — at_client publishes a
  /// legacy client's signing key at `public:_apsk.primary.a.__e@<atSign>` —
  /// so a change to it has to break this test rather than follow along.
  const String housekeepingId = 'primary';

  List<OutboundConnectionFactory> open = [];

  Future<OutboundConnectionFactory> newConnection() async {
    OutboundConnectionFactory c = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, host, port);
    open.add(c);
    return c;
  }

  /// A LEGACY PKAM connection: `pkam:` with no enrollment id at all, verified
  /// against `at_pkam_publickey`. This is the credential under test.
  Future<OutboundConnectionFactory> legacyConnection() async {
    OutboundConnectionFactory c = await newConnection();
    expect((await c.authenticateConnection(authType: AuthType.pkam)).trim(),
        'data:success');
    return c;
  }

  Future<Map> enrollList(OutboundConnectionFactory c) async =>
      jsonDecode((await c.sendRequestToServer('enroll:list'))
          .replaceFirst('data:', '')
          .trim()) as Map;

  Map recordFor(Map list, String enrollmentId) {
    final key = list.keys.firstWhere(
        (k) => '$k'.startsWith('$enrollmentId.'),
        orElse: () => throw StateError(
            'no enroll:list entry for $enrollmentId in ${list.keys}'));
    return list[key] as Map;
  }

  tearDown(() async {
    for (final c in open) {
      c.close();
    }
    open = [];
  });

  test('a legacy connection creates the housekeeping enrollment and is listed '
      'as it', () async {
    final legacy = await legacyConnection();

    final list = await enrollList(legacy);
    final h = recordFor(list, housekeepingId);
    expect(h['status'], 'approved');
    expect(h['namespace'], {'*': 'rw', '__manage': 'rw'},
        reason: 'it stands for the credential the atSign was onboarded with, '
            'and stating those grants is the point of the record');
  });

  test('the legacy credential upgrades itself, and the successor\'s first '
      'authentication arms the cap on it', () async {
    final legacy = await legacyConnection();

    // The retrofit. No OTP and no approver: the authenticated legacy
    // credential is the whole authority, exactly as an APKAM one is. No
    // namespaces either — a retrofit inherits its predecessor's and may not
    // choose them.
    final request = 'enroll:request:{"appName":"legacy","deviceName":"legacy",'
        '"apkamPublicKey":"${apkamPublicKeyMap[atSign]!}"}';
    final response = jsonDecode(
        (await legacy.sendRequestToServer(request)).replaceFirst('data:', ''));
    expect(response['status'], 'approved',
        reason: 'auto-approved — this is the no-approver upgrade path the '
            'legacy keyfile never had');
    final String successorId = response['enrollmentId'];

    final before = recordFor(await enrollList(legacy), successorId);
    expect(before['namespace'], {'*': 'rw', '__manage': 'rw'},
        reason: 'a retrofit carries its predecessor\'s grants exactly');
    expect(before.containsKey('predecessorCapArmedAt'), isFalse,
        reason: 'PRECONDITION, and the whole point of the ordering: storing a '
            'successor proves only that the server wrote a record. The '
            'private half lives client-side and may never have reached disk, '
            'so nothing may be retired yet');

    // The successor authenticates for the first time. THIS is what proves the
    // private half survived, and it is what arms the cap.
    final successor = await newConnection();
    expect(
        (await successor.authenticateConnection(
                authType: AuthType.apkam, enrollmentId: successorId))
            .trim(),
        'data:success',
        reason: 'the successor is not merely recorded: it works');

    final after = recordFor(await enrollList(legacy), successorId);
    expect(after['predecessorCapArmedAt'], isNotNull,
        reason: 'the cap is armed by the successor\'s first authentication, '
            'never by its creation — a keyfile write that failed would '
            'otherwise start a clock on the only credential that still works');
    expect(() => DateTime.parse(after['predecessorCapArmedAt'] as String),
        returnsNormally,
        reason: 'the wire contract is ISO-8601');
  });

  test('a successor of the legacy credential may not retrofit again',
      () async {
    // The once-off rule reaches this path too: the legacy keyfile gets ONE
    // no-approver migration, not a series that restarts the key-expiry clock
    // every time. The successor from the previous test is already on this
    // atSign, so ask it directly.
    final legacy = await legacyConnection();
    // Derived from the record's KEY — `<id>.new.enrollments.__manage@<atSign>`
    // — which is where the id actually lives, rather than from a field the
    // response is not obliged to carry.
    final entry = (await enrollList(legacy)).entries.firstWhere(
        (e) => (e.value as Map)['parentEnrollmentId'] == housekeepingId,
        orElse: () => throw StateError(
            'no successor of $housekeepingId on $atSign. A retrofit is '
            'one-shot per atSign, so this case reuses the successor the test '
            'above created and depends on it having run'));
    final String successorId = '${entry.key}'.split('.').first;

    final successor = await newConnection();
    expect(
        (await successor.authenticateConnection(
                authType: AuthType.apkam, enrollmentId: successorId))
            .trim(),
        'data:success');

    final refused = await successor.sendRequestToServer(
        'enroll:request:{"appName":"legacy","deviceName":"legacy",'
        '"apkamPublicKey":"${apkamPublicKeyMap[atSign]!}"}');
    expect(refused, startsWith('error:'),
        reason: 'a replacement may not itself be replaced without an '
            'approver. Got: $refused');
  });
}
