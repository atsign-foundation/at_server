/// Benchmark: lookup and notify throughput between two atServers of the
/// virtualenv, driven by clients of each.
///
/// WHAT THIS MEASURES
///
/// - llookup, the control: clients authenticated as @bob🛠 look up a key of
///   @bob🛠's own, which never leaves @bob🛠's atServer. Latency is the
///   client's round trip, and it is the part of a lookup's latency that is not
///   the exchange between the two atServers.
/// - lookup: clients authenticated as @bob🛠 send
///   `lookup:bypassCache:true:<key>@alice🛠`, so on every call @bob🛠's
///   atServer looks the key up on @alice🛠's atServer over its
///   pol-authenticated connection. Latency is the client's round trip.
///
/// In both, each client looks up a key of its own.
/// - notify: clients authenticated as @bob🛠 send notifications to @alice🛠,
///   which @bob🛠's atServer queues and delivers; a client of @alice🛠
///   monitors and timestamps each arrival. Latency is send to arrival, both
///   read from one monotonic clock in this process.
///
/// Every response and every arrival is checked, so a run that errors or loses
/// a notification fails rather than reporting the speed of its errors. Before
/// timing, a remote-path check changes the looked-up value on @alice🛠's
/// atServer and requires @bob🛠's next lookup to answer the new value, which
/// only a lookup that reached @alice🛠's atServer can do.
///
/// The client speaks the protocol on its own sockets, completing each request
/// as its response line arrives, so its timing does not depend on whichever
/// at_lookup this package resolves.
///
/// Usage (normally through runBench.sh, which provides the virtualenv):
///
///   dart run bench/cross_atserver_bench.dart [options]
///
///   --host H          atServer host            (default vip.ve.atsign.zone)
///   --lookups N       timed lookups per run    (default 2000)
///   --notifies N      timed notifies per run   (default 1000)
///   --concurrency L   client counts, e.g. 1,8  (default 1,8)
///   --warmup N        untimed ops per run      (default 100)
///   --repeat N        runs per workload and client count (default 3)
///   --arrival-timeout S  seconds to wait for every notification (default 120)
///
/// VIRTUALENV_BASE_PORT shifts the atServer ports as the virtualenv does.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:uuid/uuid.dart';

const String _alice = '@alice🛠';
const String _bob = '@bob🛠';
const int _aliceUnshiftedPort = 25000;
const int _bobUnshiftedPort = 25003;
const String _namespace = 'gatebench';

/// The key client [index] looks up on @alice🛠's atServer.
String _remoteKey(int index) => 'lookup$index.$_namespace$_alice';

/// The key of @bob🛠's own that client [index] looks up locally.
String _localKey(int index) => 'local$index.$_namespace$_bob';

Future<void> main(List<String> arguments) async {
  final _Options options = _Options.parse(arguments);
  final int shift = _portShift();
  final _Target alice =
      _Target(_alice, options.host, _aliceUnshiftedPort + shift);
  final _Target bob = _Target(_bob, options.host, _bobUnshiftedPort + shift);
  final Stopwatch clock = Stopwatch()..start();

  print('alice: ${alice.atSign} ${alice.host}:${alice.port}');
  print('bob:   ${bob.atSign} ${bob.host}:${bob.port}');
  print('options: $options');

  final _Connection aliceOwner = await _Connection.authenticated(alice, clock);
  await _checkRemotePath(aliceOwner, bob, clock);
  final int maxClients = options.concurrency.reduce((a, b) => a > b ? a : b);
  final _Connection bobOwner = await _Connection.authenticated(bob, clock);
  for (int i = 0; i < maxClients; i++) {
    await aliceOwner.expectData('update:$_bob:${_remoteKey(i)} value');
    await bobOwner.expectData('update:${_localKey(i)} value');
  }
  await bobOwner.close();

  final List<_Result> results = [];
  for (final String workload in ['llookup', 'lookup']) {
    for (final int clients in options.concurrency) {
      for (int run = 1; run <= options.repeat; run++) {
        results.add(await _lookupRun(bob, clock,
            workload: workload,
            clients: clients,
            warmup: options.warmup,
            ops: options.lookups,
            run: run));
      }
    }
  }
  for (final int clients in options.concurrency) {
    for (int run = 1; run <= options.repeat; run++) {
      results.add(await _notifyRun(alice, bob, clock,
          clients: clients,
          warmup: options.warmup,
          ops: options.notifies,
          run: run,
          arrivalTimeout: options.arrivalTimeout));
    }
  }
  await aliceOwner.close();

  print('');
  print('median across runs, per workload and client count:');
  for (final String workload in ['llookup', 'lookup', 'notify']) {
    for (final int clients in options.concurrency) {
      final List<_Result> group = results
          .where((r) => r.workload == workload && r.clients == clients)
          .toList();
      print(_Result.median(group));
    }
  }
}

