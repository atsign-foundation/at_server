import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:at_commons/at_commons.dart' show Response;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_web_socket_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_write_queue.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/http_connections.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart'
    show AuthType, InboundConnection;
import 'package:test/test.dart';

import 'test_utils.dart';

/// Catalogue: features/connections/unsent_bytes_bound.feature
void main() {
  const String certs =
      '../../tools/build_virtual_environment/ve_base/contents/atsign/secondary/base/certs';
  const int limit = 16 * 1024 * 1024;
  final int seed =
      int.tryParse(Platform.environment['UNSENT_BYTES_TEST_SEED'] ?? '') ??
          Random().nextInt(1 << 31);
  late SecureServerSocket serverSocket;
  late HttpConnections http;
  final List<_Client> clients = <_Client>[];
  AtSecondaryContext? priorContext;
  int at = DateTime.now().millisecondsSinceEpoch;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    priorContext = AtSecondaryServerImpl.getInstance().serverContext;
    AtSecondaryServerImpl.getInstance().serverContext = AtSecondaryContext()
      ..inboundMaxUnsentBytes = limit;
    atServer.inboundConnectionManager =
        InboundConnectionManager(serverAtSign: alice, poolSize: 10);
    serverSocket = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChain('$certs/fullchain.pem')
          ..usePrivateKey('$certs/privkey.pem')
          ..setAlpnProtocols(['atProtocol/1.0', 'http/1.1'], true));
    http = atServer.listenOn(serverSocket, httpMaxLimit: 10);
    printOnFailure('UNSENT_BYTES_TEST_SEED=$seed');
  });

  tearDown(() async {
    for (final _Client client in clients) {
      client.socket.destroy();
    }
    clients.clear();
    for (final InboundConnection c
        in atServer.inboundConnectionManager.pool.getConnections().toList()) {
      await c.close();
    }
    await http.close();
    await serverSocket.close();
    AtSecondaryServerImpl.getInstance().serverContext = priorContext;
    await verbTestsTearDown();
  });

  /// Connects a client the way a real one does: by TLS negotiating
  /// atProtocol/1.0, or by WebSocket upgrading /ws over http/1.1. Returns
  /// the client once it has the @ prompt, with the atServer's side of the
  /// connection, authenticated by CRAM.
  Future<(_Client, InboundConnection)> connect(
      {required bool webSocket}) async {
    final Set<InboundConnection> before =
        atServer.inboundConnectionManager.pool.getConnections().toSet();
    final SecureSocket socket = await SecureSocket.connect(
        InternetAddress.loopbackIPv4, serverSocket.port,
        supportedProtocols: [webSocket ? 'http/1.1' : 'atProtocol/1.0'],
        onBadCertificate: (_) => true);
    final _Client client = _Client(socket, webSocket: webSocket);
    clients.add(client);
    if (webSocket) {
      socket.write('GET /ws HTTP/1.1\r\n'
          'Host: 127.0.0.1:${serverSocket.port}\r\n'
          'Upgrade: websocket\r\n'
          'Connection: Upgrade\r\n'
          'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
          'Sec-WebSocket-Version: 13\r\n\r\n');
    }
    await _until(
        () => atServer.inboundConnectionManager.pool
            .getConnections()
            .any((InboundConnection c) => !before.contains(c)),
        reason: 'precondition: the atServer took the connection');
    final InboundConnection server = atServer.inboundConnectionManager.pool
        .getConnections()
        .singleWhere((InboundConnection c) => !before.contains(c));
    await _until(() => client.prompted,
        reason: 'the client receives every line once, in order and whole: '
            'the @ prompt never arrived (seed $seed)');
    (server.metaData as InboundConnectionMetadata)
      ..isAuthenticated = true
      ..authType = AuthType.cram;
    return (client, server);
  }

  group('A client that reads in bursts receives every byte written to it', () {
    for (final String transport in ['TLS', 'WebSocket']) {
      test(transport, () async {
        final Random random = Random(seed);
        final (_Client client, InboundConnection server) =
            await connect(webSocket: transport == 'WebSocket');
        final List<int> lengths = <int>[];
        int next = 0;
        String? misread;
        client.onLine = (Uint8List line) {
          final int? s = int.tryParse(
              ascii.decode(Uint8List.sublistView(line, 0, max(0, line.indexOf(58)))));
          if (s != next || s! >= lengths.length || line.length != lengths[s]) {
            misread ??= 'line $s of ${line.length} bytes arrived where line '
                '$next was due';
          }
          next++;
        };
        final _Watch watch = _Watch(server, seed);
        client.readInBursts(random);

        await watch.or(_writeLines(server, random, 8 * 1024 * 1024, lengths));
        await watch.or(_until(() => next >= lengths.length,
            reason: 'the client receives every line once, in order and '
                'whole: it read $next of ${lengths.length} (seed $seed)'));
        await (server as DrainableConnection).drained.timeout(
            const Duration(seconds: 2),
            onTimeout: () => fail('once the client has read everything, the '
                'connection is drained (seed $seed)'));
        watch.stop();

        expect(watch.failure, isNull, reason: watch.failure);
        expect(misread, isNull,
            reason: 'the client receives every line once, in order and '
                'whole (seed $seed)');
        expect(watch.waitingTurns, greaterThan(0),
            reason: 'precondition: bytes waited behind a paused transport');
        expect(server.metaData.isClosed, isFalse);
      }, timeout: const Timeout(Duration(seconds: 60)));
    }
  });

  group('The bytes held for a replay are released however the replay ends',
      () {
    AtNotification notification(String id, int valueLength) =>
        (AtNotificationBuilder()
              ..id = id
              ..fromAtSign = bob
              ..toAtSign = alice
              ..notification = '@alice:phone.wavi@bob'
              ..atValue = 'v' * valueLength
              ..notificationDateTime =
                  DateTime.fromMillisecondsSinceEpoch(++at, isUtc: true)
              ..type = NotificationType.received)
            .build();

    late _Client client;
    late InboundConnectionImpl server;
    late MonitorVerbHandler handler;
    late List<String> written;
    late Future<void> replay;

    /// Starts a monitor:<t> replay of [stored] notifications to a client that
    /// has stopped reading, and queues [live] notifications behind it.
    Future<void> holdBehindReplay(int stored, int live) async {
      final int t = at;
      for (int i = 0; i < stored; i++) {
        final AtNotification n = notification('stored-$i', 4096);
        written.add(n.id!);
        await notificationManager.notify(n);
      }
      final (_Client c, InboundConnection s) = await connect(webSocket: false);
      client = c;
      server = s as InboundConnectionImpl;
      client.stopReading();
      client.onLine = (Uint8List line) {
        final String text = utf8.decode(line);
        if (text.startsWith('notification: ')) {
          client.ids.add(jsonDecode(text.substring(14))['id'] as String);
        }
      };
      await server.write('${'f' * (8 * 1024 * 1024)}\n');
      replay = handler.processVerb(
          Response(), handler.parse('monitor:$t'), server);
      await _until(() => server.unsentBytes > 0,
          reason: 'precondition: the replay waits for the client');
      for (int i = 0; i < live; i++) {
        final AtNotification n = notification('live-$i', 2048);
        written.add(n.id!);
        notificationManager.enqueue(n);
      }
      await _until(() => server.heldBytes > 0,
          reason: 'precondition: live notifications are held behind the '
              'replay');
    }

    Future<void> heldReturnToZero() async {
      await _until(() => server.heldBytes == 0,
          reason: 'the bytes held for the replay return to zero');
    }

    setUp(() {
      handler = MonitorVerbHandler(keyValueStore, notificationManager);
      written = <String>[];
    });

    test('the client closes the connection', () async {
      await holdBehindReplay(20, 3);

      client.socket.destroy();
      await _until(() => server.metaData.isClosed,
          reason: 'precondition: the atServer saw the client close');
      await replay.timeout(const Duration(seconds: 5));

      await heldReturnToZero();
    });

    test(
        'the client reads, and runs monitor again while the held notifications are still being written',
        () async {
      await holdBehindReplay(20, 10);

      client.read();
      await replay.timeout(const Duration(seconds: 30));
      expect(notificationManager.queuedPushes, greaterThan(0),
          reason: 'precondition: the held notifications are still being '
              'written');
      await handler.processVerb(Response(), handler.parse('monitor'), server);
      await notificationManager.monitorsIdle;

      await heldReturnToZero();
      await _until(() => client.ids.length >= written.length,
          reason: 'every notification reaches the client');
      expect(client.ids, written);
    });

    test('the client reads and the replay completes', () async {
      await holdBehindReplay(20, 3);

      client.read();
      await replay.timeout(const Duration(seconds: 30));
      await notificationManager.monitorsIdle;

      await heldReturnToZero();
      await _until(() => client.ids.length >= written.length,
          reason: 'every notification reaches the client');
      expect(client.ids, written);
    });
  });
}

