import 'dart:async';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/connection_util.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_message_listener.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

StreamController<String> sc = StreamController<String>();

void streamCallBack(List<int> data, InboundConnection connection) {}

Future<void> callback(String value, InboundConnection connection) async {
  sc.add(value);
}

void _expectCommandsToValidate(
  List<String> commands,
  InboundConnection connection,
) {
  for (final command in commands) {
    expect(
      () => InboundCommandValidator.validate(
        utf8.encode(command).toList(),
        connection,
      ),
      returnsNormally,
      reason: 'Expected valid command: $command',
    );
  }
}

void _expectCommandsToRequireAuth(
  List<String> commands,
  InboundConnection connection,
) {
  for (final command in commands) {
    expect(
      () => InboundCommandValidator.validate(
        utf8.encode(command).toList(),
        connection,
      ),
      throwsA(isA<UnAuthenticatedException>()),
      reason: 'Expected auth-required command: $command',
    );
  }
}

void main() async {
  late FakeSocket socket;
  late InboundConnection connection;
  late FakeInboundConnection fakeConnection;

  late InboundConnectionMetadata authenticatedMetadata;
  late InboundConnectionMetadata unAuthenticatedMetadata;

  setUpAll(() {
    verbTestsSetUpLogging();
    authenticatedMetadata = InboundConnectionMetadata()..isAuthenticated = true;
    unAuthenticatedMetadata = InboundConnectionMetadata();
  });

  setUp(() async {
    sc = StreamController<String>();
    socket = FakeSocket();
    connection = MockInboundConnection();
    fakeConnection = FakeInboundConnection(socket, authenticatedMetadata);
    when(() => connection.close()).thenAnswer((_) async {});
    when(() => connection.isInValid()).thenReturn(false);

    final mockManager = MockInboundConnectionManager();
    final mockPool = MockInboundConnectionPool();
    when(() => mockManager.pool).thenReturn(mockPool);
    when(() => mockPool.remove(fakeConnection)).thenReturn(null);
    AtSecondaryServerImpl.getInstance().inboundConnectionManager = mockManager;
    AtSecondaryServerImpl.getInstance().globalExceptionHandler =
        GlobalExceptionHandler(alice);
  });

  // testing InboundConnectionValidator.validate(), mainly focusing on what it throws and when
  // happy path of this group is covered by inbound message listener.
  group('A test to verify commands are properly invalidated in the buffer', () {
    test('validate a successful command -> should pass', () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('lookup:public:publickey@alice\n').toList(),
            connection),
        returnsNormally,
      );
    });

    test('validate a failed verb (length > 32)', () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('lookupdjflsdfspublickeylice:').toList(), connection),
        throwsA(isA<InvalidSyntaxException>()),
      );
    });

    test('validate a failed verb (trying to run authenticated verb)', () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('monitor\n').toList(), connection),
        throwsA(isA<UnAuthenticatedException>()),
      );
    });

    test('validate all unauthenticated top-level verbs -> should pass', () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      _expectCommandsToValidate(unauthenticatedTopLevelCommands, connection);
    });

    test('validate all authenticated top-level verbs unauthenticated -> fail',
        () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      _expectCommandsToRequireAuth(authenticatedTopLevelCommands, connection);
    });

    test('validate all authenticated top-level verbs authenticated -> pass',
        () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      _expectCommandsToValidate(authenticatedTopLevelCommands, connection);
    });

    test('validate subcommand auth requirements for notify/keys/enroll', () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      _expectCommandsToValidate(subcommandsAllowedWithoutAuth, connection);
      _expectCommandsToRequireAuth(subcommandsRequiringAuth, connection);
    });

    test('validate scan with trailing arguments bypasses verb parsing', () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
          utf8.encode('scan this-is-accepted\n').toList(),
          connection,
        ),
        returnsNormally,
      );
    });

    test('validate monitor with trailing arguments bypasses verb parsing', () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
          utf8.encode('monitor this-is-accepted\n').toList(),
          connection,
        ),
        returnsNormally,
      );
    });

    test('invalidate bad connection', () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      when(() => connection.isInValid()).thenReturn(true);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('monitor\n').toList(), connection),
        throwsA(isA<ConnectionInvalidException>()),
      );
    });

    test('invalidate (non authenticated junk)', () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      when(() => connection.isInValid()).thenReturn(true);
      expect(
        () => InboundCommandValidator.validate(
            utf8
                .encode(
                    'monitoradshfajdsfkjalsdkjflaksdjlfkajsdlkfjalksdjflaksdjflaksdjflkadsjflkasdjflkajsdlkfjasldkfjalksdjflaksdjflaksdjfalskdfjalsdkfjalksdjfalksdjflaksdjflaksdjflaksdjflakdsjflakdsjfalksdjflaksdjflaksdjflaksdjflaksdjflaksdjflaksdjflaksdjflaksdjflaksdjflaksdjfalskdjfalskdjfalksdjfalskdjfalksdjflaskdjfalksdjfalskdjfalsdkfjalsdkjf')
                .toList(),
            connection),
        throwsA(isA<ConnectionInvalidException>()),
      );
    });

    test('rawVerb longer than 64 chars throws InvalidSyntaxException', () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('${'a' * 65}:rest\n').toList(), connection),
        throwsA(isA<InvalidSyntaxException>()),
      );
    });

    test('rawVerb of exactly 64 chars falls through to tryParse-null', () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('${'a' * 64}:rest\n').toList(), connection),
        throwsA(isA<InvalidSyntaxException>()),
      );
    });

    test('pol-authenticated connection passes auth-required top-level verbs',
        () {
      final pol = InboundConnectionMetadata()..isPolAuthenticated = true;
      when(() => connection.metaData).thenReturn(pol);
      _expectCommandsToValidate(authenticatedTopLevelCommands, connection);
    });
    test('pol-authenticated connection passes auth-required subcommands', () {
      final pol = InboundConnectionMetadata()..isPolAuthenticated = true;
      when(() => connection.metaData).thenReturn(pol);
      _expectCommandsToValidate(subcommandsRequiringAuth, connection);
    });

    test('unknown enroll subcommand falls back to verb.requiresAuth=false', () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('enroll:foobar:rest\n').toList(), connection),
        returnsNormally,
      );
    });

    test('enroll without colon falls back to verb.requiresAuth=false', () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('enroll\n').toList(), connection),
        returnsNormally,
      );
    });

    test('notify without colon throws UnAuth (fallback to verb.requiresAuth)',
        () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('notify\n').toList(), connection),
        throwsA(isA<UnAuthenticatedException>()),
      );
    });

    test('empty bytes throws InvalidSyntaxException', () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate([], connection),
        throwsA(isA<InvalidSyntaxException>()),
      );
    });

    test('whitespace-only input throws InvalidSyntaxException', () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('   \n').toList(), connection),
        throwsA(isA<InvalidSyntaxException>()),
      );
    });

    test('leading whitespace is stripped before parsing', () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('   lookup:public:publickey@alice\n').toList(),
            connection),
        returnsNormally,
      );
    });

    test('leading colon produces empty rawVerb and throws', () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode(':something\n').toList(), connection),
        throwsA(isA<InvalidSyntaxException>()),
      );
    });

    test('valid verb with >256 trailing bytes still validates from prefix', () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      final big = 'update:public:phone@alice ${'x' * 400}\n';
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode(big).toList(), connection),
        returnsNormally,
      );
    });

    test('>256 bytes of unrecognised junk throws based on the prefix', () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('${'z' * 400}\n').toList(), connection),
        throwsA(isA<InvalidSyntaxException>()),
      );
    });

    test('malformed UTF-8 bytes do not leak FormatException', () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            [0xFF, 0xFE, 0xFD, ...utf8.encode(':rest\n')], connection),
        throwsA(isA<InvalidSyntaxException>()),
      );
    });

    test('subcommandsRequiringAuth pass when authenticated', () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      _expectCommandsToValidate(subcommandsRequiringAuth, connection);
    });

    test(
        '`scan `/`monitor ` substring inside a value does NOT bypass auth check',
        () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('update:public:phone@alice scan some-text\n').toList(),
            connection),
        throwsA(isA<UnAuthenticatedException>()),
      );
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('update:public:phone@alice monitor stuff\n').toList(),
            connection),
        throwsA(isA<UnAuthenticatedException>()),
      );
    });
  });

  group(
      'A test to verify that the message listener is properly handling commands in the buffer',
      () {
    test('validate one-word commands -> should pass', () async {
      var listener = InboundMessageListener(fakeConnection);
      final streamFuture = expectLater(
          sc.stream,
          emitsInOrder([
            equalsIgnoringCase('scan'),
            equalsIgnoringCase('info'),
          ]));
      listener.listen(callback, streamCallBack);
      fakeConnection.socket.addData('scan\n');
      fakeConnection.socket.addData('info\n');
      await streamFuture;
    });

    test('validate a colon separated command -> should pass', () async {
      var listener = InboundMessageListener(fakeConnection);
      var lookup = 'lookup:public:publickey@alice:metadata:ttl:0\n';
      var from = 'from:@mchicken\n';
      var pkam = 'pkam:superadvancedcoolsignature\n';
      final streamFuture = expectLater(
          sc.stream,
          emitsInOrder([
            equalsIgnoringCase(lookup.trim()),
            equalsIgnoringCase(from.trim()),
            equalsIgnoringCase(pkam.trim()),
          ]));
      listener.listen(callback, streamCallBack);
      fakeConnection.socket.addData(lookup);
      fakeConnection.socket.addData(from);
      fakeConnection.socket.addData(pkam);
      await streamFuture;
    });

    test('validate a colon & json included command -> should pass', () async {
      var listener = InboundMessageListener(fakeConnection);
      listener.listen(callback, streamCallBack);
      var enroll =
          'enroll:request:{"appName":"wavi","deviceName":"iphone","namespaces":{"wavi":"rw"},"otp":"<otp>","apkamPublicKey":"<apkamPublicKey>","encryptedAPKAMSymmetricKey": "<encryptedAPKAMSymmetricKey>"}\n';
      final streamFuture = expectLater(
          sc.stream,
          emitsInOrder([
            equalsIgnoringCase(enroll.trim()),
          ]));
      fakeConnection.socket.addData(enroll);
      await streamFuture;
    });

    test('partial command validation -> should pass', () async {
      // receive command in increments, expect to validate by packet2
      // shouldn't fail and should emit one command.
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      var listener = InboundMessageListener(fakeConnection);
      listener.listen(callback, streamCallBack);
      var enroll =
          'enroll:request:{"appName":"wavi","deviceName":"iphone","namespaces":{"wavi":"rw"},"otp":"<otp>","apkamPublicKey":"<apkamPublicKey>","encryptedAPKAMSymmetricKey": "<encryptedAPKAMSymmetricKey>"}\n';
      final packet1 = enroll.substring(0, 5);
      final packet2 = enroll.substring(5, 40);
      final packet3 = enroll.substring(40);
      final streamFuture = expectLater(
          sc.stream,
          emitsInOrder([
            equalsIgnoringCase(enroll.trim()),
          ]));
      fakeConnection.socket.addData(packet1);
      fakeConnection.socket.addData(packet2);
      fakeConnection.socket.addData(packet3);
      await streamFuture;
    });

    test('validate representative command for each verb -> should pass',
        () async {
      var listener = InboundMessageListener(fakeConnection);
      listener.listen(callback, streamCallBack);
      final streamFuture = expectLater(
          sc.stream,
          emitsInOrder(representativeListenerCommands
              .map((command) => equalsIgnoringCase(command.trim()))
              .toList()));
      for (final command in representativeListenerCommands) {
        fakeConnection.socket.addData(command);
      }
      await streamFuture;
    });

    test(
        'lookup arriving in two TCP flows ("loo" + "kup:publickey@alice\\n") '
        'reassembles into one command emission and no error frames', () async {
      // Reproducer for a production bug. When a command's bytes arrive
      // in two TCP flows AND the first flow's bytes are shorter than
      // the verb name, InboundCommandValidator.validate runs against
      // the partial prefix on the first flow, fails (AtVerb.tryParse
      // returns null for 'loo'), the buffer is cleared, and the
      // second flow is then validated alone (also rejected). The
      // client sees two `error:…\n@` frames written to its connection
      // instead of the single successful response it should get.
      //
      // The expected behaviour: the listener should reassemble the
      // two flows into one command, emit it once via the callback,
      // and write nothing to the connection in this layer.
      var listener = InboundMessageListener(fakeConnection);
      final emissions = <String>[];
      final sub = sc.stream.listen(emissions.add);
      listener.listen(callback, streamCallBack);

      // GlobalExceptionHandler's _getPrompt reads
      // AtSecondaryServerImpl.getInstance().currentAtSign — set it
      // so that the error-handling path can actually write to the
      // connection (otherwise it throws an unrelated `late field`
      // error, the catch-on-Exception in the buffer listener doesn't
      // catch the Error, and `_buffer.clear()` never runs — masking
      // the bug as a successful reassembly).
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice'.toAtsign();

      const cmd = 'lookup:publickey@alice\n';
      fakeConnection.socket.addData(cmd.substring(0, 3)); // 'loo'
      // Yield to the event loop so the message + buffer listeners
      // process the first flow BEFORE the second arrives — mirroring
      // a real TCP flow gap. Without this, both flows land in the
      // buffer before any listener fires and the validator sees the
      // already-reassembled command, hiding the bug.
      await Future.delayed(Duration(milliseconds: 10));
      fakeConnection.socket
          .addData(cmd.substring(3)); //    'kup:publickey@alice\n'

      // Drain microtasks + give the listener a moment to process.
      await Future.delayed(Duration(milliseconds: 50));
      await sub.cancel();

      // Pin both the emission count and the contents (per the
      // count-emissions-not-just-the-last rule).
      expect(emissions, [cmd.trim()],
          reason: 'Expected one command emission with the reassembled '
              'lookup. With the current validate-on-first-flow logic, '
              'the prefix "loo" fails validation, the buffer is '
              'cleared, and zero commands are emitted.');

      // The listener layer shouldn't write to the connection on the
      // success path. Any writes here indicate a `GlobalExceptionHandler`
      // `error:…\n@` frame leaking out — the double-write the
      // production logs show.
      expect(fakeConnection.writes, isEmpty,
          reason: 'Expected no error frames written; the connection saw '
              '${fakeConnection.writes.length} write(s): '
              '${fakeConnection.writes}');
    });
  });
}
