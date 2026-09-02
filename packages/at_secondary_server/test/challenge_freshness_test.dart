import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops.dart' show MlDsa65PureDartAlgo;
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/cram_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// The per-connection challenge `from:` issues is a ONE-SHOT, TIME-BOUND
/// credential, and these pin both halves of that at the two places a unit test
/// can drive the full handshake.
///
/// Neither half used to hold. The challenge was removed only on the success
/// path, so a caller could present signature after signature against a single
/// `from:` until one verified; and no verifier asked whether the record was
/// still live, so the 60-second ttl `from:` stamps was enforced by nothing but
/// a background sweep running on its own schedule — a challenge hours past its
/// `expiresAt` still authenticated.
///
/// `pol` shares the same shared helper and therefore the same two properties.
/// Its handler cannot be driven from a unit test (it needs the outbound
/// server-to-server path), so it is pinned here at the helper and end-to-end
/// in the functional pack.
void main() {
  verbTestsSetUpLogging();

  group('consumeChallenge — the mechanism all three verifiers share', () {
    setUp(() async => await verbTestsSetUp());
    tearDown(() async => await verbTestsTearDown());

    test('returns a live challenge, and spends it', () async {
      final handler = PkamVerbHandler(keyValueStore);
      await keyValueStore.put('private:live$alice',
          AtData()..data = 'the-proof'..metaData = (AtMetaData()..ttl = 60000));

      expect(await handler.consumeChallenge('private:live$alice'), 'the-proof',
          reason: 'a live challenge is honoured exactly once');
      expect(await keyValueStore.exists('private:live$alice'), isFalse,
          reason: 'and is gone afterwards — one challenge, one attempt');
    });

    test('refuses an EXPIRED challenge, and still spends it', () async {
      final handler = PkamVerbHandler(keyValueStore);
      final past = DateTime.now().toUtc().subtract(Duration(hours: 2));
      await keyValueStore.put('private:stale$alice',
          AtData()..data = 'the-proof'..metaData = (AtMetaData()..expiresAt = past));

      // Fixture control: the record must actually BE expired, or the
      // assertion below would pass for a record that simply is not there.
      final stored = await keyValueStore.get('private:stale$alice');
      expect(stored, isNotNull, reason: 'the fixture stored something');
      expect(SecondaryUtil.isActiveKey(stored), isFalse,
          reason: 'and what it stored is genuinely expired — otherwise this '
              'test would be asserting nothing about expiry');

      expect(await handler.consumeChallenge('private:stale$alice'), isNull,
          reason: 'expiry is a reader-side rule in this server: no keystore '
              'backend filters on read, so a verifier that does not ask is a '
              'verifier for which the ttl does not exist');
      expect(await keyValueStore.exists('private:stale$alice'), isFalse,
          reason: 'a refused challenge is spent too');
    });

    test('returns null for a challenge that was never issued', () async {
      final handler = PkamVerbHandler(keyValueStore);
      expect(await handler.consumeChallenge('private:never$alice'), isNull);
    });
  });

  group('pkam spends its challenge', () {
    setUp(() async => await verbTestsSetUp());
    tearDown(() async => await verbTestsTearDown());

    /// Seeds the flat credential and returns a signer over its secret key.
    Future<
        (
          Future<void> Function(String sessionId, String challenge),
          Future<String> Function(String sessionId, String challenge),
        )> seedFlatCredential() async {
      final mlDsa = await MlDsa65PureDartAlgo().generateKeyPair();
      await keyValueStore.put(AtConstants.atPkamPublicKey,
          AtData()..data = base64Encode(mlDsa.publicKey),
          skipCommit: true);
      Future<void> issue(String sessionId, String challenge) async =>
          await keyValueStore.put(
              'private:$sessionId$alice',
              AtData()
                ..data = challenge
                ..metaData = (AtMetaData()..ttl = 60000));
      Future<String> sign(String sessionId, String challenge) async =>
          base64Encode(await MlDsa65PureDartAlgo().signBytes(
              Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')),
              secretKey: mlDsa.secretKey));
      return (issue, sign);
    }

    Future<Response> attempt(String sessionId, String signature) async {
      inboundConnection.metaData
        ..isAuthenticated = false
        ..enrollmentId = null
        ..sessionID = sessionId;
      final r = Response();
      await PkamVerbHandler(keyValueStore).processVerb(
        r,
        getVerbParam(
            VerbSyntax.pkam, 'pkam:signingAlgo:mldsa65:$signature'),
        inboundConnection,
      );
      return r;
    }

    test('a WRONG signature spends the challenge, so the right one that '
        'follows is refused', () async {
      final (issue, sign) = await seedFlatCredential();
      const sessionId = 'retry-oracle';
      const challenge = 'a-per-connection-challenge';
      await issue(sessionId, challenge);

      final good = await sign(sessionId, challenge);
      final bad = base64Encode(
          Uint8List.fromList(base64Decode(good))..[0] ^= 0xff);

      // Positive control: the good signature is genuinely good — proven
      // below by the fact that it authenticates once the challenge is
      // reissued. Without it, the refusal we assert could be a bad signature.
      await expectLater(() => attempt(sessionId, bad),
          throwsA(isA<UnAuthenticatedException>()),
          reason: 'a tampered signature is refused');

      await expectLater(
          () => attempt(sessionId, good),
          throwsA(isA<UnAuthenticatedException>()),
          reason: 'and the failed attempt SPENT the challenge, so even a '
              'correct signature over it no longer authenticates — a '
              'challenge that survived its own failed use would be a retry '
              'oracle bounded only by the ttl');

      // The positive control fires: reissue and the same signature works.
      await issue(sessionId, challenge);
      expect((await attempt(sessionId, good)).data, 'success',
          reason: 'the signature refused above was correct all along; what '
              'refused it was the spent challenge, not the signature');
    });

    test('an EXPIRED challenge is refused even with a valid signature',
        () async {
      final (_, sign) = await seedFlatCredential();
      const sessionId = 'stale-session';
      const challenge = 'a-per-connection-challenge';
      final past = DateTime.now().toUtc().subtract(Duration(hours: 2));
      await keyValueStore.put(
          'private:$sessionId$alice',
          AtData()
            ..data = challenge
            ..metaData = (AtMetaData()..expiresAt = past));

      // Fixture control, as above.
      expect(
          SecondaryUtil.isActiveKey(
              await keyValueStore.get('private:$sessionId$alice')),
          isFalse,
          reason: 'the challenge under test is genuinely expired');

      final good = await sign(sessionId, challenge);
      await expectLater(() => attempt(sessionId, good),
          throwsA(isA<UnAuthenticatedException>()),
          reason: 'the 60-second bound from: stamps has to be enforced by the '
              'verifier; nothing else reads it in time');

      // Positive control: the same signature over a LIVE challenge works, so
      // what refused above was the expiry and not the signature.
      await keyValueStore.put(
          'private:$sessionId$alice',
          AtData()
            ..data = challenge
            ..metaData = (AtMetaData()..ttl = 60000));
      expect((await attempt(sessionId, good)).data, 'success',
          reason: 'same signature, same challenge value — only the expiry '
              'differed');
    });
  });

  group('cram spends its challenge', () {
    late AtKeyValueStore<String, AtData, AtMetaData?> store;
    late FakeSocket socket;
    const secret =
        'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43b'
        'c55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';

    setUp(() async {
      await verbTestsSetUp();
      store = keyValueStore;
      socket = FakeSocket();
      await store.put('privatekey:at_secret', AtData()..data = secret);
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
    });
    tearDown(() async => await verbTestsTearDown());

    /// Runs `from:` and returns (connection, the challenge it issued).
    Future<(InboundConnectionImpl, String)> issue(String sessionId) async {
      final connection = InboundConnectionImpl(socket, sessionId);
      final response = Response();
      await FromVerbHandler(store, commitLog: atCommitLog, accessLog: atAccessLog)
          .processVerb(
              response,
              HashMap<String, String>()
                ..putIfAbsent('atSign', () => alice.toString().substring(1)),
              connection);
      return (
        connection,
        response.data!.replaceFirst(RegExp('^data:'), ''),
      );
    }

    Future<Response> digestAttempt(
        InboundConnectionImpl connection, String proof) async {
      final r = Response();
      await CramVerbHandler(store, accessLog: atAccessLog).processVerb(
          r,
          HashMap<String, String>()
            ..putIfAbsent(
                'digest',
                () => sha512.convert(utf8.encode('$secret$proof')).toString()),
          connection);
      return r;
    }

    test('a WRONG digest spends the challenge, so the right one that follows '
        'is refused', () async {
      final (connection, proof) = await issue('_cram-retry-oracle');

      await expectLater(() => digestAttempt(connection, 'not-the-proof'),
          throwsA(isA<UnAuthenticatedException>()),
          reason: 'a wrong digest is refused');
      expect((connection.metaData as InboundConnectionMetadata).isAuthenticated,
          isFalse);

      await expectLater(() => digestAttempt(connection, proof),
          throwsA(isA<UnAuthenticatedException>()),
          reason: 'and the failed attempt spent the challenge — otherwise one '
              'from: buys unlimited guesses at the CRAM secret, which is the '
              'registrar activation credential');
    });

    test('an EXPIRED challenge is refused even with the right digest',
        () async {
      final (connection, proof) = await issue('_cram-stale');
      final storedSecretId = 'private:_cram-stale$alice';
      // Fixture control: this is the record `from:` actually wrote. Guessing
      // the id wrong would age nothing, leave the real challenge live, and
      // make the refusal below mean something else entirely.
      final issued = await store.get(storedSecretId);
      expect(issued, isNotNull,
          reason: 'from: stored the challenge where this test ages it');

      // Age it, keeping its value byte-for-byte.
      final past = DateTime.now().toUtc().subtract(Duration(hours: 2));
      await store.put(
          storedSecretId,
          AtData()
            ..data = issued!.data
            ..metaData = (AtMetaData()..expiresAt = past));
      expect(SecondaryUtil.isActiveKey(await store.get(storedSecretId)), isFalse,
          reason: 'the challenge under test is genuinely expired');

      await expectLater(() => digestAttempt(connection, proof),
          throwsA(isA<UnAuthenticatedException>()),
          reason: 'the ttl has to bite on the CRAM path too');

      // Positive control: the identical digest over a LIVE challenge works.
      await store.put(
          storedSecretId,
          AtData()
            ..data = issued.data
            ..metaData = (AtMetaData()..ttl = 60000));
      expect((await digestAttempt(connection, proof)).data, 'success',
          reason: 'same digest, same proof — only the expiry differed');
    });
  });
}
