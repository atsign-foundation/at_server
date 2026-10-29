import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/keys_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// A keystore whose reads are recorded and stubbed per test.
class _ReadRecordingStore extends Mock
    implements AtKeyValueStore<String, AtData, AtMetaData?> {}

/// Scenarios: features/enrollment/keys_verb_own_encryption_keys.feature
void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  final etu = ETU();
  late KeysVerbHandler keysVerbHandler;

  setUp(() async {
    await verbTestsSetUp();
    await etu.init();
    keysVerbHandler = KeysVerbHandler(keyValueStore, enMgr, alice);
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  /// The values ETU's enroll:approve stores for every enrollment it approves.
  const String storedPrivateKey = 'encrypted default encryption private key';
  const String storedSelfKey = 'encrypted default self encryption key';

  /// An enrollment approved through enroll:approve, which stores its two
  /// keys, with the connection then authenticated as it.
  Future<String> approvedAndConnected(String name) async {
    inboundConnection.metadata.enrollmentId = etu.primaryEnId;
    final String id = await etu.createPendingEnrollment(
        appName: name,
        deviceName: 'device',
        namespaces: {'wavi': 'rw'},
        apkamKeysExpiryDuration: null);
    await etu.approveEnrollment(etu.primaryEnId, id);
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam;
    inboundConnection.metadata.enrollmentId = id;
    return id;
  }

  String privateKeyOf(String id) =>
      '$id.default_enc_private_key.__manage$alice';
  String selfKeyOf(String id) => '$id.default_self_enc_key.__manage$alice';

  String dataWritten() {
    final String written = inboundConnection.lastWrittenData!;
    return written.substring('data:'.length, written.indexOf('\n'));
  }

  Future<List<String>> storedKeys() async =>
      (await (await keyValueStore.getKeys()).toList())..sort();

  group('An enrollment reads its own encryption key by keyName', () {
    test('encryption private key', () async {
      final e = await approvedAndConnected('e');

      await keysVerbHandler.process(
          'keys:get:keyName:${privateKeyOf(e)}', inboundConnection);

      expect(jsonDecode(dataWritten())['value'], storedPrivateKey);
    });

    test('self encryption key', () async {
      final e = await approvedAndConnected('e');

      await keysVerbHandler.process(
          'keys:get:keyName:${selfKeyOf(e)}', inboundConnection);

      expect(jsonDecode(dataWritten())['value'], storedSelfKey);
    });
  });

  group(
      'Every other keys: request is refused before the store is read or '
      'written', () {
    final Map<String, String Function(String e, String f)> requests = {
      'keys:put:public': (e, f) => 'keys:put:public:namespace:__global:'
          'keyType:rsa2048:keyName:encryption_$e planted',
      'keys:put:self': (e, f) => 'keys:put:self:namespace:__global:'
          'appName:wavi:deviceName:pixel:keyType:aes256:'
          'encryptionKeyName:encryption_$e:keyName:myAESkey planted',
      'keys:put:private': (e, f) => 'keys:put:private:namespace:__global:'
          'appName:wavi:deviceName:pixel:keyType:aes:'
          'encryptionKeyName:myAESkey:keyName:myPrivateKey planted',
      'keys:put of __nskey': (e, f) =>
          'keys:put:public:namespace:app:keyName:__nskey planted',
      'keys:delete of its own key': (e, f) =>
          'keys:delete:keyName:${privateKeyOf(e)}',
      'keys:get:private': (e, f) => 'keys:get:private',
      'keys:get:self': (e, f) => 'keys:get:self',
      'keys:get:public': (e, f) => 'keys:get:public',
      "keys:get of enrollment F's key": (e, f) =>
          'keys:get:keyName:${privateKeyOf(f)}',
      'keys:get of the CRAM secret': (e, f) =>
          'keys:get:keyName:privatekey:at_secret',
      'keys:get with a visibility': (e, f) =>
          'keys:get:self:keyName:${selfKeyOf(e)}',
      'keys:get with a namespace': (e, f) =>
          'keys:get:namespace:__global:keyName:${selfKeyOf(e)}',
      'keys:get with a value': (e, f) =>
          'keys:get:keyName:${privateKeyOf(e)} planted',
    };
    for (final MapEntry(key: String label, value: build) in requests.entries) {
      test(label, () async {
        final f = await approvedAndConnected('f');
        final e = await approvedAndConnected('e');
        await keyValueStore.put(
            'privatekey:at_secret', AtData()..data = 'cram secret');
        final List<String> before = await storedKeys();

        await expectLater(
            keysVerbHandler.process(build(e, f), inboundConnection),
            throwsA(isA<UnAuthorizedException>()));

        expect(await storedKeys(), before,
            reason: 'nothing is stored or deleted');
        expect(inboundConnection.lastWrittenData ?? '',
            isNot(contains('encrypted default')),
            reason: 'nothing is listed or answered');
      });
    }
  });

  test('A connection carrying no enrollment id is refused', () async {
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.cram;
    inboundConnection.metadata.enrollmentId = null;
    final List<String> before = await storedKeys();

    await expectLater(
        keysVerbHandler.process(
            'keys:get:keyName:${selfKeyOf(etu.primaryEnId)}',
            inboundConnection),
        throwsA(isA<AtEnrollmentException>().having((e) => e.message, 'message',
            'Keys verb cannot be accessed without an enrollmentId')));
    expect(await storedKeys(), before);
  });

  group('A connection whose enrollment record is missing', () {
    late _ReadRecordingStore store;
    late KeysVerbHandler handler;

    setUp(() {
      store = _ReadRecordingStore();
      when(() => store.get(any())).thenAnswer((invocation) =>
          keyValueStore.get(invocation.positionalArguments.single as String));
      handler = KeysVerbHandler(store, enMgr, alice);
    });

    // NOTE processVerb, not process: process closes a connection whose
    // enrollment has no record before any handler runs.
    Future<Response> keysGet(String keyName) async {
      final Response response = Response();
      await handler.processVerb(response,
          handler.parse('keys:get:keyName:$keyName'), inboundConnection);
      return response;
    }

    test('is answered while its record is present', () async {
      final e = await approvedAndConnected('e');

      final Response response = await keysGet(selfKeyOf(e));

      expect(jsonDecode(response.data!)['value'], storedSelfKey);
      verify(() => store.get(enMgr.keyForSEK(e))).called(1);
    });

    test('is refused before the key is read', () async {
      final e = await approvedAndConnected('e');
      await keyValueStore.remove(enMgr.buildEnrollmentKey(e), skipCommit: true);
      final List<String> before = await storedKeys();

      await expectLater(
          keysGet(selfKeyOf(e)), throwsA(isA<UnAuthorizedException>()));

      verifyNever(() => store.get(any()));
      expect(await storedKeys(), before,
          reason: 'nothing is stored or deleted');
    });
  });

  test('A legacy pkam: connection finds no encryption key', () async {
    await enMgr
        .serialiseMutation(() => enMgr.mintPrimary('legacy pkam public key'));
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.pkamLegacy;
    inboundConnection.metadata.enrollmentId =
        EnrollmentManager.primaryEnrollmentId;

    await expectLater(
        keysVerbHandler.process(
            'keys:get:keyName:${privateKeyOf('primary')}', inboundConnection),
        throwsA(isA<KeyNotFoundException>()));
  });

  test(
      'A refused request from an enrollment that is not approved is refused '
      'for its form', () async {
    inboundConnection.metadata.enrollmentId = etu.primaryEnId;
    final String e = await etu.createPendingEnrollment(
        appName: 'e',
        deviceName: 'device',
        namespaces: {'wavi': 'rw'},
        apkamKeysExpiryDuration: null);
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam;
    inboundConnection.metadata.enrollmentId = e;

    // NOTE processVerb, not process: process refuses an enrollment that is
    // not approved before any handler runs.
    await expectLater(
        keysVerbHandler.processVerb(
            Response(),
            keysVerbHandler.parse('keys:put:public:namespace:__global:'
                'keyType:rsa2048:keyName:encryption_$e planted'),
            inboundConnection),
        throwsA(isA<UnAuthorizedException>()));
  });

  test('an enrollment that is not approved is refused its own key', () async {
    inboundConnection.metadata.enrollmentId = etu.primaryEnId;
    final String e = await etu.createPendingEnrollment(
        appName: 'e',
        deviceName: 'device',
        namespaces: {'wavi': 'rw'},
        apkamKeysExpiryDuration: null);
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam;
    inboundConnection.metadata.enrollmentId = e;

    // NOTE processVerb, not process: process refuses an enrollment that is
    // not approved before any handler runs.
    await expectLater(
        keysVerbHandler.processVerb(
            Response(),
            keysVerbHandler.parse('keys:get:keyName:${selfKeyOf(e)}'),
            inboundConnection),
        throwsA(isA<AtEnrollmentException>()
            .having((e) => e.message, 'message', contains('is not approved'))));
  });

  test('a keyName naming its own key in another case names the same key',
      () async {
    final e = await approvedAndConnected('e');

    await keysVerbHandler.process(
        'keys:get:keyName:${selfKeyOf(e).toUpperCase()}', inboundConnection);

    expect(jsonDecode(dataWritten())['value'], storedSelfKey);
  });

  test('an approved enrollment whose key is not stored is told so', () async {
    final e = await approvedAndConnected('e');
    await keyValueStore.remove(enMgr.keyForPEK(e), skipCommit: true);

    await expectLater(
        keysVerbHandler.process(
            'keys:get:keyName:${privateKeyOf(e)}', inboundConnection),
        throwsA(isA<KeyNotFoundException>().having((e) => e.message, 'message',
            'key ${enMgr.keyForPEK(e)} not found in keystore')));
  });

  test('keys verb invalid syntax - invalid operation', () {
    expect(() => getVerbParam(Keys().syntax(), 'keys:update:hello'),
        throwsA(isA<InvalidSyntaxException>()));
  });

  test('keys verb without an operation is invalid syntax', () {
    expect(
        () => getVerbParam(
            Keys().syntax(),
            'keys:public:namespace:__global:keyType:rsa2048:'
            'keyName:encryption_1278383933 testPublicKeyValue'),
        throwsA(isA<InvalidSyntaxException>()));
  });

  for (final String command in [
    'keys:put:public:namespace:__global:keyType:rsa2048:'
        'keyName:encryption_1278383933 testPublicKeyValue',
    'keys:get:keyName:anything',
    'keys:delete:keyName:anything',
  ]) {
    test('$command without authentication is refused as unauthenticated',
        () async {
      inboundConnection.metaData.isAuthenticated = false;
      await expectLater(keysVerbHandler.process(command, inboundConnection),
          throwsA(isA<UnAuthenticatedException>()));
    });
  }
}