/// The shift the virtualenv applies to every atServer port when
/// VIRTUALENV_BASE_PORT is set: atServers start at BASE + 1 instead of 25000.
int _portShift() {
  final int? base =
      int.tryParse(Platform.environment['VIRTUALENV_BASE_PORT'] ?? '');
  return base == null ? 0 : base + 1 - _aliceUnshiftedPort;
}

/// Seeds the looked-up key, then proves a bypassCache lookup from @bob🛠
/// reaches @alice🛠's atServer: it must answer a value changed there since.
Future<void> _checkRemotePath(
    _Connection aliceOwner, _Target bob, Stopwatch clock) async {
  final _Connection bobClient = await _Connection.authenticated(bob, clock);
  await aliceOwner.expectData('update:$_bob:${_remoteKey(0)} before');
  final String before =
      await bobClient.expectData('lookup:bypassCache:true:${_remoteKey(0)}');
  await aliceOwner.expectData('update:$_bob:${_remoteKey(0)} value');
  final String after =
      await bobClient.expectData('lookup:bypassCache:true:${_remoteKey(0)}');
  print('remote-path check: lookup answered "$before", then "$after" after '
      '$_alice changed it (expected "before", then "value")');
  if (before != 'before' || after != 'value') {
    throw StateError('lookups from $_bob are not reaching $_alice\'s atServer');
  }
  await bobClient.close();
}

/// One run of [workload], `llookup` or `lookup`, each client on its own key.
Future<_Result> _lookupRun(_Target bob, Stopwatch clock,
    {required String workload,
    required int clients,
    required int warmup,
    required int ops,
    required int run}) async {
  final List<_Connection> connections = [
    for (int i = 0; i < clients; i++)
      await _Connection.authenticated(bob, clock)
  ];
  final List<String> commands = [
    for (int i = 0; i < clients; i++)
      workload == 'llookup'
          ? 'llookup:${_localKey(i)}'
          : 'lookup:bypassCache:true:${_remoteKey(i)}'
  ];
  Future<void> lookUp(int client, List<int>? latencies) async {
    final int start = clock.elapsedMicroseconds;
    final String value = await connections[client].expectData(commands[client]);
    if (value != 'value') {
      throw StateError('"${commands[client]}" answered "$value", '
          'expected "value"');
    }
    latencies?.add(clock.elapsedMicroseconds - start);
  }

  await _spread(clients, warmup, (c) => lookUp(c, null));
  final List<int> latencies = [];
  final int start = clock.elapsedMicroseconds;
  await _spread(clients, ops, (c) => lookUp(c, latencies));
  final int wall = clock.elapsedMicroseconds - start;
  for (final _Connection connection in connections) {
    await connection.close();
  }
  return _Result.print(workload, clients, run, wall, latencies);
}

