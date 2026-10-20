import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/reserved_namespace.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:test/test.dart';

import 'atsign_bound_harness.dart';
import 'test_utils.dart';

/// Catalogue: features/keys/reserved_namespace_records.feature
void main() {
  setUpAll(() async => await verbTestsSetUpAll());
  setUp(() async => await setUpAtSignBound());
  tearDown(() async => await verbTestsTearDown());

  /// A client of @alice on a connection that is enrollment [id], approved
  /// with [namespaces], authenticated by [authType].
  Future<Connection> enrolled(String id, Map<String, String> namespaces,
      {AuthType authType = AuthType.apkam}) async {
    await keyValueStore.put(
        '$id.new.enrollments.__manage$alice',
        AtData()
          ..data = jsonEncode({
            'sessionId': '123',
            'appName': 'wavi',
            'deviceName': 'pixel',
            'namespaces': namespaces,
            'apkamPublicKey': 'x',
            'requestType': 'newEnrollment',
            'approval': {'state': 'approved'}
          }));
    return Connection(InboundConnectionMetadata()
      ..isAuthenticated = true
      ..authType = authType
      ..enrollmentId = id);
  }

  Future<Connection> cram() async => aliceClient();
  Future<Connection> pkam() async =>
      enrolled('primary', {'*': 'rw', '__manage': 'rw'},
          authType: AuthType.pkamLegacy);
  Future<Connection> starRw() async => enrolled('e9', {'*': 'rw'});
  Future<Connection> e1() async => enrolled('e1', {'wavi': 'rw'});

  Future<String?> valueOf(String key) async =>
      (await keyValueStore.get(key))?.data;

  group(
      "An atSign's own client may not change a record in a reserved "
      'namespace', () {
    for (final (
          String auth,
          Future<Connection> Function() connect,
          String command,
          String record,
          String refusal
        ) in [
      (
        'cram',
        cram,
        'update:e1.new.enrollments.__manage@alice {"appName":"x"}',
        'e1.new.enrollments.__manage@alice',
        'Record in reserved namespace'
      ),
      (
        'cram',
        cram,
        'update:e1.default_enc_private_key.__manage@alice k',
        'e1.default_enc_private_key.__manage@alice',
        'Record in reserved namespace'
      ),
      (
        'pkam',
        pkam,
        'update:x.__global@alice v',
        'x.__global@alice',
        'Record in reserved namespace'
      ),
      (
        'apkam as an enrollment holding *:rw',
        starRw,
        'update:x.__private@alice v',
        'x.__private@alice',
        'Record in reserved namespace'
      ),
      (
        'apkam as an enrollment holding *:rw',
        starRw,
        'update:x.__config@alice v',
        'x.__config@alice',
        'Record in reserved namespace'
      ),
      (
        'apkam as an enrollment holding *:rw',
        starRw,
        'update:public:x.__foo@alice v',
        'public:x.__foo@alice',
        'Record in reserved namespace'
      ),
      (
        'apkam as an enrollment holding *:rw',
        starRw,
        'update:@bob:x.__global@alice v',
        '@bob:x.__global@alice',
        'Record in reserved namespace'
      ),
      (
        'apkam as an enrollment holding *:rw',
        starRw,
        'update:meta:x.__global@alice:ttl:1000',
        'x.__global@alice',
        'Record in reserved namespace'
      ),
      (
        'apkam as an enrollment holding *:rw',
        starRw,
        'delete:x.__global@alice',
        'x.__global@alice',
        'Record in reserved namespace'
      ),
      (
        'apkam as enrollment e1',
        e1,
        'update:x.e2.a.__e@alice v',
        'x.e2.a.__e@alice',
        'is not authorized to update key'
      ),
      (
        'cram',
        cram,
        'update:json:{"atKey":"x.new.enrollments.__manage@bob","value":"v",'
            '"metadata":{"isPublic":false,"isBinary":false,'
            '"isEncrypted":false}}',
        'x.new.enrollments.__manage@bob',
        'Record in reserved namespace'
      ),
      (
        'cram',
        cram,
        'delete:1700000000000000.events.__atserver@alice',
        '1700000000000000.events.__atserver@alice',
        'Record in reserved namespace'
      ),
    ]) {
      test('$auth, $command', () async {
        await keyValueStore.put(record, AtData()..data = 'before');
        final Connection client = await connect();

        await send(command, client);

        expect(client.writes.first, startsWith('error:AT0009'));
        expect(client.writes.first, contains(refusal));
        expect(await valueOf(record), 'before',
            reason: 'the record is unchanged');
        expect((await keyValueStore.getMeta(record))?.ttl, isNull,
            reason: 'the record is unchanged');
        expect(client.closeCount, 0, reason: 'it keeps its connection');
      });
    }
  });

  test(
      "An atSign's own client may not change a record in a reserved namespace "
      'inside a batch', () async {
    await keyValueStore.put('x.__global@alice', AtData()..data = 'before');
    final Connection client = await starRw();

    await send(
        'batch:${jsonEncode([
              {'id': 1, 'command': 'update:x.__global@alice v'},
              {'id': 2, 'command': 'update:x.wavi@alice v'},
            ])}',
        client);

    final List<dynamic> entries = jsonDecode(
        client.writes.first.substring('data:'.length).split('\n').first);
    expect(entries[0]['response']['error_code'], 'AT0009');
    expect(await valueOf('x.__global@alice'), 'before');
    expect(entries[1]['response']['error_code'], isNull);
    expect(await valueOf('x.wavi@alice'), 'v');
  });

  group('An enrollment changes records in its own per-enrollment namespace',
      () {
    test('apkam as enrollment e1, update:__ckcur.bob.wavi.e1.a.__e@alice v',
        () async {
      final Connection client = await e1();

      await send('update:__ckcur.bob.wavi.e1.a.__e@alice v', client);

      expect(client.writes.first, startsWith('data:'));
      expect(await valueOf('__ckcur.bob.wavi.e1.a.__e@alice'), 'v');
    });

    test('apkam as enrollment e1, delete:__ckcur.bob.wavi.e1.a.__e@alice',
        () async {
      await keyValueStore.put(
          '__ckcur.bob.wavi.e1.a.__e@alice', AtData()..data = 'before');
      final Connection client = await e1();

      await send('delete:__ckcur.bob.wavi.e1.a.__e@alice', client);

      expect(client.writes.first, startsWith('data:'));
      expect(await keyValueStore.exists('__ckcur.bob.wavi.e1.a.__e@alice'),
          isFalse);
    });

    test(
        'pkam, as enrollment primary, '
        'update:public:_apsk.primary.a.__e@alice v', () async {
      final Connection client = await pkam();

      await send('update:public:_apsk.primary.a.__e@alice v', client);

      expect(client.writes.first, startsWith('data:'));
      expect(await valueOf('public:_apsk.primary.a.__e@alice'), 'v');
    });

    test(
        'cram, as enrollment primary, '
        'update:public:_apsk.primary.a.__e@alice v', () async {
      final Connection client = await cram();

      await send('update:public:_apsk.primary.a.__e@alice v', client);

      expect(client.writes.first, startsWith('data:'));
      expect(await valueOf('public:_apsk.primary.a.__e@alice'), 'v');
    });

    test('apkam as enrollment e1, update:@alice:x.e1.a.__e@alice v', () async {
      final Connection client = await e1();

      await send('update:@alice:x.e1.a.__e@alice v', client);

      expect(client.writes.first, startsWith('data:'));
      expect(await valueOf('@alice:x.e1.a.__e@alice'), 'v');
    });

    test('apkam as enrollment e1, delete:@bob:x.e1.a.__e@alice', () async {
      await keyValueStore.put(
          '@bob:x.e1.a.__e@alice', AtData()..data = 'before');
      final Connection client = await e1();

      await send('delete:@bob:x.e1.a.__e@alice', client);

      expect(client.writes.first, startsWith('data:'));
      expect(await keyValueStore.exists('@bob:x.e1.a.__e@alice'), isFalse,
          reason: 'any that exist can be removed');
    });
  });

  group(
      "An enrollment's records in its own per-enrollment namespace are never "
      'for another atSign', () {
    for (final String command in [
      'update:@bob:x.e1.a.__e@alice v',
      'update:meta:@bob:x.e1.a.__e@alice:ttl:1000',
    ]) {
      test(command, () async {
        await keyValueStore.put(
            '@bob:x.e1.a.__e@alice', AtData()..data = 'before');
        final Connection client = await e1();

        await send(command, client);

        expect(client.writes.first, startsWith('error:AT0009'));
        expect(await valueOf('@bob:x.e1.a.__e@alice'), 'before',
            reason: 'the record is unchanged');
        expect(
            (await keyValueStore.getMeta('@bob:x.e1.a.__e@alice'))?.ttl, isNull,
            reason: 'the record is unchanged');
      });
    }
  });

  group('Given a reserved namespace of 5000 characters', () {
    final String longName = '__${'a' * 5000}';
    final Matcher isShortened =
        allOf(contains('[truncated'), isNot(contains('a' * (2100 + 1))));

    for (final String command in [
      'update:x.$longName@alice v',
      'delete:x.$longName@alice',
    ]) {
      test(
          'when an own client sends ${command.split(':').first} of a record '
          'in it, then the refusal is shortened', () async {
        final Connection client = await cram();

        await send(command, client);

        expect(client.writes.first, startsWith('error:AT0009'));
        expect(client.writes.first, isShortened);
      });
    }
  });

  group('A stored passcode is read only through otp:', () {
    Future<Connection> starR() => enrolled('e8', {'*': 'r'});
    for (final (
          String auth,
          Future<Connection> Function() connect,
          String record,
          String command
        ) in [
      (
        'cram',
        cram,
        'private:spp.__otp@alice',
        'llookup:private:spp.__otp@alice'
      ),
      (
        'apkam as an enrollment holding *:r',
        starR,
        'private:spp.__otp@alice',
        'llookup:private:spp.__otp@alice'
      ),
      (
        'cram',
        cram,
        'private:spp.__otp@alice',
        'lookup:private:spp.__otp@alice'
      ),
      (
        'apkam as an enrollment holding *:r',
        starR,
        'private:spp.__otp@alice',
        'lookup:all:private:spp.__otp@alice'
      ),
      (
        'apkam as an enrollment holding *:r',
        starR,
        'private:spp@alice',
        'llookup:private:spp@alice'
      ),
      ('cram', cram, 'private:spp@alice', 'lookup:private:spp@alice'),
    ]) {
      test('$auth, $command', () async {
        await keyValueStore.put(record, AtData()..data = 'SPP123');
        final Connection client = await connect();

        await send(command, client);

        expect(client.writes.first, startsWith('error:AT0009'));
        expect(client.writes.join(), isNot(contains('SPP123')));
      });
    }
  });

  test(
      'Given a key that begins with @ and has no colon, when its enrollment '
      'updates it alone and in a batch, then it is answered and the batch '
      'runs on', () async {
    final Connection client = await enrolled('e9', {'*': 'rw'});
    final String update = 'update:json:${jsonEncode({
          'atKey': '@x.e9.a.__e',
          'sharedBy': '@alice',
          'value': 'v'
        })}';

    await send(update, client);
    expect(client.writes.first, isNot(contains('AT0010')));

    await send(
        'batch:${jsonEncode([
              {'id': 1, 'command': update},
              {'id': 2, 'command': 'update:x.wavi@alice v'},
            ])}',
        client);
    final List<dynamic> entries = jsonDecode(
        client.writes.last.substring('data:'.length).split('\n').first);
    expect(entries, hasLength(2));
    expect(await valueOf('x.wavi@alice'), 'v');
  });

  test(
      "An atSign's own client still reads what its enrollment may read in a "
      'reserved namespace', () async {
    await keyValueStore.put(
        '1700000000000000.events.__atserver@alice', AtData()..data = 'VALUE');
    final Connection client = await enrolled('e8', {'*': 'r'});

    await send('llookup:1700000000000000.events.__atserver@alice', client);

    expect(client.writes.first, startsWith('data:VALUE'));
  });

  group('Given a record key', () {
    for (final (String key, String? enrollmentId, String? reserved) in [
      ('x.__global@alice', null, '__global'),
      ('@bob:__manage.x@alice', null, '__manage'),
      ('public:x.__foo@alice', 'e1', '__foo'),
      ('x.__global@bob', null, '__global'),
      ('cached:@alice:x.__global@bob', null, null),
      ('x.primary.a.__e@alice', null, null),
      ('x.e1.a.__e@alice', 'e1', null),
      ('x.e1.a.__e@alice', 'E1', null),
      ('x.e1.a.__e@alice', 'e2', '__e'),
      ('x.wavi@alice', null, null),
    ]) {
      test(
          'when it is $key on a connection that is enrollment $enrollmentId, '
          'then a direct change is barred by ${reserved ?? 'no namespace'}',
          () {
        expect(
            reservedNamespaceBarringChange(key,
                atSign: alice, enrollmentId: enrollmentId),
            reserved);
      });
    }

    for (final (String key, bool forAnother) in [
      ('@bob:x.e1.a.__e@alice', true),
      ('@bob:x.e2.r.__e@alice', true),
      ('@alice:x.e1.a.__e@alice', false),
      ('public:x.e1.a.__e@alice', false),
      ('x.e1.a.__e@alice', false),
      ('@bob:x.wavi@alice', false),
      ('@x.e1.a.__e@alice', false),
    ]) {
      test(
          'when it is $key, then it is ${forAnother ? '' : 'not '}a '
          'per-enrollment record for another atSign', () {
        expect(isPerEnrollmentRecordForAnotherAtSign(key, atSign: alice),
            forAnother);
      });
    }

    for (final (String key, bool isPasscode) in [
      ('private:spp.__otp@alice', true),
      ('private:abc123.__otp@alice', true),
      ('private:spp.wavi@alice', false),
      ('private:spp@alice', true),
    ]) {
      test('when it is $key, then it is ${isPasscode ? '' : 'not '}a passcode',
          () {
        expect(isPasscodeRecord(key), isPasscode);
      });
    }
  });
}
