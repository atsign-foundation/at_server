import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_key_guard.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_signing_key.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/keys_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/proxy_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/stats_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_meta_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

// Pins the protections around the atServer's telemetry signing key: only the
// atServer writes the secret or its public record, no verb returns the
// secret, and nothing else may claim the __atserver namespace. Every group
// runs on each keystore backend.
void main() {
  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  for (final AtPersistenceBackendId backend in AtPersistenceBackendId.values) {
    group('${backend.name}:', () {
      setUp(() async {
        await verbTestsSetUp(backend: backend);
      });

      tearDown(() async {
        await verbTestsTearDown();
      });

      telemetryKeyGuardTests();
    });
  }
}

void telemetryKeyGuardTests() {
  const String secretKey = AtServerTelemetryKeyGuard.secretKey;
  final String publicKey = AtServerTelemetryKeyGuard.publicRecordKey('$alice');
  // The record's name as a verb spells it, without public: or the atSign
  const String publicEntity = '_at_telemetry_signing_publickey.__atserver';

  late AtServerTelemetrySigningKey signingKey;
  late String storedSecret;
  late String storedPublicRecord;

  setUp(() async {
    signingKey =
        await AtServerTelemetrySigningKey.loadOrCreate(keyValueStore, '$alice');
    storedSecret = (await keyValueStore.get(secretKey))!.data!;
    storedPublicRecord = (await keyValueStore.get(publicKey))!.data!;
  });

  Future<String> bindEnrollment(Map<String, String> namespaces) async {
    final String enrollmentId = Uuid().v4();
    inboundConnection.metadata
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..enrollmentId = enrollmentId;
    await keyValueStore.put(
      '$enrollmentId.new.enrollments.__manage$alice',
      AtData()
        ..data = jsonEncode(<String, Object?>{
          'sessionId': '123',
          'appName': 'wavi',
          'deviceName': 'pixel',
          'namespaces': namespaces,
          'apkamPublicKey': 'testPublicKeyValue',
          'requestType': 'newEnrollment',
          'approval': <String, String>{'state': 'approved'},
        }),
    );
    return enrollmentId;
  }

  void bindCram() {
    inboundConnection.metadata
      ..isAuthenticated = true
      ..authType = AuthType.cram
      ..enrollmentId = null;
  }

  final Map<String, Future<void> Function()> connections =
      <String, Future<void> Function()>{
    'CRAM': () async => bindCram(),
    'a root enrollment': () =>
        bindEnrollment(<String, String>{'*': 'rw', '__manage': 'rw'}),
    'a *:rw enrollment': () => bindEnrollment(<String, String>{'*': 'rw'}),
    'a scoped enrollment': () => bindEnrollment(<String, String>{'wavi': 'rw'}),
  };

  Future<void> expectUnchanged() async {
    expect((await keyValueStore.get(secretKey))!.data, storedSecret,
        reason: 'the secret must be untouched');
    expect((await keyValueStore.get(publicKey))!.data, storedPublicRecord,
        reason: 'the public record must be untouched');
  }

  group('the signing key', () {
    test('is an Ed25519 seed stored as base64, never as JSON', () {
      expect(base64Decode(storedSecret), hasLength(32));
      expect(() => jsonDecode(storedSecret), throwsFormatException,
          reason: 'keys:get and keys:delete trust an enrollmentId field in '
              'a JSON value');
    });

    test('is reused across boots, and the public record names it', () async {
      final AtServerTelemetrySigningKey again =
          await AtServerTelemetrySigningKey.loadOrCreate(
              keyValueStore, '$alice');
      final AtTelemetryPublicKeyRecord record =
          AtTelemetryPublicKeyRecord.parse(storedPublicRecord);

      expect(again.keyId, signingKey.keyId);
      expect(record.keyId, signingKey.keyId);
      expect(record.publicKey, signingKey.signer.publicKey);
    });

    test('rewrites a public record that does not match the secret', () async {
      await keyValueStore.put(publicKey, AtData()..data = 'planted',
          skipCommit: true);

      await AtServerTelemetrySigningKey.loadOrCreate(keyValueStore, '$alice');

      expect((await keyValueStore.get(publicKey))!.data, storedPublicRecord);
    });

    test('neither record is in the commit log', () async {
      final List<String> served = await _syncedKeys();

      expect(served, isNot(contains(secretKey)));
      expect(served, isNot(contains(publicKey)));
    });
  });

  group('update:json of the secret', () {
    for (final MapEntry<String, Future<void> Function()> connection
        in connections.entries) {
      test('is refused for ${connection.key}', () async {
        await connection.value();
        final String json = jsonEncode(<String, Object?>{
          'atKey': secretKey,
          'value': base64Encode(List<int>.filled(32, 7)),
          'metadata': Metadata().toJson(),
        });

        await expectLater(
          _update().process('update:json:$json', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
        );
        await expectUnchanged();
      });
    }

    test('is refused under another spelling', () async {
      bindCram();
      final String json = jsonEncode(<String, Object?>{
        'atKey': ' PRIVATEKEY:AT_TELEMETRY_SIGNING_PRIVATEKEY',
        'value': 'x',
        'metadata': Metadata().toJson(),
      });

      await expectLater(
        _update().process('update:json:$json', inboundConnection),
        throwsA(isA<UnAuthorizedException>()),
      );
      await expectUnchanged();
    });

    test('CONTROL: CRAM may still write another privatekey: key', () async {
      bindCram();
      final String json = jsonEncode(<String, Object?>{
        'atKey': 'privatekey:self_encryption_key',
        'value': 'ORDINARY',
        'metadata': Metadata().toJson(),
      });

      await _update().process('update:json:$json', inboundConnection);

      expect((await keyValueStore.get('privatekey:self_encryption_key'))!.data,
          'ORDINARY');
    });
  });

  group('keys:get and keys:delete naming the secret', () {
    for (final String operation in <String>['get', 'delete']) {
      for (final MapEntry<String, Future<void> Function()> connection
          in connections.entries) {
        if (connection.key == 'CRAM') {
          continue;
        }
        test('keys:$operation is refused for ${connection.key}', () async {
          await connection.value();

          await expectLater(
            KeysVerbHandler(keyValueStore, enMgr, alice).process(
                'keys:$operation:keyName:$secretKey', inboundConnection),
            throwsA(isA<UnAuthorizedException>()),
          );
          expect(inboundConnection.lastWrittenData ?? '',
              isNot(contains(storedSecret)));
          await expectUnchanged();
        });
      }
    }

    test('are refused even when the stored value names the enrollment',
        () async {
      final String enrollmentId =
          await bindEnrollment(<String, String>{'*': 'rw', '__manage': 'rw'});
      final String planted = jsonEncode(<String, Object?>{
        AtConstants.enrollmentId: enrollmentId,
        'value': 'planted',
      });
      await keyValueStore.put(secretKey, AtData()..data = planted,
          skipCommit: true);

      for (final String operation in <String>['get', 'delete']) {
        await expectLater(
          KeysVerbHandler(keyValueStore, enMgr, alice)
              .process('keys:$operation:keyName:$secretKey', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'keys:$operation trusts an enrollmentId in a JSON value, '
              'so only the guard on the name refuses it',
        );
      }
      expect((await keyValueStore.get(secretKey))!.data, planted);
    });

    test('keys:delete of the public record is refused', () async {
      await bindEnrollment(<String, String>{'*': 'rw', '__manage': 'rw'});

      await expectLater(
        KeysVerbHandler(keyValueStore, enMgr, alice)
            .process('keys:delete:keyName:$publicKey', inboundConnection),
        throwsA(isA<UnAuthorizedException>()),
      );
      await expectUnchanged();
    });
  });

  group('no read verb returns the secret', () {
    final Map<String, Future<void> Function()> reads =
        <String, Future<void> Function()>{
      'scan:showhidden:true': () => ScanVerbHandler(
              keyValueStore, mockOutboundClientManager, cacheManager)
          .process('scan:showhidden:true', inboundConnection),
      'llookup': () => LocalLookupVerbHandler(keyValueStore, enMgr)
          .process('llookup:$secretKey$alice', inboundConnection),
      'llookup:all': () => LocalLookupVerbHandler(keyValueStore, enMgr)
          .process('llookup:all:$secretKey$alice', inboundConnection),
      'lookup': () => LookupVerbHandler(
              keyValueStore, mockOutboundClientManager, cacheManager, enMgr,
              accessLog: atAccessLog)
          .process('lookup:all:$secretKey$alice', inboundConnection),
      'plookup': () => ProxyLookupVerbHandler(
              keyValueStore, mockOutboundClientManager, cacheManager,
              accessLog: atAccessLog)
          .process('plookup:all:$secretKey$alice', inboundConnection),
      'stats:3': () =>
          StatsVerbHandler(keyValueStore).process('stats:3', inboundConnection),
    };

    for (final MapEntry<String, Future<void> Function()> connection
        in connections.entries) {
      for (final MapEntry<String, Future<void> Function()> read
          in reads.entries) {
        test('${read.key} over ${connection.key}', () async {
          await connection.value();
          inboundConnection.lastWrittenData = null;

          try {
            await read.value();
          } on Object {
            // Refusing is as good as not finding it
          }

          expect(inboundConnection.lastWrittenData ?? '',
              isNot(contains(storedSecret)));
          expect(inboundConnection.lastWrittenData ?? '',
              isNot(contains(secretKey)),
              reason: 'scan and stats print key names, never values, so '
                  'only the name shows whether they reach the secret');
        });
      }

      test('sync:from over ${connection.key}', () async {
        await connection.value();

        expect(await _syncedKeys(), isNot(contains(secretKey)));
      });
    }
  });

  group('the public record', () {
    final Map<String, String Function()> writes = <String, String Function()>{
      'update': () => 'update:public:$publicEntity$alice planted',
      'update:json with isPublic': () =>
          'update:json:${jsonEncode(<String, Object?>{
                'atKey': '$publicEntity$alice',
                'value': 'planted',
                'metadata': (Metadata()..isPublic = true).toJson(),
              })}',
      'update:json with the full name': () =>
          'update:json:${jsonEncode(<String, Object?>{
                'atKey': publicKey,
                'value': 'planted',
                'metadata': Metadata().toJson(),
              })}',
      'update:meta': () => 'update:meta:public:$publicEntity$alice:ttl:1000',
      'delete': () => 'delete:public:$publicEntity$alice',
      'notify': () => 'notify:update:@bob:public:$publicEntity$alice:planted',
    };

    for (final MapEntry<String, Future<void> Function()> connection
        in connections.entries) {
      for (final MapEntry<String, String Function()> write in writes.entries) {
        test('${write.key} is refused for ${connection.key}', () async {
          await connection.value();
          final String command = write.value();

          await expectLater(
            _handlerFor(command).process(command, inboundConnection),
            throwsA(isA<UnAuthorizedException>()),
          );
          await expectUnchanged();
        });
      }
    }

    test('an unauthenticated lookup returns it', () async {
      inboundConnection.metadata
        ..isAuthenticated = false
        ..enrollmentId = null;

      await LookupVerbHandler(
              keyValueStore, mockOutboundClientManager, cacheManager, enMgr,
              accessLog: atAccessLog)
          .process('lookup:$publicEntity$alice', inboundConnection);

      final String data = inboundConnection.lastWrittenData!
          .substring('data:'.length)
          .split('\n')
          .first;
      final AtTelemetryPublicKeyRecord record =
          AtTelemetryPublicKeyRecord.parse(data);
      expect(record.keyId, signingKey.keyId);
      expect(record.publicKey, signingKey.signer.publicKey);
    });

    test('scan does not list it', () async {
      bindCram();

      await ScanVerbHandler(
              keyValueStore, mockOutboundClientManager, cacheManager)
          .process('scan', inboundConnection);

      expect(inboundConnection.lastWrittenData, isNot(contains(publicEntity)));
    });
  });

  group('enrollments naming __atserver', () {
    for (final String namespace in <String>[
      '__atserver',
      '__ATSERVER',
      'evil.__atserver',
    ]) {
      test('enroll:request for "$namespace" is refused over CRAM', () async {
        bindCram();
        inboundConnection.metadata.sessionID = 'session';
        final String request = 'enroll:request:{"appName":"wavi",'
            '"deviceName":"pixel","namespaces":{"$namespace":"rw"},'
            '"apkamPublicKey":"key-${Uuid().v4()}"}';

        await expectLater(
          _enroll().processVerb(Response(),
              getVerbParam(VerbSyntax.enroll, request), inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
        );
      });
    }

    test('enroll:request for "__atserver" is refused over APKAM', () async {
      await bindEnrollment(<String, String>{'*': 'rw', '__manage': 'rw'});
      inboundConnection.metadata.sessionID = 'session';
      final String request = 'enroll:request:{"appName":"wavi",'
          '"deviceName":"pixel","namespaces":{"wavi":"r","__atserver":"rw"},'
          '"apkamPublicKey":"key-${Uuid().v4()}"}';

      await expectLater(
        _enroll().processVerb(Response(),
            getVerbParam(VerbSyntax.enroll, request), inboundConnection),
        throwsA(isA<UnAuthorizedException>()),
      );
    });

    test('approving a stored request naming __atserver is refused over CRAM',
        () async {
      final String pendingId = Uuid().v4();
      await keyValueStore.put(
        enMgr.buildEnrollmentKey(pendingId),
        AtData()
          ..data = jsonEncode(<String, Object?>{
            'sessionId': '123',
            'appName': 'wavi',
            'deviceName': 'pixel',
            'namespaces': <String, String>{'__atserver': 'rw'},
            'apkamPublicKey': 'key-$pendingId',
            'requestType': 'newEnrollment',
            'approval': <String, String>{'state': 'pending'},
          }),
      );
      bindCram();
      final String approve = 'enroll:approve:{"enrollmentId":"$pendingId",'
          '"encryptedDefaultEncryptionPrivateKey":"x",'
          '"encryptedDefaultSelfEncryptionKey":"y"}';

      await expectLater(
        _enroll().processVerb(Response(),
            getVerbParam(VerbSyntax.enroll, approve), inboundConnection),
        throwsA(isA<UnAuthorizedException>()),
      );
      expect(
        (await enMgr.getEnrollmentById(pendingId)).approval!.state,
        'pending',
      );
    });

    test('CONTROL: an ordinary CRAM enroll:request still works', () async {
      bindCram();
      inboundConnection.metadata.sessionID = 'session';
      final Response response = Response();
      final String request = 'enroll:request:{"appName":"wavi",'
          '"deviceName":"pixel","namespaces":{"wavi":"rw"},'
          '"apkamPublicKey":"key-${Uuid().v4()}"}';

      await _enroll().processVerb(response,
          getVerbParam(VerbSyntax.enroll, request), inboundConnection);

      expect(jsonDecode(response.data!)['enrollmentId'], isNotEmpty);
    });
  });

  group('keys:put', () {
    for (final String namespace in <String>[
      '__atserver',
      '__ATSERVER',
    ]) {
      test('into "$namespace" is refused', () async {
        await bindEnrollment(<String, String>{'*': 'rw', '__manage': 'rw'});

        await expectLater(
          KeysVerbHandler(keyValueStore, enMgr, alice).process(
              'keys:put:public:namespace:$namespace:keyType:rsa2048:'
              'keyName:_at_telemetry_signing_publickey planted',
              inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
        );
        await expectUnchanged();
      });
    }

    test('CONTROL: into __global still works', () async {
      await bindEnrollment(<String, String>{'*': 'rw', '__manage': 'rw'});

      await KeysVerbHandler(keyValueStore, enMgr, alice).process(
          'keys:put:public:namespace:__global:keyType:rsa2048:'
          'keyName:encryption_self value',
          inboundConnection);

      expect(inboundConnection.lastWrittenData, startsWith('data:'));
    });
  });

  group('the keystore', () {
    test('accepts both reserved names', () async {
      expect(await keyValueStore.exists(secretKey), isTrue);
      expect(await keyValueStore.exists(publicKey), isTrue);
    });

    for (final String nearMiss in <String>[
      'privatekey:at_telemetry_signing_privatekeyx',
      'privatekey:at_telemetry_signing_private_key',
      'privatekey:at_telemetry_signing_privatekey.wavi',
    ]) {
      test('refuses the near miss $nearMiss', () async {
        await expectLater(
          keyValueStore.put(nearMiss, AtData()..data = 'x'),
          throwsA(isA<InvalidAtKeyException>()),
        );
      });
    }

    test('the guard ignores near misses of the public record', () {
      expect(
        AtServerTelemetryKeyGuard.isTelemetryKey(
            'public:_at_telemetry_signing_publickey.wavi$alice'),
        isFalse,
      );
      expect(
        AtServerTelemetryKeyGuard.isTelemetryKey(
            '@bob:_at_telemetry_signing_publickey.__atserver$alice'),
        isFalse,
      );
      expect(AtServerTelemetryKeyGuard.isTelemetryKey(' $publicKey '), isTrue);
    });
  });
}

UpdateVerbHandler _update() => UpdateVerbHandler(
    keyValueStore, statsNotificationService, notificationManager, alice);

EnrollVerbHandler _enroll() =>
    EnrollVerbHandler(keyValueStore, enMgr, notificationManager);

AbstractVerbHandler _handlerFor(String command) {
  if (command.startsWith('update:meta:')) {
    return UpdateMetaVerbHandler(
        keyValueStore, statsNotificationService, notificationManager, alice);
  }
  if (command.startsWith('update:')) {
    return _update();
  }
  if (command.startsWith('delete:')) {
    return DeleteVerbHandler(
        keyValueStore, statsNotificationService, notificationManager);
  }
  return NotifyVerbHandler(keyValueStore, notificationManager);
}

Future<List<String>> _syncedKeys() async {
  final Response response = Response();
  final HashMap<String, String> params = HashMap<String, String>()
    ..[AtConstants.fromCommitSequence] = '-1'
    ..[AtConstants.syncLimit] = '100';
  await SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog)
      .processVerb(response, params, inboundConnection);
  return <String>[
    for (final Object? entry in jsonDecode(response.data ?? '[]') as List)
      (entry! as Map<String, Object?>)['atKey']! as String,
  ];
}
