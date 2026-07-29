import 'dart:convert';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';

/// End-to-end cover for the post-quantum inter-server handshake.
///
/// The unit tests around `PolVerbHandler` stub every `lookUp`/`plookUp`, so
/// they cannot show that the published PQ signing record is actually reachable
/// over the wire. It is written straight to the keystore by `PqKeyManager`, so
/// if it were not served over the wire every unit test would still pass while
/// inter-server auth was broken in production.
///
/// Three distinct wire paths are involved, and picking the wrong verb for each
/// silently tests nothing (see `LookupVerbHandler` and
/// `AtCacheManager.remoteLookUp`):
///
/// - **Our own record, unauthenticated `lookup:`** — exactly how a *peer*
///   fetches our signing key: `remoteLookUp` resolves a `cached:public:` name
///   with `handshakeRequired: false`, i.e. a plain unauthenticated `lookup:`
///   against the key owner's own server.
/// - **The peer's record, `plookup:` on an authenticated connection** — an
///   unauthenticated `lookup:` never proxies. It takes
///   `LookupVerbHandler._handleUnAuthenticatedConnection`, which only ever
///   reads `public:<key>` from *this* server's keystore whatever atSign the
///   key names, so it can never see a peer's record. Cross-atSign fetch lives
///   behind `_fetchDataOwnedByOtherAtSign`, reachable only once authenticated.
/// - **A real FROM/POL handshake: authenticated `lookup:` of a *non-public*
///   key owned by the peer** — the only one of the three that handshakes, via
///   the `cached:<thisAtSign>:` branch of `remoteLookUp`
///   (`handshakeRequired: true`). `plookup:` of a public key does not
///   handshake at all.
void main() {
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  String secondAtSign =
      ConfigUtil.getYaml()!['secondAtSignServer']['secondAtSignName'];

  const String pqRecordName = 'pq_signing_publickey';
  const String pqAlgo = 'ml-dsa-65';

  late OutboundConnectionFactory connection;

  /// Both cross-server tests below open outbound TLS connections to the peer
  /// (and, for the handshake case, a second one back), so they need a budget
  /// well above dart test's 30s default. Without this the default caps the
  /// whole test *below* the wrapper's own 90s `maxWaitMilliSeconds`, so a slow
  /// handshake always dies at 30s and the wait budget can never be reached —
  /// making "slow" and "hung" indistinguishable. Matches the 120s the
  /// equivalent tests in `at_end2end_test` already use.
  final crossServerTimeout = Timeout(Duration(seconds: 120));

  setUp(() async {
    connection = OutboundConnectionFactory();
    await connection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
  });

  tearDown(() async => await connection.close());

  /// Asserts [response] is a `data:` record carrying a well-formed [pqAlgo]
  /// public key. Shared by the own-record and peer-record tests: the two reach
  /// the record over different wire paths but must agree on its shape.
  void expectPqSigningRecord(String response, {required String reason}) {
    expect(response, startsWith('data:'), reason: reason);

    var record = jsonDecode(response.replaceFirst('data:', '').trim()) as Map;
    expect(record.keys, contains(pqAlgo),
        reason: 'the record is keyed by algorithm id for crypto agility');
    expect(base64Decode(record[pqAlgo] as String).length, 1952,
        reason: 'raw ML-DSA-65 public key length (FIPS 204)');
  }

  group('PQ signing public key is published and locally fetchable', () {
    test('an unauthenticated lookup returns a parseable $pqAlgo record',
        () async {
      String response = await connection
          .sendRequestToServer('lookup:$pqRecordName$firstAtSign');
      expectPqSigningRecord(response,
          reason: 'the record is published at startup by PqKeyManager, so an '
              'unauthenticated lookup must resolve it — this is exactly how a '
              'peer fetches our key when verifying our pol signature');
    });
  });

  group('PQ record is protected from clients', () {
    setUp(() async {
      expect(await connection.authenticateConnection(), 'data:success',
          reason: 'the assertions below distinguish a *protected-key* refusal '
              'from any other error, so an unauthenticated connection would '
              'make them vacuous rather than failing outright');
    });

    /// Asserts the write was refused specifically for being a protected key
    /// (AT0009), not merely that *some* error came back — a bare
    /// `startsWith('error:')` also matches AT0401 "cannot be executed without
    /// auth", so it would pass even if the record were writable.
    void expectProtectedKeyRefusal(String response, String operation) {
      expect(response, contains('AT0009'),
          reason: 'only the server may $operation its own signing key');
      expect(response, contains('Cannot $operation protected key'),
          reason: 'refused for being protected, not for some unrelated reason');
    }

    test('an authenticated client cannot update it', () async {
      String response = await connection.sendRequestToServer(
          'update:public:$pqRecordName$firstAtSign forged');
      expectProtectedKeyRefusal(response, 'update');
    });

    test('an authenticated client cannot delete it', () async {
      String response = await connection
          .sendRequestToServer('delete:public:$pqRecordName$firstAtSign');
      expectProtectedKeyRefusal(response, 'delete');
    });

    test('and the record survives those attempts', () async {
      // Closes the loop the two refusals above leave open: a refusal response
      // proves the verb was rejected, not that the stored record is still
      // intact. Read back on a *fresh unauthenticated* connection, because
      // that is the only path that resolves `public:<key>` — an authenticated
      // lookup of our own key resolves `<thisAtSign>:<key>` instead.
      var reader = OutboundConnectionFactory();
      await reader.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      try {
        expectPqSigningRecord(
            await reader
                .sendRequestToServer('lookup:$pqRecordName$firstAtSign'),
            reason: 'the published record must be byte-for-byte intact after '
                'a rejected update and delete');
      } finally {
        await reader.close();
      }
    });
  });

  group('cross-server auth completes with PQ in play', () {
    setUp(() async => await connection.authenticateConnection());

    test('the peer\'s own record is reachable across servers', () async {
      // plookup:, not lookup: — an unauthenticated lookup of a @peer key never
      // proxies (it reads public:<key> from *this* keystore and 404s), and this
      // record is what a peer's verifier must fetch before it can check our
      // signature. This path is `handshakeRequired: false`, so it proves
      // reachability only; the handshake itself is the next test.
      String response = await connection
          .sendRequestToServer('plookup:$pqRecordName$secondAtSign');
      expectPqSigningRecord(response,
          reason: 'cross-server pol depends on fetching the *peer\'s* record');
    }, timeout: crossServerTimeout);

    test('a lookup of a key shared by the peer completes a FROM/POL handshake',
        () async {
      // The only test in the suite that drives a live FROM/POL exchange:
      // `shared_key` is non-public, so remoteLookUp takes its
      // `cached:<thisAtSign>:` branch with handshakeRequired: true. Both
      // servers publish a PQ record, so the handshake takes the ML-DSA path; a
      // signature or record failure surfaces here as an error response rather
      // than data/no-key.
      //
      // The 30s idle window sits inside the wrapper's 90s total budget, which
      // crossServerTimeout above now actually allows us to reach — a cold
      // handshake chains two outbound TLS connections plus the extra
      // checkPeerPqSupport round trip the PQ path adds over legacy RSA. A
      // failure at 90s (AtTimeoutException) means a genuine hang rather than
      // CI latency, and wants server-side logs.
      String response = await connection.sendRequestToServer(
          'lookup:shared_key$secondAtSign',
          transientWaitTimeMillis: 30000);
      // Matched on the code alone, not a prefix: an authenticated connection
      // has sent a `from` with its config, so the server knows it can speak
      // JSON and returns `error:{"errorCode":"AT0015",...}` rather than the
      // bare `error:AT0015-...` form it reserves for old clients.
      expect(response, anyOf(startsWith('data:'), contains('AT0015')),
          reason: 'either the key resolves or it genuinely does not exist; an '
              'auth failure would come back as a pol/handshake error');
      // A pol-prefixed key name in the not-found error is the positive proof
      // the handshake itself completed: only PolVerbHandler's authenticated
      // path builds `<fromAtSign>:<key>` (LookupVerbHandler
      // ._handlePolAuthConnection). Without it, an AT0015 here could equally
      // mean the request never got past this server.
      if (response.contains('AT0015')) {
        expect(response, contains('$firstAtSign:shared_key$secondAtSign'),
            reason: 'the peer must have resolved the key under our atSign, '
                'which only happens on a pol-authenticated connection');
      }
    }, timeout: crossServerTimeout);
  });
}
