import 'dart:async';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/connection_util.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_message_listener.dart';
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

  group('A test to verify commands are framed one per terminator', () {
    /// Feeds [flows] into a listener over [fakeConnection], one addData per
    /// element with [gapMillis] between them, and returns the commands the
    /// listener dispatched.
    Future<List<String>> dispatchedFor(List<String> flows,
        {int gapMillis = 0}) async {
      final commands = <String>[];
      InboundMessageListener(fakeConnection).listen(
          (String command, InboundConnection connection) async =>
              commands.add(command),
          (List<int> data, InboundConnection connection) {});
      for (final flow in flows) {
        fakeConnection.socket.addData(flow);
        if (gapMillis > 0) {
          await Future.delayed(Duration(milliseconds: gapMillis));
        }
      }
      await Future.delayed(Duration(milliseconds: 60));
      return commands;
    }

    test('monitor then noop:0 in ONE flow are dispatched as two commands',
        () async {
      // Reproducer for a production bug. at_lookup runs `noop:0` heartbeats
      // on the same connection it runs the monitor on. When two commands
      // landed in one read event the buffer dispatched everything it held as
      // a single command -- 'monitor\nnoop:0' -- which no verb syntax
      // matches (the regexes are `^..$` without multiLine, and `.` does not
      // cross a newline). The client got one error:AT0003 frame, the monitor
      // was never registered and the noop never ran, on a connection that
      // stayed open: a client reporting `listening` while permanently deaf.
      expect(await dispatchedFor(['monitor\nnoop:0\n']), ['monitor', 'noop:0'],
          reason: 'Both commands should be dispatched, in arrival order');
      expect(fakeConnection.writes, isEmpty,
          reason: 'Neither command is a syntax error, so this layer should '
              'write nothing; the connection saw ${fakeConnection.writes}');
    });

    test('the other order is framed too (noop:0 then monitor)', () async {
      // The bare `monitor` arm above fails in InboundCommandValidator (the
      // first colon lands inside `noop:0`, so the verb reads as
      // 'monitor\nnoop'), this one gets past it and fails in the verb
      // syntax. Both orders have to be pinned: they break in different
      // places.
      expect(await dispatchedFor(['noop:0\nmonitor\n']), ['noop:0', 'monitor'],
          reason: 'Both commands should be dispatched, in arrival order');
      expect(fakeConnection.writes, isEmpty);
    });

    test('three commands in one flow are dispatched in order', () async {
      expect(
          await dispatchedFor(['from:@alice\nscan\ninfo\n']),
          ['from:@alice', 'scan', 'info'],
          reason: 'The drain loop should not stop after the first command');
    });

    test('a fragmented command followed by a pipelined one', () async {
      // The fragment reassembly and the framing have to hold at once: the
      // first flow ends mid-command and the second carries its tail AND a
      // whole further command.
      expect(
          await dispatchedFor(['lookup:publi', 'ckey@alice\nnoop:0\n'],
              gapMillis: 15),
          ['lookup:publickey@alice', 'noop:0'],
          reason: 'The tail of flow 1 and the head of flow 2 are one command; '
              'what follows the terminator is a second one');
      expect(fakeConnection.writes, isEmpty);
    });

    test('a partial command left after the terminator stays buffered',
        () async {
      // Flow 1 holds one complete command plus the first bytes of the next.
      // The complete one goes out now; the partial must survive in the
      // buffer until flow 2 completes it, rather than being dispatched
      // truncated or binned.
      expect(await dispatchedFor(['from:@alice\nnoo', 'p:0\n'], gapMillis: 15),
          ['from:@alice', 'noop:0'],
          reason: 'The trailing partial command must be preserved across '
              'flows');
      expect(fakeConnection.writes, isEmpty);
    });

    test('a pipelined command waits for the previous handler to finish',
        () async {
      // Pipelined commands are dispatched one at a time: a request-response
      // protocol whose replies come back in completion order rather than
      // arrival order would hand the client the wrong reply for its command.
      final events = <String>[];
      InboundMessageListener(fakeConnection).listen(
          (String command, InboundConnection connection) async {
            events.add('start:$command');
            await Future.delayed(Duration(milliseconds: 20));
            events.add('end:$command');
          },
          (List<int> data, InboundConnection connection) {});
      fakeConnection.socket.addData('scan\ninfo\n');
      await Future.delayed(Duration(milliseconds: 150));
      expect(events, ['start:scan', 'end:scan', 'start:info', 'end:info'],
          reason: 'info must not start until scan has finished');
    });

    test('a rejected command bins the rest of the pipeline', () async {
      // `update` requires auth and `from:`/`scan` do not. The refusal has to
      // stop the drain: dispatching the commands queued behind a rejected
      // one would run them for a caller the validator has just refused.
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice'.toAtsign();
      final unauthenticated =
          FakeInboundConnection(FakeSocket(), InboundConnectionMetadata());
      final commands = <String>[];
      InboundMessageListener(unauthenticated).listen(
          (String command, InboundConnection connection) async =>
              commands.add(command),
          (List<int> data, InboundConnection connection) {});
      unauthenticated.socket
          .addData('from:@alice\nupdate:public:phone@alice 1234\nscan\n');
      await Future.delayed(Duration(milliseconds: 60));
      expect(commands, ['from:@alice'],
          reason: 'update is refused unauthenticated, and scan is queued '
              'behind it');
      expect(unauthenticated.writes.length, 1,
          reason: 'One error frame, for the refused update: '
              '${unauthenticated.writes}');
      expect(unauthenticated.writes.single, startsWith('error:'));
    });

    test('a command arriving DURING another command\'s handler is dispatched '
        'after it, not alongside it', () async {
      // The append signal for flow 2 lands while the drain loop is awaiting
      // flow 1's handler, and is dropped. The running loop has to pick those
      // bytes up when it comes back round, because nothing else will signal
      // it: a dropped signal with no follow-up flow would leave the command
      // sitting in the buffer for ever.
      final events = <String>[];
      InboundMessageListener(fakeConnection).listen(
          (String command, InboundConnection connection) async {
            events.add('start:$command');
            await Future.delayed(Duration(milliseconds: 40));
            events.add('end:$command');
          },
          (List<int> data, InboundConnection connection) {});
      fakeConnection.socket.addData('scan\n');
      await Future.delayed(Duration(milliseconds: 10));
      fakeConnection.socket.addData('info\n');
      await Future.delayed(Duration(milliseconds: 200));
      expect(events, ['start:scan', 'end:scan', 'start:info', 'end:info'],
          reason: 'info must be dispatched, and only once scan has finished');
    });

    test('an empty flow does not disturb the buffer', () async {
      // A WebSocket client can deliver an empty message, which reaches the
      // buffer as a zero-byte append. Asking an empty buffer for its last
      // byte raises a StateError, which is an Error rather than an Exception
      // — so it is not caught where a bad command is, and the connection is
      // torn down for a message that said nothing.
      expect(await dispatchedFor(['', 'scan\n'], gapMillis: 15), ['scan'],
          reason: 'The empty flow should be inert, and the command after it '
              'should still be dispatched');
      expect(fakeConnection.closeCount, 0,
          reason: 'An empty flow must not close the connection');
      expect(fakeConnection.writes, isEmpty);
    });

    test('@exit mid-pipeline stops the drain', () async {
      expect(await dispatchedFor(['scan\n@exit\nfrom:@alice\n']), ['scan'],
          reason: '@exit closes the connection; anything queued behind it '
              'must not be dispatched');
    });
  });
}
