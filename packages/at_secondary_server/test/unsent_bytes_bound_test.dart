import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'atsign_bound_harness.dart';
import 'test_utils.dart';

/// Catalogue: features/connections/unsent_bytes_bound.feature
void main() {
  const int limit = 64 * 1024;
  const String certs =
      '../../tools/build_virtual_environment/ve_base/contents/atsign/secondary/base/certs';
  final List<_Pair> pairs = <_Pair>[];
  late List<String> warnings;
  AtSecondaryContext? priorContext;
  int sessions = 0;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await setUpAtSignBound();
    priorContext = AtSecondaryServerImpl.getInstance().serverContext;
    AtSecondaryServerImpl.getInstance().serverContext = AtSecondaryContext()
      ..inboundMaxUnsentBytes = limit;
    warnings = <String>[];
  });

  tearDown(() async {
    for (final _Pair pair in pairs) {
      await pair.dispose();
    }
    pairs.clear();
    AtSecondaryServerImpl.getInstance().serverContext = priorContext;
    await verbTestsTearDown();
  });

  /// A loopback connection whose atServer side is an InboundConnectionImpl;
  /// its client starts out not reading.
  Future<_Pair> connect({bool tls = false}) async {
    final Socket serverSide;
    final Socket clientSide;
    if (tls) {
      final SecurityContext context = SecurityContext()
        ..useCertificateChain('$certs/fullchain.pem')
        ..usePrivateKey('$certs/privkey.pem');
      final SecureServerSocket listener = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4, 0, context);
      final Future<SecureSocket> accepted = listener.first;
      clientSide = await SecureSocket.connect(
          InternetAddress.loopbackIPv4, listener.port,
          onBadCertificate: (_) => true);
      serverSide = await accepted;
      await listener.close();
    } else {
      final ServerSocket listener =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final Future<Socket> accepted = listener.first;
      clientSide =
          await Socket.connect(InternetAddress.loopbackIPv4, listener.port);
      serverSide = await accepted;
      await listener.close();
    }
    final InboundConnectionImpl server =
        InboundConnectionImpl(serverSide, 'session-${++sessions}');
    final Level priorLevel = server.logger.logger.level;
    server.logger.level = 'warning';
    final StreamSubscription<LogRecord> logs = server.logger.logger.onRecord
        .where((LogRecord record) => record.level == Level.WARNING)
        .listen((LogRecord record) => warnings.add(record.message));
    final _Pair pair = _Pair(server, clientSide, () async {
      await logs.cancel();
      server.logger.logger.level = priorLevel;
    });
    pairs.add(pair);
    return pair;
  }

  Future<void> monitor(InboundConnectionImpl connection,
      [String command = 'monitor']) async {
    final MonitorVerbHandler handler =
        MonitorVerbHandler(keyValueStore, notificationManager);
    await handler.processVerb(Response(), handler.parse(command), connection);
  }

  int at = DateTime.now().millisecondsSinceEpoch;
  AtNotification notification(String id, {int valueLength = 8 * 1024}) =>
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

  int lineLength(AtNotification n) =>
      utf8.encode('notification: ${jsonEncode(n.mapForClient)}\n').length;

  Future<void> pushLive(Iterable<AtNotification> ns) async {
    for (final AtNotification n in ns) {
      notificationManager.enqueue(n);
    }
    await notificationManager.monitorsIdle;
  }

  /// Pushes notifications to [connection] until it closes, returning them;
  /// fails after [max].
  Future<List<AtNotification>> pushUntilClosed(InboundConnectionImpl connection,
      {int max = 4000, bool store = false}) async {
    final List<AtNotification> pushed = <AtNotification>[];
    while (pushed.length < max) {
      for (int j = 0; j < 20; j++) {
        final AtNotification n = notification('n${pushed.length}');
        pushed.add(n);
        if (store) {
          await notificationManager.notify(n);
        } else {
          notificationManager.enqueue(n);
        }
      }
      await notificationManager.monitorsIdle;
      if (connection.metaData.isClosed) {
        return pushed;
      }
    }
    fail('the connection was still open after $max notifications');
  }

  Future<String> enrollment() =>
      createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});

  test('A monitor connection whose client stops reading is closed at the limit',
      () async {
    final String e1 = await enrollment();
    final _Pair pair = await connect();
    (pair.server.metaData as InboundConnectionMetadata)
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..enrollmentId = e1;
    await monitor(pair.server);

    await pushUntilClosed(pair.server);

    expect(pair.server.metaData.isClosed, isTrue);
    expect(
        warnings.single,
        allOf([
          contains(pair.server.metaData.sessionID),
          contains('enrollment $e1'),
          contains('bytes would be waiting'),
          contains('the limit of $limit'),
        ]));
    expect(pair.server.unsentBytes, 0);
  });

  test('A client that reads slowly is not closed', () async {
    final _Pair pair = await connect();
    pair.server.metaData
      ..isAuthenticated = true
      ..authType = AuthType.cram;
    await monitor(pair.server);
    pair.readSlowly();

    for (int batch = 0; batch < 10; batch++) {
      await pushLive([
        for (int i = 0; i < 6; i++) notification('n${batch * 6 + i}'),
      ]);
      expect(pair.server.unsentBytes, lessThanOrEqualTo(limit));
      await pair.server.drained;
    }
    await pair.untilLines(60);

    expect(pair.server.metaData.isClosed, isFalse);
    expect(pair.ids, [for (int i = 0; i < 60; i++) 'n$i']);
  });

  test('One write larger than the limit onto an empty queue is taken',
      () async {
    final _Pair pair = await connect();
    pair.server.metaData
      ..isAuthenticated = true
      ..authType = AuthType.cram;
    await monitor(pair.server);

    await pushLive([notification('big-1', valueLength: 1024 * 1024)]);
    expect(pair.server.unsentBytes, 0,
        reason: 'nothing was waiting, so the transport took it');
    await pushLive([notification('big-2', valueLength: 1024 * 1024)]);
    expect(pair.server.unsentBytes, greaterThan(limit),
        reason: 'nothing was waiting, so the queue took it whole');
    expect(pair.server.metaData.isClosed, isFalse);

    pair.read();
    await pair.untilLines(2);

    expect(pair.ids, ['big-1', 'big-2']);
    expect(pair.server.metaData.isClosed, isFalse);
  });

  test('Replay waits for the client instead of filling the queue', () async {
    final int t = at;
    final List<AtNotification> backlog = [
      for (int i = 0; i < 300; i++) notification('stored-$i'),
    ];
    for (final AtNotification n in backlog) {
      await notificationManager.notify(n);
    }
    final _Pair pair = await connect();
    pair.server.metaData
      ..isAuthenticated = true
      ..authType = AuthType.cram;
    pair.read();

    await monitor(pair.server, 'monitor:$t');
    expect(pair.server.metaData.isClosed, isFalse);
    await pair.untilLines(300);

    expect(pair.ids, [for (int i = 0; i < 300; i++) 'stored-$i']);
  });

  test('A replay to a client that is not reading holds back its live pushes',
      () async {
    final int t = at;
    final List<AtNotification> backlog = [
      for (int i = 0; i < 300; i++) notification('stored-$i'),
    ];
    for (final AtNotification n in backlog) {
      await notificationManager.notify(n);
    }
    final _Pair pair = await connect();
    pair.server.metaData
      ..isAuthenticated = true
      ..authType = AuthType.cram;

    final Future<void> monitoring = monitor(pair.server, 'monitor:$t');
    await _until(() => pair.server.unsentBytes > 0);
    final List<AtNotification> live = [
      for (int i = 0; i < 3; i++) notification('live-$i'),
    ];
    for (final AtNotification n in live) {
      notificationManager.enqueue(n);
    }
    await pumpEventQueue();

    final int longestLine = [...backlog, ...live]
        .map(lineLength)
        .reduce((int a, int b) => a > b ? a : b);
    expect(pair.server.unsentBytes, lessThanOrEqualTo(longestLine));
    expect(pair.server.metaData.isClosed, isFalse);

    pair.read();
    await monitoring;
    await notificationManager.monitorsIdle;
    expect(pair.server.metaData.isClosed, isFalse);
    await pair.untilLines(303);
    expect(pair.ids, [
      for (int i = 0; i < 300; i++) 'stored-$i',
      for (int i = 0; i < 3; i++) 'live-$i',
    ]);
  });

  test('Stats notifications count toward the limit', () async {
    final _Pair pair = await connect();
    pair.server.metaData
      ..isAuthenticated = true
      ..authType = AuthType.cram;
    atServer.inboundConnectionManager =
        InboundConnectionManager(serverAtSign: alice, poolSize: 3);
    atServer.inboundConnectionManager.pool.add(pair.server);
    atServer.statsNotificationService.currentAtSign = alice;
    await monitor(pair.server);
    int i = 0;
    while (pair.server.unsentBytes == 0) {
      await pushLive([notification('fill-${i++}')]);
    }
    final int overhead = lineLength(notification('top-up', valueLength: 0));
    final int room = limit - pair.server.unsentBytes - 100;
    await pushLive([notification('top-up', valueLength: room - overhead)]);
    expect(pair.server.unsentBytes, inInclusiveRange(limit - 100, limit),
        reason: 'precondition: just under the limit');
    expect(warnings, isEmpty);

    await atServer.statsNotificationService
        .writeStatsToMonitor(latestCommitID: '7', operationType: 'update');

    expect(pair.server.metaData.isClosed, isTrue);
    expect(warnings, hasLength(1));
  });

  test(
      'A client that sends commands and never reads the responses is closed at the limit',
      () async {
    await keyValueStore.put(
        'public:big.wavi$alice', AtData()..data = 'p' * (32 * 1024));
    final _Pair pair = await connect();
    int sent = 0;

    while (!pair.server.metaData.isClosed && sent < 2000) {
      try {
        await DefaultVerbExecutor()
            .execute('lookup:big.wavi$alice', pair.server, verbs);
      } on AtConnectException {
        break;
      }
      sent++;
    }

    expect(pair.server.metaData.isClosed, isTrue);
    expect(warnings.single, contains('not authenticated'));
  });

  test('What the client sees when it is closed', () async {
    final _Pair pair = await connect(tls: true);
    pair.server.metaData
      ..isAuthenticated = true
      ..authType = AuthType.cram;
    await monitor(pair.server);
    await pushUntilClosed(pair.server);

    pair.read();
    await pair.ended;

    final String text = utf8.decode(pair.bytes, allowMalformed: true);
    expect(text, isNotEmpty);
    final List<String> lines = text.split('\n');
    final String partial = lines.removeLast();
    for (final String line in lines) {
      expect(jsonDecode(line.substring('notification: '.length))['id'],
          startsWith('n'));
    }
    expect(
        'notification: '.startsWith(partial) ||
            partial.startsWith('notification: '),
        isTrue,
        reason: 'anything after the last newline is the start of a line');
  });

  test('A client closed at the limit resumes from its watermark', () async {
    final _Pair pair = await connect();
    pair.server.metaData
      ..isAuthenticated = true
      ..authType = AuthType.cram;
    await monitor(pair.server);
    final List<AtNotification> stored =
        await pushUntilClosed(pair.server, store: true);
    pair.read();
    await pair.ended;
    final int t = pair.notifications.last['epochMillis'] as int;
    final List<Object?> afterT = [
      for (final AtNotification n in stored)
        if (n.notificationDateTime!.millisecondsSinceEpoch > t) n.id,
    ];

    final _RecordingConnection resumed = _RecordingConnection()
      ..metadata.isAuthenticated = true
      ..metadata.authType = AuthType.cram;
    final MonitorVerbHandler handler =
        MonitorVerbHandler(keyValueStore, notificationManager);
    await handler.processVerb(Response(), handler.parse('monitor:$t'), resumed);

    expect(resumed.ids, afterT);
    expect(afterT, isNotEmpty, reason: 'precondition: some were not read');
  });
}

