import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Regression coverage for the verifier-bound augmented pol challenge.
///
/// The peer-path challenge issuance and the prover-side abort only fire on the
/// server-to-server handshake, which a unit test cannot drive (FROM's client-
/// certificate check on the peer path, and `OutboundClient.productionMode`
/// gating the sign block). Those paths are covered by the functional/e2e
/// suites. Here we pin down the codec contract the augmented challenge depends
/// on, and prove that the self path (client PKAM/CRAM) is unchanged.
void main() {
  verbTestsSetUpLogging();

  group('verifier-bound pol challenge codec', () {
    test('round-trips the verifier atSign, colon-free and whitespace-free', () {
      final challenge =
          SecondaryUtil.buildBoundPolChallenge('@alice'.toAtsign());
      expect(challenge.startsWith(SecondaryUtil.polChallengeV1Prefix), isTrue);
      // Colon-free so it survives getCookieParams' split(':').
      expect(challenge.contains(':'), isFalse);
      // Whitespace-free so signChallenge's trim() cannot change the signed bytes.
      expect(challenge, challenge.trim());
      expect(SecondaryUtil.verifierOfBoundPolChallenge(challenge),
          '@alice'.toAtsign());
    });

    test('a legacy bare-UUID challenge is reported as unbound (null)', () {
      expect(
          SecondaryUtil.verifierOfBoundPolChallenge(
              '1f2e3d4c-5b6a-7089-90ab-cdef01234567'),
          isNull);
    });

    test('a malformed bound challenge fails closed (FormatException)', () {
      // Not valid base64Url after the prefix.
      expect(
          () => SecondaryUtil.verifierOfBoundPolChallenge('pol1.not*base64*'),
          throwsA(isA<FormatException>()));
      // Well-formed base64Url, but the payload names no verifier.
      final noVerifier = '${SecondaryUtil.polChallengeV1Prefix}'
          '${base64Url.encode(utf8.encode('{"n":"x"}'))}';
      expect(() => SecondaryUtil.verifierOfBoundPolChallenge(noVerifier),
          throwsA(isA<FormatException>()));
    });

    test('a bound challenge naming an invalid atSign fails closed', () {
      // Well-formed base64/JSON, but `v` is not a valid atSign (whitespace),
      // so the .toAtsign() that produces the Atsign throws — fail closed.
      final badVerifier = '${SecondaryUtil.polChallengeV1Prefix}'
          '${base64Url.encode(utf8.encode('{"v":"@bad sign","n":"x"}'))}';
      expect(() => SecondaryUtil.verifierOfBoundPolChallenge(badVerifier),
          throwsA(isA<InvalidAtSignException>()));
    });

    test('the returned verifier is canonicalised (dotted domain / case)', () {
      // A verifier is normally embedded already-canonical, but the decoder
      // canonicalises defensively: a non-canonical `v` in the token comes back
      // in canonical form, so the prover's equality check against the
      // (canonicalised) dialed atSign cannot be tricked by spelling.
      final token = '${SecondaryUtil.polChallengeV1Prefix}'
          '${base64Url.encode(utf8.encode('{"v":"@Colin.Constable","n":"x"}'))}';
      expect(SecondaryUtil.verifierOfBoundPolChallenge(token),
          '@colinconstable'.toAtsign());
    });
  });

  group('FROM challenge issuance', () {
    setUp(() async => await verbTestsSetUp());
    tearDown(() async => await verbTestsTearDown());

    test('self path (client PKAM/CRAM) keeps a bare UUID challenge', () async {
      final handler =
          FromVerbHandler(keyValueStore, accessLog: atAccessLog);
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      final atConnection = InboundConnectionImpl(FakeSocket(), '123');
      final verbParams = HashMap<String, String>()
        ..putIfAbsent('atSign', () => alice);
      final response = Response();

      await handler.processVerb(response, verbParams, atConnection);

      // self path replies with data: and an unbound (bare UUID) challenge.
      expect(response.data!.startsWith('data:'), isTrue);
      final challenge =
          response.data!.substring(response.data!.lastIndexOf(':') + 1);
      expect(SecondaryUtil.verifierOfBoundPolChallenge(challenge), isNull,
          reason: 'PKAM/CRAM self path must remain a bare UUID');
    });
  });
}
