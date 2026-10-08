import 'dart:async';
import 'dart:io';

import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_utils/at_utils.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

class _FakeSecureSocket extends Fake implements SecureSocket {
  bool destroyed = false;

  @override
  String? get selectedProtocol => null;

  @override
  X509Certificate? get peerCertificate => null;

  @override
  void destroy() => destroyed = true;
}

class _FakeWebSocket extends Fake implements WebSocket {
  bool closed = false;

  @override
  Future close([int? code, String? reason]) async => closed = true;
}

class _FakeSecureServerSocket extends Fake implements SecureServerSocket {}

void main() {
  late MockInboundConnectionManager manager;

  setUpAll(() {
    verbTestsSetUpLogging();
    registerFallbackValue(_FakeSecureSocket());
    registerFallbackValue(_FakeWebSocket());
  });

  setUp(() {
    manager = MockInboundConnectionManager();
    AtSecondaryServerImpl.getInstance().inboundConnectionManager = manager;
  });

  /// Starts [accept] the way a listener does, without awaiting it, and
  /// returns every error that escaped to the zone it ran in.
  Future<List<Object>> uncaughtFrom(Future<void> Function() accept) async {
    final List<Object> uncaught = [];
    runZonedGuarded(() => unawaited(accept()), (e, _) => uncaught.add(e));
    await Future.delayed(const Duration(milliseconds: 100));
    return uncaught;
  }

  test('an unexpected error accepting a socket closes only that socket',
      () async {
    when(() => manager.createSocketConnection(any(),
        sessionId: any(named: 'sessionId'))).thenThrow(StateError('injected'));
    final socket = _FakeSecureSocket();

    final uncaught = await uncaughtFrom(() =>
        AtSecondaryServerImpl.getInstance().acceptSocket(
            socket, PseudoServerSocket(_FakeSecureServerSocket())));

    expect(uncaught, isEmpty);
    expect(socket.destroyed, isTrue);
  });

  test('an unexpected error setting up a WebSocket closes only that WebSocket',
      () async {
    when(() => manager.createWebSocketConnection(any(),
        sessionId: any(named: 'sessionId'))).thenThrow(StateError('injected'));
    final ws = _FakeWebSocket();

    final uncaught = await uncaughtFrom(
        () => AtSecondaryServerImpl.getInstance().webSocketListener(ws));

    expect(uncaught, isEmpty);
    expect(ws.closed, isTrue);
  });
}
