import 'dart:convert';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';

/// End-to-end cover for the post-quantum inter-server handshake.
///
/// The `PolVerbHandler` unit tests stub every `lookUp`/`plookUp`, so they can't
/// show that `SigningKeyManager`'s published record — written straight to the
/// keystore — is actually served over the wire. Without this suite, every unit
/// test would pass while inter-server auth was broken in production.
///
/// Three wire paths are involved, and the wrong verb for any of them silently
/// tests nothing (see `LookupVerbHandler` and `AtCacheManager.remoteLookUp`):
///
/// - **Our own record, unauthenticated `lookup:`** — how a *peer* fetches our
///   signing key: `remoteLookUp` resolves a `cached:public:` name with
///   `handshakeRequired: false`.
/// - **The peer's record, `plookup:` on an authenticated connection** — an
///   unauthenticated `lookup:` never proxies; it only reads `public:<key>` from
///   *this* keystore whatever atSign the key names
///   (`LookupVerbHandler._handleUnAuthenticatedConnection`). Cross-atSign fetch
///   lives behind `_fetchDataOwnedByOtherAtSign`, authenticated only.
/// - **A real FROM/POL handshake: authenticated `lookup:` of a *non-public* key
///   owned by the peer** — the only one of the three that handshakes, via
///   `remoteLookUp`'s `cached:<thisAtSign>:` branch. `plookup:` of a public key
///   does not handshake at all.
void main() {
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  String secondAtSign =
      ConfigUtil.getYaml()!['secondAtSignServer']['secondAtSignName'];

  // The one published signing-key record: generically named and permanent, its
  // top-level keys being challenge types. Spelled out rather than imported so a
  // rename of the server-side constant fails here loudly — peers fetch this by
  // name, so it is wire protocol.
  const String pqRecordName = 'signing_publickeys';
  const String pqAlgo = 'ml-dsa-65';

  late OutboundConnectionFactory connection;

  /// The cross-server tests open outbound TLS connections (two, for the
  /// handshake case), so dart test's 30s default would cap them *below* the
  /// wrapper's own 90s `maxWaitMilliSeconds` — making "slow" and "hung"
  /// indistinguishable. Matches the 120s `at_end2end_test` uses.
  final crossServerTimeout = Timeout(Duration(seconds: 120));

  setUp(() async {
    connection = OutboundConnectionFactory();
    await connection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
  });

  tearDown(() async => await connection.close());

  /// Asserts [response] is a `data:` record carrying a well-formed [pqAlgo]
  /// public key. Shared by the own-record and peer-record tests, which reach it
  /// over different wire paths but must agree on its shape.
  void expectPqSigningRecord(String response, {required String reason}) {
    expect(response, startsWith('data:'), reason: reason);

    var record = jsonDecode(response.replaceFirst('data:', '').trim()) as Map;
    expect(record.keys, contains(pqAlgo),
        reason: 'the record is keyed by challenge type for crypto agility — the '
            'same identifier that tags the pol cookie');
    // Each entry is an object, not a bare key, so a future algorithm can carry
    // parameters alongside its key without a format break.
    var entry = record[pqAlgo] as Map;
    expect(base64Decode(entry['publicKey'] as String).length, 1952,
        reason: 'raw ML-DSA-65 public key length (FIPS 204)');
    expect(record.containsKey('rsa-sha256'), isFalse,
        reason: 'RSA is not duplicated here — it stays at signing_publickey, '
            'and its location is implied by the type id');
  }

  group('PQ signing public key is published and locally fetchable', () {
    test('an unauthenticated lookup returns a parseable $pqAlgo record',
        () async {
      String response = await connection
          .sendRequestToServer('lookup:$pqRecordName$firstAtSign');
      expectPqSigningRecord(response,
          reason: 'the record is published at startup by SigningKeyManager, so an '
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

    /// Asserts refusal specifically for being a protected key (AT0009). A bare
    /// `startsWith('error:')` would also match AT0401 "cannot be executed
    /// without auth", passing even if the record were writable.
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
      // A refusal response proves the verb was rejected, not that the record
      // is intact. Read back on a *fresh unauthenticated* connection: it is the
      // only path resolving `public:<key>` — authenticated resolves
      // `<thisAtSign>:<key>` instead.
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
      // proxies (it reads public:<key> from *this* keystore and 404s). Being
      // `handshakeRequired: false`, this proves reachability only; the next
      // test drives the handshake.
      String response = await connection
          .sendRequestToServer('plookup:$pqRecordName$secondAtSign');
      expectPqSigningRecord(response,
          reason: 'cross-server pol depends on fetching the *peer\'s* record');
    }, timeout: crossServerTimeout);

    test('a lookup of a key shared by the peer completes a FROM/POL handshake',
        () async {
      // The only test here that drives a live FROM/POL exchange: `shared_key`
      // is non-public, so remoteLookUp takes its `cached:<thisAtSign>:` branch
      // with handshakeRequired: true. Both servers publish a PQ record, so the
      // handshake takes the ML-DSA path and a signature or record failure
      // surfaces as an error response rather than data/no-key.
      //
      // The 30s idle window sits inside the wrapper's 90s total budget (a cold
      // handshake chains two outbound TLS connections plus the extra
      // in-band type advert, so no capability probe). An AtTimeoutException at 90s means a
      // genuine hang, not CI latency, and wants server-side logs.
      String response = await connection.sendRequestToServer(
          'lookup:shared_key$secondAtSign',
          transientWaitTimeMillis: 30000);
      // Matched on the code alone: an authenticated connection has sent a
      // `from` with its config, so the server returns
      // `error:{"errorCode":"AT0015",...}` rather than the bare
      // `error:AT0015-...` form it reserves for old clients.
      expect(response, anyOf(startsWith('data:'), contains('AT0015')),
          reason: 'either the key resolves or it genuinely does not exist; an '
              'auth failure would come back as a pol/handshake error');
      // A pol-prefixed key name in the not-found error is positive proof the
      // handshake completed: only `LookupVerbHandler._handlePolAuthConnection`
      // builds `<fromAtSign>:<key>`. Without it, an AT0015 could equally mean
      // the request never left this server.
      if (response.contains('AT0015')) {
        expect(response, contains('$firstAtSign:shared_key$secondAtSign'),
            reason: 'the peer must have resolved the key under our atSign, '
                'which only happens on a pol-authenticated connection');
      }
    }, timeout: crossServerTimeout);
  });
}
