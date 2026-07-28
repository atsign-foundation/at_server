import 'dart:convert';

import 'package:test/test.dart';
import 'package:version/version.dart';

import 'e2e_test_utils.dart' as e2e;

/// End-to-end cover for the post-quantum inter-server (FROM/POL) handshake,
/// run against real, already-deployed atServers rather than a dockerized VE.
///
/// There's no verb that drives FROM/POL directly — it only fires internally
/// when an authenticated client asks its own server for a key owned by the
/// *other* atSign (see `LookupVerbHandler._fetchDataOwnedByOtherAtSign`).
/// Every test below forces that path via `plookup`, the same mechanism
/// `plookup_verb_test.dart` already relies on for its cross-atSign checks.
void main() {
  late String atSign_1;
  late e2e.SimpleOutboundConnection sh1;

  late String atSign_2;
  late e2e.SimpleOutboundConnection sh2;

  // Whether both peers are running a server version that publishes/verifies
  // the ML-DSA-65 PQ signing record (>= 3.15.2). Config pairs mixing a trunk
  // and a prod atSign (config34/config56) will genuinely be false until prod
  // catches up — that's a real mixed-version fleet, not a test gap.
  late bool pqSupported;

  setUpAll(() async {
    List<String> atSigns = e2e.knownAtSigns();
    atSign_1 = atSigns[0];
    sh1 = await e2e.getSocketHandler(atSign_1);
    atSign_2 = atSigns[1];
    sh2 = await e2e.getSocketHandler(atSign_2);

    final v1 = Version.parse(await sh1.getVersion());
    final v2 = Version.parse(await sh2.getVersion());
    pqSupported = v1 >= Version(3, 15, 2) && v2 >= Version(3, 15, 2);
  });

  tearDownAll(() {
    sh1.close();
    sh2.close();
  });

  setUp(() async {
    print("Clearing socket response queues");
    sh1.clear();
    sh2.clear();
  });

  test('PQ signing public key is published and cross-server fetchable',
      () async {
    if (!pqSupported) {
      print('Skipping: $atSign_1 / $atSign_2 pair is not PQ-capable '
          '(< 3.15.2)');
      return;
    }

    /// PLOOKUP VERB — forces sh2's server to complete a real FROM/POL
    /// handshake to sh1's server before it can return this cross-atSign key.
    await sh2.writeCommand('plookup:pq_signing_publickey$atSign_1');
    String response = await sh2.read();
    print('plookup verb response $response');

    expect(response, startsWith('data:'),
        reason: 'the record is published at startup by PqKeyManager, so a '
            'peer plookup must resolve it once the handshake succeeds');

    var record =
        jsonDecode(response.replaceFirst('data:', '').trim()) as Map;
    expect(record.keys, contains('ml-dsa-65'),
        reason: 'the record is keyed by algorithm id for crypto agility');
    expect(base64Decode(record['ml-dsa-65'] as String).length, 1952,
        reason: 'raw ML-DSA-65 public key length (FIPS 204)');
  }, timeout: Timeout(Duration(seconds: 120)));

  test('an ordinary cross-server lookup completes through the FROM/POL '
      'handshake', () async {
    /// UPDATE VERB
    await sh1.writeCommand('update:public:pq_e2e_probe$atSign_1 hello-pq');
    String response = await sh1.read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    /// PLOOKUP VERB — not version-gated: on a PQ-capable pair this is the
    /// ML-DSA-65 happy path; on a mixed/legacy pair it proves the RSA
    /// fallback keeps a rolling upgrade working either way.
    await sh2.writeCommand('plookup:pq_e2e_probe$atSign_1');
    response = await sh2.read();
    print('plookup verb response $response');
    expect(response, contains('data:hello-pq'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('a nonexistent cross-server key surfaces a clean not-found error, '
      'not a handshake failure', () async {
    /// PLOOKUP VERB for a key that was never written. A clean AT0015 (rather
    /// than an auth/handshake error) proves the FROM/POL exchange itself
    /// succeeded and the failure is purely "key not found" — the unhappy
    /// sibling of the previous test.
    await sh2.writeCommand('plookup:pq_e2e_no_such_key$atSign_1');
    String response = await sh2.read();
    print('plookup verb response $response');

    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    expect(errorMap['errorCode'], 'AT0015');
    expect(errorMap['errorDescription'],
        contains(
            'public:pq_e2e_no_such_key$atSign_1 does not exist in keystore'));
  }, timeout: Timeout(Duration(seconds: 120)));
}