/// Waits, a few milliseconds at a time, until [condition] holds, failing
/// with [reason] if it has not within [within].
Future<void> _until(bool Function() condition,
    {required String reason,
    Duration within = const Duration(seconds: 20)}) async {
  final Stopwatch waited = Stopwatch()..start();
  while (!condition()) {
    if (waited.elapsed > within) {
      fail(reason);
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// Writes about [total] bytes of numbered lines of mixed sizes to
/// [connection], recording each line's UTF-8 length without its newline in
/// [lengths]. Some writes are awaited, some made in a burst, some from the
/// next turn, a microtask or drained's callback; once 2 MiB are waiting,
/// it waits for them to drain or for a few milliseconds.
Future<void> _writeLines(InboundConnection connection, Random random,
    int total, List<int> lengths) async {
  final DrainableConnection drainable = connection as DrainableConnection;
  final List<Future<void>> writes = <Future<void>>[];
  int written = 0;

  void write(String body) {
    final String line = '${lengths.length}:$body\n';
    final int length = utf8.encode(line).length;
    lengths.add(length - 1);
    written += length;
    writes.add(connection.write(line));
  }

  Future<void> later(void Function(void Function()) schedule) {
    final Completer<void> done = Completer<void>();
    final String body = _body(random);
    schedule(() {
      write(body);
      done.complete();
    });
    return done.future;
  }

  while (written < total) {
    while (_unsent(connection) > 2 * 1024 * 1024) {
      if (random.nextBool()) {
        await drainable.drained;
      } else {
        await Future<void>.delayed(
            Duration(milliseconds: 1 + random.nextInt(8)));
      }
    }
    switch (random.nextInt(5)) {
      case 0:
        write(_body(random));
        await writes.last;
      case 1:
        for (int k = random.nextInt(4); k >= 0; k--) {
          write(_body(random));
        }
      case 2:
        await later(Timer.run);
      case 3:
        await later(scheduleMicrotask);
      case 4:
        await later((void Function() f) => drainable.drained.then((_) => f()));
    }
  }
  await Future.wait(writes);
}

const String _chunk = 'abcdefghijklmnopqrstuvwxyz0123456789é€😀';
final String _source = _chunk * (1024 * 1024 ~/ _chunk.length + 2);

/// A line body of 1-, 2-, 3- and 4-byte UTF-8 characters, mostly short and
/// sometimes up to 1 MiB.
String _body(Random random) {
  final double r = random.nextDouble();
  final int units = r < 0.70
      ? 1 + random.nextInt(512)
      : r < 0.95
          ? 512 + random.nextInt(64 * 1024)
          : 64 * 1024 + random.nextInt(1024 * 1024 - 64 * 1024);
  int start = random.nextInt(_chunk.length);
  int end = start + units;
  if ((_source.codeUnitAt(start) & 0xFC00) == 0xDC00) start++;
  if ((_source.codeUnitAt(end - 1) & 0xFC00) == 0xD800) end++;
  return _source.substring(start, end);
}

int _unsent(InboundConnection c) => switch (c) {
      InboundConnectionImpl c => c.unsentBytes,
      InboundWebSocketConnection c => c.unsentBytes,
      _ => throw ArgumentError.value(c),
    };

bool _takingWrites(InboundConnection c) => switch (c) {
      InboundConnectionImpl c => c.transportTakingWrites,
      InboundWebSocketConnection c => c.transportTakingWrites,
      _ => throw ArgumentError.value(c),
    };

/// Checks a connection at every event-loop turn, when no microtask is
/// pending, that no bytes wait while its transport is taking writes.
class _Watch {
  _Watch(this.connection, this.seed) {
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) => _check());
  }

  final InboundConnection connection;
  final int seed;
  late final Timer _timer;
  final Completer<void> _failed = Completer<void>();

  /// How many turns found bytes waiting behind a paused transport.
  int waitingTurns = 0;

  /// Why a check failed, once one has.
  String? failure;

  void _check() {
    final int unsent = _unsent(connection);
    if (unsent == 0) {
      return;
    }
    if (!_takingWrites(connection)) {
      waitingTurns++;
      return;
    }
    _timer.cancel();
    failure = 'no bytes wait while the transport is taking writes: $unsent '
        'bytes were waiting (seed $seed)';
    _failed.completeError(TestFailure(failure));
  }

  /// Completes as [work] does, or fails as soon as a check does.
  Future<void> or(Future<void> work) => Future.any([work, _failed.future]);

  void stop() => _timer.cancel();
}

/// A client that reads its connection in bursts, pausing at random and
/// sometimes for over a second, and splits what it reads into lines.
class _Client {
  _Client(this.socket, {required this.webSocket}) {
    _subscription = socket.listen(_take, onError: (Object _) {});
  }

  final SecureSocket socket;
  final bool webSocket;
  late final StreamSubscription<Uint8List> _subscription;
  final BytesBuilder _line = BytesBuilder(copy: true);
  final List<int> _head = <int>[];
  final List<int> _frameHeader = <int>[];
  int _payloadLeft = -1;
  int _opcode = 0;
  Random? _random;
  int _burstLeft = 0;

  /// Whether the @ prompt has arrived.
  bool prompted = false;

  /// Takes each line the client reads, without its newline.
  void Function(Uint8List line) onLine = (_) {};

  /// Notification ids the client has read, for tests that collect them.
  final List<String> ids = <String>[];

  void stopReading() {
    if (!_subscription.isPaused) _subscription.pause();
  }

  void read() {
    _random = null;
    while (_subscription.isPaused) {
      _subscription.resume();
    }
  }

  /// Starts reading in bursts after a first pause of half a second.
  void readInBursts(Random random) {
    _random = random;
    stopReading();
    Timer(const Duration(milliseconds: 500), _nextBurst);
  }

  void _nextBurst() {
    _burstLeft = 4096 + _random!.nextInt(512 * 1024);
    if (_subscription.isPaused) _subscription.resume();
  }

  void _take(Uint8List data) {
    if (webSocket) {
      _frames(data);
    } else {
      _lines(data);
    }
    final Random? random = _random;
    if (random == null) return;
    _burstLeft -= data.length;
    if (_burstLeft > 0) return;
    _subscription.pause();
    final int pause = random.nextDouble() < 0.03
        ? 300 + random.nextInt(1200)
        : random.nextInt(25);
    Timer(Duration(milliseconds: pause), _nextBurst);
  }

  void _lines(Uint8List data) {
    int start = 0;
    if (!prompted && data.isNotEmpty && data[0] == 64) {
      prompted = true;
      start = 1;
    }
    while (true) {
      final int newline = data.indexOf(10, start);
      if (newline < 0) {
        _line.add(Uint8List.sublistView(data, start));
        return;
      }
      _line.add(Uint8List.sublistView(data, start, newline));
      onLine(_line.takeBytes());
      start = newline + 1;
    }
  }

  /// Reads the 101 answer, then the unmasked frames, one message per frame.
  void _frames(Uint8List data) {
    int i = 0;
    while (_head.length < 4 ||
        !(_head[_head.length - 4] == 13 &&
            _head[_head.length - 3] == 10 &&
            _head[_head.length - 2] == 13 &&
            _head[_head.length - 1] == 10)) {
      if (i == data.length) return;
      _head.add(data[i++]);
    }
    while (i < data.length) {
      if (_payloadLeft < 0) {
        _frameHeader.add(data[i++]);
        if (_frameHeader.length < 2) continue;
        final int length7 = _frameHeader[1] & 0x7f;
        final int size = length7 == 126 ? 4 : (length7 == 127 ? 10 : 2);
        if (_frameHeader.length < size) continue;
        _opcode = _frameHeader[0] & 0x0f;
        _payloadLeft = 0;
        if (length7 < 126) {
          _payloadLeft = length7;
        } else {
          for (int k = 2; k < size; k++) {
            _payloadLeft = (_payloadLeft << 8) | _frameHeader[k];
          }
        }
        _frameHeader.clear();
      }
      final int take = min(_payloadLeft, data.length - i);
      _line.add(Uint8List.sublistView(data, i, i + take));
      i += take;
      _payloadLeft -= take;
      if (_payloadLeft == 0) {
        _payloadLeft = -1;
        _message(_line.takeBytes());
      }
    }
  }

  void _message(Uint8List payload) {
    if (_opcode != 1) return;
    if (!prompted) {
      prompted = payload.length == 1 && payload[0] == 64;
      return;
    }
    final int end = payload.isNotEmpty && payload.last == 10
        ? payload.length - 1
        : payload.length;
    onLine(Uint8List.sublistView(payload, 0, end));
  }
}