/// Waits, one event-loop turn at a time, until [condition] holds.
Future<void> _until(bool Function() condition) async {
  for (int i = 0; i < 3000 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'the awaited condition never held');
}

/// A loopback connection pair: the atServer's side and its client.
class _Pair {
  _Pair(this.server, this.client, this._disposeLogs) {
    _subscription = client.listen(_builder.add,
        onDone: () => _ended.complete(),
        onError: (Object _) {
          if (!_ended.isCompleted) _ended.complete();
        });
    _subscription.pause();
  }

  final InboundConnectionImpl server;
  final Socket client;
  final Future<void> Function() _disposeLogs;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  final Completer<void> _ended = Completer<void>();
  late final StreamSubscription<Uint8List> _subscription;

  /// Completes when the atServer has closed the connection and the client
  /// has read everything that reached it.
  Future<void> get ended => _ended.future;

  /// Everything the client has read.
  Uint8List get bytes => _builder.toBytes();

  /// The notifications the client has read whole.
  List<Map<String, Object?>> get notifications => [
        for (final String line in utf8
            .decode(bytes, allowMalformed: true)
            .split('\n')
            .where((String l) => l.startsWith('notification: ')))
          if (_whole(line)) jsonDecode(line.substring('notification: '.length)),
      ];

  /// The ids of the notifications the client has read whole.
  List<Object?> get ids => [for (final n in notifications) n['id']];

  /// Starts the client reading.
  void read() => _subscription.resume();

  /// Starts the client reading, pausing briefly after each chunk.
  void readSlowly() {
    _subscription.onData((Uint8List data) {
      _builder.add(data);
      _subscription
          .pause(Future<void>.delayed(const Duration(milliseconds: 1)));
    });
    _subscription.resume();
  }

  /// Waits until the client has read [count] whole notifications.
  Future<void> untilLines(int count) => _until(() => ids.length >= count);

  Future<void> dispose() async {
    await _disposeLogs();
    await _subscription.cancel();
    client.destroy();
    await server.close();
  }

  static bool _whole(String line) {
    try {
      jsonDecode(line.substring('notification: '.length));
      return true;
    } on FormatException {
      return false;
    }
  }
}

/// A connection that keeps every write.
class _RecordingConnection extends DummyInboundConnection {
  final List<String> _writes = <String>[];

  /// The ids of the notifications written to this connection, in order.
  List<Object?> get ids => [
        for (final String w in _writes)
          if (w.startsWith('notification: '))
            jsonDecode(w.substring('notification: '.length))['id'],
      ];

  @override
  Future<void> write(String data) async {
    _writes.add(data);
  }
}