Future<_Result> _notifyRun(_Target alice, _Target bob, Stopwatch clock,
    {required int clients,
    required int warmup,
    required int ops,
    required int run,
    required Duration arrivalTimeout}) async {
  final _Connection monitor = await _Connection.authenticated(alice, clock);
  final Map<String, int> sentAt = {};
  final Map<String, int> arrivedAt = {};
  Completer<void> allArrived = Completer();
  int expected = 0;
  final StreamSubscription<_Line> arrivals =
      monitor.notifications.listen((line) {
    final Map<String, dynamic> notification =
        jsonDecode(line.text.substring('notification:'.length).trim());
    final String id = notification['id'] as String;
    if (!sentAt.containsKey(id) || arrivedAt.containsKey(id)) {
      return;
    }
    arrivedAt[id] = line.at;
    if (arrivedAt.length == expected && !allArrived.isCompleted) {
      allArrived.complete();
    }
  });
  monitor.send('monitor $_namespace');

  final List<_Connection> connections = [
    for (int i = 0; i < clients; i++)
      await _Connection.authenticated(bob, clock)
  ];
  final String runTag = const Uuid().v4().substring(0, 8);
  int sequence = 0;
  Future<void> notify(int client) async {
    final String id = const Uuid().v4();
    final String key = 'n$runTag-${sequence++}.$_namespace$_bob';
    sentAt[id] = clock.elapsedMicroseconds;
    final String answer = await connections[client]
        .expectData('notify:id:$id:update:$_alice:$key:v');
    if (answer != id) {
      throw StateError('notify answered "$answer", expected its id $id');
    }
  }

  Future<void> sendAndAwait(int count) async {
    sentAt.clear();
    arrivedAt.clear();
    allArrived = Completer();
    expected = count;
    await _spread(clients, count, notify);
    await allArrived.future.timeout(arrivalTimeout,
        onTimeout: () => throw TimeoutException(
            '${count - arrivedAt.length} of $count notifications had not '
            'arrived at $_alice after $arrivalTimeout'));
  }

  await sendAndAwait(warmup);
  final int start = clock.elapsedMicroseconds;
  await sendAndAwait(ops);
  final int wall = arrivedAt.values.reduce((a, b) => a > b ? a : b) - start;
  final List<int> latencies = [
    for (final MapEntry<String, int> sent in sentAt.entries)
      arrivedAt[sent.key]! - sent.value
  ];
  await arrivals.cancel();
  await monitor.close();
  for (final _Connection connection in connections) {
    await connection.close();
  }
  return _Result.print('notify', clients, run, wall, latencies);
}

/// Runs [count] calls of [op] across [clients] clients, each issuing its share
/// in sequence and the clients in parallel; [op] is passed the client's index.
Future<void> _spread(
    int clients, int count, Future<void> Function(int client) op) async {
  await Future.wait([
    for (int c = 0; c < clients; c++)
      () async {
        final int share = count ~/ clients + (c < count % clients ? 1 : 0);
        for (int i = 0; i < share; i++) {
          await op(c);
        }
      }()
  ]);
}

class _Target {
  final String atSign;
  final String host;
  final int port;

  _Target(this.atSign, this.host, this.port);
}

/// One line from an atServer, with the moment it arrived.
class _Line {
  final String text;
  final int at;

  _Line(this.text, this.at);
}

/// A connection to one atServer that frames its responses by line.
class _Connection {
  static final RegExp _response =
      RegExp(r'^(?:@(?:[^@:\s]+@)?)?((?:data|error|notification):.*)$');

  final SecureSocket _socket;
  final Stopwatch _clock;
  final Queue<Completer<String>> _pending = Queue();
  final StreamController<_Line> _notifications = StreamController.broadcast();
  final List<int> _buffer = [];

  _Connection._(this._socket, this._clock) {
    _socket.listen(_onData,
        onError: (Object e) => _failAll('socket error: $e'),
        onDone: () => _failAll('socket closed'));
  }

  /// A connection to [target], authenticated as its atSign by PKAM.
  static Future<_Connection> authenticated(
      _Target target, Stopwatch clock) async {
    final _Connection connection = _Connection._(
        await SecureSocket.connect(target.host, target.port), clock);
    final String challenge =
        await connection.expectData('from:${target.atSign}');
    final String digest = AuthenticationUtils.generatePKAMDigest(
        pkamPrivateKeyMap[target.atSign]!, challenge);
    final String answer = await connection.expectData('pkam:$digest');
    if (answer != 'success') {
      throw StateError('pkam as ${target.atSign} answered "$answer"');
    }
    return connection;
  }

  Stream<_Line> get notifications => _notifications.stream;

  /// Sends [command] without waiting for an answer.
  void send(String command) => _socket.write('$command\n');

