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
///
/// Which verb is used decides whether a handshake happens at all, and getting
/// it wrong tests nothing while still passing. `AtCacheManager.remoteLookUp`
/// picks the branch:
/// - a **`public:`** key (what `plookup` always resolves) goes out with
///   `handshakeRequired: false` — a plain unauthenticated `lookup:` to the key
///   owner, with **no FROM/POL at all**. `OutboundClient.lookUp` even throws
///   if a handshake *was* done on this path.
/// - a key **shared with us** (`@us:key@them`, non-public) goes out with
///   `handshakeRequired: true` — the real FROM/POL exchange.
///
/// So the first test below uses `plookup` deliberately, to prove only that a
/// verifier can *fetch* our published key; the two that claim to exercise the
/// handshake use a shared, non-public key, mirroring
/// `lookup_verb_test.dart`'s 'update-lookup verb on private key' pattern.
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

    /// PLOOKUP VERB — proves sh2's server can reach and parse the record sh1
    /// published. This is `handshakeRequired: false` (a public key), i.e. the
    /// exact wire call a verifier makes to fetch a prover's signing key
    /// *before* any pol verification — a prerequisite for the handshake, not
    /// the handshake itself. The two tests below cover that.
    await sh2.writeCommand('plookup:pq_signing_publickey$atSign_1');
    String response = await sh2.read();
    print('plookup verb response $response');

    expect(response, startsWith('data:'),
        reason: 'the record is published at startup by PqKeyManager, so a '
            'peer must be able to fetch it — if this fails, no peer can '
            'verify our pol signatures and every handshake degrades to RSA');

    var record = jsonDecode(response.replaceFirst('data:', '').trim()) as Map;
    expect(record.keys, contains('ml-dsa-65'),
        reason: 'the record is keyed by algorithm id for crypto agility');
    expect(base64Decode(record['ml-dsa-65'] as String).length, 1952,
        reason: 'raw ML-DSA-65 public key length (FIPS 204)');
  }, timeout: Timeout(Duration(seconds: 120)));

  test(
      'an ordinary cross-server lookup completes through the FROM/POL '
      'handshake', () async {
    /// UPDATE VERB — shared with atSign_2 rather than public, so that the
    /// lookup below takes remoteLookUp's `handshakeRequired: true` branch.
    await sh1.writeCommand('update:$atSign_2:pq_e2e_shared$atSign_1 hello-pq');
    String response = await sh1.read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    /// LOOKUP VERB — bypassCache:true so a value cached by an earlier run can
    /// never satisfy this locally and skip the handshake we are here to test.
    ///
    /// Not version-gated: on a PQ-capable pair this is the ML-DSA-65 happy
    /// path; on a mixed/legacy pair it proves the RSA fallback keeps a rolling
    /// upgrade working either way.
    await sh2.writeCommand('lookup:bypassCache:true:pq_e2e_shared$atSign_1');
    response = await sh2.read();
    print('lookup verb response $response');
    expect(response, contains('data:hello-pq'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test(
      'a nonexistent cross-server key surfaces a clean not-found error, '
      'not a handshake failure', () async {
    /// LOOKUP VERB for a shared key that was never written. A clean AT0015
    /// (rather than an auth/handshake error) proves the FROM/POL exchange
    /// itself succeeded and the failure is purely "key not found" — the
    /// unhappy sibling of the previous test.
    await sh2
        .writeCommand('lookup:bypassCache:true:pq_e2e_no_such_key$atSign_1');
    String response = await sh2.read();
    print('lookup verb response $response');

    expect(response, contains('AT0015'));

    /// The peer resolved it under *our* atSign, which only PolVerbHandler's
    /// authenticated path does (LookupVerbHandler._handlePolAuthConnection
    /// builds `<fromAtSign>:<key>`). That prefix is the positive proof the
    /// handshake completed; without it an AT0015 could equally mean the
    /// request never left sh2's own server.
    expect(response, contains('$atSign_2:pq_e2e_no_such_key$atSign_1'));
  }, timeout: Timeout(Duration(seconds: 120)));
}
