import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// What the cache REPORTS about another atSign's encryption public key when
/// the remote answers "do not cache" (`ttr` of 0 or null).
///
/// Every other public value in that case is given a 24-hour ttl as a
/// backwards-compatibility measure. An encryption public key is the carve-out:
/// it is kept indefinitely, spelled `ttr = -1` with no ttl.
///
/// The distinction that matters here is between what is STORED and what is
/// RETURNED. Storage is unaffected by the guard: `OutboundClient.connect`
/// caches the peer's key via `checkRemotePublicKey` before the cache manager
/// puts, so that put is an update and a stamped ttl never reaches the record.
/// The returned [AtData] is a different object, and it is what
/// `plookup:all` / `plookup:meta` serialise to the client through
/// `SecondaryUtil.prepareResponseData` — so a wrong ttl there tells the
/// client to expire a key this atServer keeps forever. `lookup` never
/// reaches this code: it builds a `cached:@<atSign>:` name, which the
/// `cached:public:` carve-out cannot match.
void main() {
  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  /// Answers bob's atServer's side of `lookup:all:<key>` with [atData].
  void peerAnswers(String remoteKeyName, AtData atData) {
    when(() => mockOutboundConnection.write('lookup:all:$remoteKeyName\n'))
        .thenAnswer((_) async {
      socketOnDataFn('data:${jsonEncode(atData.toJson())}\n$alice@'.codeUnits);
    });
  }

  // createdAt/updatedAt are required: AtMetaData.fromJson parses them
  // unguarded, so a bare AtMetaData cannot survive the wire round trip the
  // cache manager performs on the response.
  AtData remoteValue(String value, {int? ttr}) {
    final DateTime now = DateTime.now().toUtc();
    return AtData()
      ..data = value
      ..metaData = (AtMetaData()
        ..createdAt = now
        ..updatedAt = now
        ..ttr = ttr);
  }

  group('a "do not cache" response for an encryption public key', () {
    // ttr null and ttr 0 both mean "do not cache" in the protocol, and the
    // carve-out has to fire for both spellings.
    for (final int? ttr in <int?>[null, 0]) {
      test('with ttr $ttr the REPORTED metadata says keep it indefinitely',
          () async {
        peerAnswers('publickey@bob', remoteValue('bobs_public_key', ttr: ttr));

        final AtData? returned = await cacheManager
            .remoteLookUp(cachedBobsPublicKeyName, maintainCache: true);

        expect(returned, isNotNull);
        expect(returned!.metaData!.ttr, -1,
            reason: 'this metadata is what plookup:all and plookup:meta '
                'hand the client; -1 is how "cache indefinitely" is spelled');
        expect(returned.metaData!.ttl, anyOf(isNull, 0),
            reason: 'a 24h ttl here tells every client to expire a key this '
                'atServer keeps forever, and to re-fetch it daily');
      });
    }

    test('the STORED record is kept indefinitely', () async {
      // Already true before the fix, because connect caches the key first,
      // so this put is an update. Pinned as the invariant it is, not as a
      // detector: deliberately insensitive to the guard above it.
      peerAnswers('publickey@bob', remoteValue('bobs_public_key'));

      await cacheManager.remoteLookUp(cachedBobsPublicKeyName,
          maintainCache: true);

      final AtData? stored = await keyValueStore.get(cachedBobsPublicKeyName);
      expect(stored, isNotNull,
          reason: '"do not cache" applies to everything except an encryption '
              'public key');
      expect(stored!.metaData!.ttr, -1);
      expect(stored.metaData!.ttl, anyOf(isNull, 0));
      expect(stored.metaData!.expiresAt, isNull,
          reason: 'an expiry is what would actually evict the record');
    });

    test('any OTHER public value is still reported with the 24h ttl', () async {
      // The control, and it has to stay green while the assertions above go
      // red: it is the branch the encryption public key was wrongly falling
      // into, so it proves the carve-out was narrowed to publickey@ rather
      // than widened to everything under cached:public:.
      const String cachedName = 'cached:public:some_other_key.wavi@bob';
      peerAnswers('some_other_key.wavi@bob', remoteValue('some value'));

      final AtData? returned =
          await cacheManager.remoteLookUp(cachedName, maintainCache: true);

      expect(returned!.metaData!.ttl, 24 * 60 * 60 * 1000,
          reason: 'unchanged: only an encryption public key is exempt');
      expect(returned.metaData!.ttr, isNull);
    });
  });
}