  /// Sends [command] and answers the text after `data:`, or throws on an
  /// `error:` response.
  Future<String> expectData(String command) async {
    final Completer<String> answer = Completer();
    _pending.add(answer);
    send(command);
    final String line = await answer.future;
    if (!line.startsWith('data:')) {
      throw StateError('"$command" answered "$line"');
    }
    return line.substring('data:'.length);
  }

  Future<void> close() async {
    await _socket.close();
    _socket.destroy();
  }

  void _onData(List<int> data) {
    final int at = _clock.elapsedMicroseconds;
    _buffer.addAll(data);
    int newline;
    while ((newline = _buffer.indexOf(0x0a)) >= 0) {
      final String text = utf8.decode(_buffer.sublist(0, newline));
      _buffer.removeRange(0, newline + 1);
      final Match? match = _response.firstMatch(text);
      if (match == null) {
        continue;
      }
      final String line = match.group(1)!;
      if (line.startsWith('notification:')) {
        _notifications.add(_Line(line, at));
      } else if (_pending.isNotEmpty) {
        _pending.removeFirst().complete(line);
      }
    }
  }

  void _failAll(String reason) {
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completeError(StateError(reason));
    }
  }
}

class _Result {
  final String workload;
  final int clients;
  final int run;
  final int wallMicros;
  final List<int> sortedMicros;

  _Result(this.workload, this.clients, this.run, this.wallMicros,
      this.sortedMicros);

  /// Builds the result of one run and prints its line.
  static _Result print(
      String workload, int clients, int run, int wallMicros, List<int> micros) {
    final _Result result =
        _Result(workload, clients, run, wallMicros, [...micros]..sort());
    stdout.writeln(result);
    return result;
  }

  /// The run whose throughput is the median of [runs].
  static String median(List<_Result> runs) {
    final List<_Result> byRate = [...runs]
      ..sort((a, b) => a.opsPerSecond.compareTo(b.opsPerSecond));
    return 'median of ${runs.length}: ${byRate[byRate.length ~/ 2]}';
  }

  double get opsPerSecond => sortedMicros.length / (wallMicros / 1e6);

  String _ms(double quantile) {
    final int index = ((sortedMicros.length - 1) * quantile).round();
    return (sortedMicros[index] / 1000).toStringAsFixed(2);
  }

  @override
  String toString() => '${workload.padRight(6)} clients=$clients run=$run '
      'n=${sortedMicros.length} wall_ms=${(wallMicros / 1000).toStringAsFixed(1)} '
      'ops_s=${opsPerSecond.toStringAsFixed(1)} p50_ms=${_ms(0.5)} '
      'p90_ms=${_ms(0.9)} p99_ms=${_ms(0.99)} max_ms=${_ms(1)}';
}

class _Options {
  String host = 'vip.ve.atsign.zone';
  int lookups = 2000;
  int notifies = 1000;
  List<int> concurrency = [1, 8];
  int warmup = 100;
  int repeat = 3;
  Duration arrivalTimeout = const Duration(seconds: 120);

  static _Options parse(List<String> arguments) {
    final _Options options = _Options();
    for (int i = 0; i < arguments.length; i += 2) {
      if (i + 1 >= arguments.length) {
        throw ArgumentError('${arguments[i]} needs a value');
      }
      final String value = arguments[i + 1];
      switch (arguments[i]) {
        case '--host':
          options.host = value;
        case '--lookups':
          options.lookups = int.parse(value);
        case '--notifies':
          options.notifies = int.parse(value);
        case '--concurrency':
          options.concurrency = value.split(',').map(int.parse).toList();
        case '--warmup':
          options.warmup = int.parse(value);
        case '--repeat':
          options.repeat = int.parse(value);
        case '--arrival-timeout':
          options.arrivalTimeout = Duration(seconds: int.parse(value));
        default:
          throw ArgumentError('unknown option ${arguments[i]}');
      }
    }
    return options;
  }

  @override
  String toString() => 'lookups=$lookups notifies=$notifies '
      'concurrency=${concurrency.join(',')} warmup=$warmup repeat=$repeat '
      'arrival-timeout=${arrivalTimeout.inSeconds}s';
}
