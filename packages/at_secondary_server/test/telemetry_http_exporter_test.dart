import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_constants.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_http_exporter.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_outbox.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_signing_key.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  late Directory outboxDirectory;
  late AtServerTelemetrySigningKey key;
  late List<_Request> requests;
  late Future<http.StreamedResponse> Function(http.BaseRequest request) respond;
  final AtTelemetryResource resource = AtTelemetryResource(
    serviceName: atServerServiceName,
    attributes: AtTelemetryResource.atServer(atServerId: '$alice'),
  );

  setUp(() async {
    await verbTestsSetUp();
    key =
        await AtServerTelemetrySigningKey.loadOrCreate(keyValueStore, '$alice');
    outboxDirectory =
        await Directory.systemTemp.createTemp('telemetry_outbox_test');
    requests = <_Request>[];
    respond = (http.BaseRequest request) async => _status(200);
  });

  tearDown(() async {
    await verbTestsTearDown();
    if (await outboxDirectory.exists()) {
      await outboxDirectory.delete(recursive: true);
    }
  });

  Future<AtServerTelemetryOutbox> openOutbox(String bootId,
      {int maxBytes = AtServerTelemetryOutbox.defaultMaxBytes,
      Duration maxAge = AtServerTelemetryOutbox.defaultMaxAge,
      DateTime Function()? now}) {
    return AtServerTelemetryOutbox.open(
      directory: outboxDirectory,
      bootId: bootId,
      maxBytes: maxBytes,
      maxAge: maxAge,
      now: now,
    );
  }

  AtServerTelemetryHttpExporter exporter(
    AtServerTelemetryOutbox outbox, {
    int maxBatchRecords = 100,
    Duration requestTimeout = const Duration(seconds: 10),
    Duration shutdownTimeout = const Duration(seconds: 10),
  }) {
    return AtServerTelemetryHttpExporter(
      endpoint: Uri.parse('https://collector.example.com'),
      producer: '$alice',
      key: key,
      outbox: outbox,
      client: _CallbackClient((http.BaseRequest request) async {
        requests.add(await _Request.read(request));
        return respond(request);
      }),
      maxBatchRecords: maxBatchRecords,
      flushInterval: const Duration(hours: 1),
      requestTimeout: requestTimeout,
      initialBackoff: const Duration(hours: 1),
      maxBackoff: const Duration(hours: 1),
      shutdownTimeout: shutdownTimeout,
      random: Random(1),
    );
  }

  AtTelemetryLogRecord heartbeat() => AtTelemetryLogRecord(
        eventName: atServerHeartbeatEventName,
        timestamp: DateTime.utc(2024),
      );

  group('AtServerTelemetryHttpExporter', () {
    test('sends a signed OTLP/JSON POST the collector can verify', () async {
      final String bootId = AtTelemetrySequence.newBootId();
      final AtServerTelemetryHttpExporter subject =
          exporter(await openOutbox(bootId));
      final Future<bool> delivery = subject.export(heartbeat(), resource);

      await subject.flush();

      expect(await delivery, isTrue);
      final _Request request = requests.single;
      expect(request.method, 'POST');
      expect(request.url, Uri.parse('https://collector.example.com/v1/logs'));
      expect(request.headers['content-type'], 'application/json');

      final AtTelemetryHttpSignature signature = AtTelemetryHttpSignature.parse(
        input: request.headers['signature-input']!,
        signature: request.headers['signature']!,
        digest: request.headers['content-digest']!,
        audience: request.headers['at-telemetry-audience']!,
        producer: request.headers['at-telemetry-producer']!,
        sequence: request.headers['at-telemetry-sequence']!,
      );
      expect(signature.keyId, key.keyId);
      expect(signature.producer, '$alice');
      expect(signature.audience, 'collector.example.com');
      expect(
          signature.sequence, AtTelemetrySequence(bootId: bootId, number: 0));
      expect(signature.matchesBody(request.body), isTrue);
      expect(
        await signature.verify(
          path: '/v1/logs',
          publicKey: AtTelemetryPublicKeyRecord.parse((await keyValueStore
                      .get('public:_at_telemetry_signing_publickey.__atserver'
                          '$alice'))!
                  .data!)
              .publicKey,
        ),
        isTrue,
      );
      expect(
        const AtTelemetryLogsCodec()
            .decode(utf8.decode(request.body))
            .single
            .records
            .single
            .eventName,
        atServerHeartbeatEventName,
      );
    });

    test('numbers batches in the order they enter the outbox', () async {
      final AtServerTelemetryHttpExporter subject = exporter(
          await openOutbox(AtTelemetrySequence.newBootId()),
          maxBatchRecords: 1);
      for (int index = 0; index < 3; index++) {
        unawaited(subject.export(heartbeat(), resource));
      }

      await subject.flush();

      expect(
        requests.map((_Request request) =>
            request.headers['at-telemetry-sequence']!.split(';seq=').last),
        <String>['0', '1', '2'],
      );
    });

    for (final int status in <int>[200, 202, 204, 299]) {
      test('$status removes the batch from the outbox', () async {
        respond = (http.BaseRequest request) async => _status(status);
        final AtServerTelemetryOutbox outbox =
            await openOutbox(AtTelemetrySequence.newBootId());
        final AtServerTelemetryHttpExporter subject = exporter(outbox);
        unawaited(subject.export(heartbeat(), resource));

        await subject.flush();

        expect(outbox.batchCount, 0);
        expect(outbox.droppedSinceBoot, 0);
      });
    }

    for (final int status in <int>[400, 401, 413, 415]) {
      test('$status drops the batch for good', () async {
        respond = (http.BaseRequest request) async => _status(status);
        final AtServerTelemetryOutbox outbox =
            await openOutbox(AtTelemetrySequence.newBootId());
        final AtServerTelemetryHttpExporter subject = exporter(outbox);
        unawaited(subject.export(heartbeat(), resource));

        await subject.flush();
        await subject.flush();

        expect(outbox.batchCount, 0);
        expect(requests, hasLength(1));
      });
    }

    for (final int status in <int>[408, 429, 500, 503]) {
      test('$status keeps the batch, with its sequence, for a retry', () async {
        respond = (http.BaseRequest request) async => _status(status);
        final AtServerTelemetryOutbox outbox =
            await openOutbox(AtTelemetrySequence.newBootId());
        final AtServerTelemetryHttpExporter subject = exporter(outbox);
        unawaited(subject.export(heartbeat(), resource));

        await subject.flush();
        expect(outbox.batchCount, 1);

        respond = (http.BaseRequest request) async => _status(200);
        await subject.flush();

        expect(outbox.batchCount, 0);
        expect(requests, hasLength(2));
        expect(requests.first.headers['at-telemetry-sequence'],
            requests.last.headers['at-telemetry-sequence']);
        expect(requests.first.body, requests.last.body);
      });
    }

    test('a network error keeps the batch', () async {
      respond = (http.BaseRequest request) async =>
          throw const SocketException('refused');
      final AtServerTelemetryOutbox outbox =
          await openOutbox(AtTelemetrySequence.newBootId());
      final AtServerTelemetryHttpExporter subject = exporter(outbox);
      unawaited(subject.export(heartbeat(), resource));

      await subject.flush();

      expect(outbox.batchCount, 1);
    });

    test('aborts a request that runs past its deadline', () async {
      final Completer<void> aborted = Completer<void>();
      respond = (http.BaseRequest request) async {
        await (request as http.Abortable).abortTrigger;
        aborted.complete();
        throw http.RequestAbortedException(request.url);
      };
      final AtServerTelemetryOutbox outbox =
          await openOutbox(AtTelemetrySequence.newBootId());
      final AtServerTelemetryHttpExporter subject = exporter(
        outbox,
        requestTimeout: const Duration(milliseconds: 20),
      );
      unawaited(subject.export(heartbeat(), resource));

      await subject.flush();

      expect(aborted.isCompleted, isTrue);
      expect(outbox.batchCount, 1);
    });

    test('shutdown returns at its deadline and aborts the request', () async {
      final Completer<void> aborted = Completer<void>();
      respond = (http.BaseRequest request) async {
        await (request as http.Abortable).abortTrigger;
        aborted.complete();
        throw http.RequestAbortedException(request.url);
      };
      final AtServerTelemetryOutbox outbox =
          await openOutbox(AtTelemetrySequence.newBootId());
      final AtServerTelemetryHttpExporter subject = exporter(
        outbox,
        requestTimeout: const Duration(hours: 1),
        shutdownTimeout: const Duration(milliseconds: 50),
      );
      unawaited(subject.export(heartbeat(), resource));

      final Stopwatch stopwatch = Stopwatch()..start();
      await subject.shutdown();
      await pumpEventQueue();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(aborted.isCompleted, isTrue);
      expect(outbox.batchCount, 1, reason: 'kept for the next boot');
      expect(await subject.export(heartbeat(), resource), isFalse);
    });

    test('a batch left by an earlier boot keeps its boot id and number',
        () async {
      respond = (http.BaseRequest request) async => _status(503);
      final String firstBoot = AtTelemetrySequence.newBootId();
      final AtServerTelemetryHttpExporter first =
          exporter(await openOutbox(firstBoot));
      unawaited(first.export(heartbeat(), resource));
      await first.shutdown();

      respond = (http.BaseRequest request) async => _status(200);
      final String secondBoot = AtTelemetrySequence.newBootId();
      final AtServerTelemetryOutbox outbox = await openOutbox(secondBoot);
      expect(outbox.batchCount, 1);
      final AtServerTelemetryHttpExporter second = exporter(outbox);
      unawaited(second.export(heartbeat(), resource));
      await second.flush();

      expect(
        requests.map(
            (_Request request) => request.headers['at-telemetry-sequence']),
        <String>[
          'boot=$firstBoot;seq=0',
          'boot=$firstBoot;seq=0',
          'boot=$secondBoot;seq=0',
        ],
      );
      expect(outbox.batchCount, 0);
    });

    test('gives up on a collector that never finishes connecting', () async {
      // Accepts the TCP connection but never answers the TLS handshake
      final ServerSocket silent =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final List<Socket> held = <Socket>[];
      silent.listen(held.add);
      final AtServerTelemetryOutbox outbox =
          await openOutbox(AtTelemetrySequence.newBootId());
      final AtServerTelemetryHttpExporter subject =
          AtServerTelemetryHttpExporter(
        endpoint: Uri.parse('https://127.0.0.1:${silent.port}'),
        producer: '$alice',
        key: key,
        outbox: outbox,
        flushInterval: const Duration(hours: 1),
        requestTimeout: const Duration(milliseconds: 200),
        initialBackoff: const Duration(hours: 1),
        maxBackoff: const Duration(hours: 1),
      );
      unawaited(subject.export(heartbeat(), resource));

      try {
        await subject.flush().timeout(const Duration(seconds: 5));
        expect(outbox.batchCount, 1, reason: 'kept for a retry');
      } finally {
        await subject.shutdown();
        for (final Socket socket in held) {
          socket.destroy();
        }
        await silent.close();
      }
    });

    test('rejects an endpoint that is not an OTLP base URL', () async {
      final AtServerTelemetryOutbox outbox =
          await openOutbox(AtTelemetrySequence.newBootId());
      for (final String endpoint in <String>[
        'ftp://collector.example.com',
        'https://collector.example.com/other',
        'https://user@collector.example.com',
        'https://collector.example.com?x=1',
      ]) {
        expect(
          () => AtServerTelemetryHttpExporter(
            endpoint: Uri.parse(endpoint),
            producer: '$alice',
            key: key,
            outbox: outbox,
            client: _CallbackClient((http.BaseRequest _) async => _status(200)),
          ),
          throwsArgumentError,
          reason: endpoint,
        );
      }
    });
  });

  group('AtServerTelemetryOutbox', () {
    test('drops the oldest batches past its size limit', () async {
      final AtServerTelemetryOutbox outbox = await openOutbox(
        AtTelemetrySequence.newBootId(),
        maxBytes: 600,
      );
      for (int index = 0; index < 5; index++) {
        await outbox.add('{"n":$index,"padding":"${'x' * 100}"}');
      }

      expect(outbox.bytes, lessThanOrEqualTo(600));
      expect(outbox.droppedSinceBoot, greaterThan(0));
      expect(outbox.batchCount + outbox.droppedSinceBoot, 5);
      expect(outbox.oldest!.sequence.number, outbox.droppedSinceBoot);
      expect(outbox.health, <String, Object?>{
        atServerOutboxBatchesAttribute: outbox.batchCount,
        atServerOutboxBytesAttribute: outbox.bytes,
        atServerOutboxDroppedAttribute: outbox.droppedSinceBoot,
      });
    });

    test('drops batches past its age limit when it opens', () async {
      DateTime now = DateTime.utc(2024);
      final AtServerTelemetryOutbox first = await openOutbox(
        AtTelemetrySequence.newBootId(),
        now: () => now,
      );
      await first.add('{}');

      now = DateTime.utc(2024, 1, 9);
      final AtServerTelemetryOutbox second = await openOutbox(
        AtTelemetrySequence.newBootId(),
        now: () => now,
      );

      expect(second.batchCount, 0);
      expect(second.droppedSinceBoot, 1);
    });

    test('removes unreadable files and leftovers when it opens', () async {
      await outboxDirectory.create(recursive: true);
      await File('${outboxDirectory.path}/broken.json').writeAsString('nope');
      await File('${outboxDirectory.path}/half.json.tmp').writeAsString('{');

      final AtServerTelemetryOutbox outbox =
          await openOutbox(AtTelemetrySequence.newBootId());

      expect(outbox.batchCount, 0);
      expect(await outboxDirectory.list().toList(), isEmpty);
    });
  });

  // The atServer runs inside a zone that stops the server on any uncaught
  // error other than a SocketException, so telemetry must never let one out
  group('a failing collector never reaches the zone', () {
    final Map<String, Future<http.StreamedResponse> Function()> failures =
        <String, Future<http.StreamedResponse> Function()>{
      'a 500': () async => _status(500),
      'a 401': () async => _status(401),
      'a SocketException': () async => throw const SocketException('refused'),
      'a HandshakeException': () async =>
          throw const HandshakeException('bad certificate'),
      'a StateError': () async => throw StateError('broken client'),
      'a response stream that fails': () async => http.StreamedResponse(
          Stream<List<int>>.error(const HttpException('reset')), 200),
    };

    for (final MapEntry<String,
        Future<http.StreamedResponse> Function()> failure in failures.entries) {
      test('on ${failure.key}', () async {
        final List<Object> uncaught = <Object>[];
        late AtServerTelemetry telemetry;

        await runZonedGuarded(() async {
          respond = (http.BaseRequest request) => failure.value();
          final AtServerTelemetryHttpExporter subject =
              exporter(await openOutbox(AtTelemetrySequence.newBootId()));
          telemetry = AtServerTelemetry(
            heartbeatInterval: const Duration(milliseconds: 10),
          )..enable(
              exporter: subject,
              serverId: '$alice',
              bootId: 'boot-1',
              health: () => subject.outboxHealth,
            );
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await telemetry.flush();
          await telemetry.shutdown(timeout: const Duration(seconds: 5));
        }, (Object error, StackTrace _) => uncaught.add(error));

        expect(requests, isNotEmpty);
        expect(uncaught, isEmpty);
        expect(telemetry.isEnabled, isFalse);
      });
    }

    test('an outbox that cannot be written drops records quietly', () async {
      final List<Object> uncaught = <Object>[];
      late bool delivered;

      await runZonedGuarded(() async {
        final AtServerTelemetryOutbox outbox =
            await openOutbox(AtTelemetrySequence.newBootId());
        final AtServerTelemetryHttpExporter subject = exporter(outbox);
        await outboxDirectory.delete(recursive: true);
        final Future<bool> delivery = subject.export(heartbeat(), resource);
        await subject.flush();
        delivered = await delivery;
        await subject.shutdown();
      }, (Object error, StackTrace _) => uncaught.add(error));

      expect(delivered, isFalse);
      expect(requests, isEmpty);
      expect(uncaught, isEmpty);
    });
  });

  group('AtServerTelemetry', () {
    test('stamps the resource with the atServer id and boot id', () async {
      final List<(AtTelemetryLogRecord, AtTelemetryResource)> exports =
          <(AtTelemetryLogRecord, AtTelemetryResource)>[];
      final AtServerTelemetry telemetry =
          AtServerTelemetry(heartbeatInterval: null)
            ..enable(
              exporter: _RecordingExporter(exports),
              serverId: '$alice',
              bootId: 'boot-1',
              serviceVersion: '3.0.0',
            );

      telemetry.emitEvent(atServerHeartbeatEventName);
      await telemetry.shutdown();

      final (AtTelemetryLogRecord record, AtTelemetryResource resource) =
          exports.single;
      expect(record.eventName, 'atsign.atserver.lifecycle.heartbeat');
      expect(resource.attributes, <String, Object?>{
        AtTelemetryAttributes.serviceName: atServerServiceName,
        AtTelemetryAttributes.atServerId: '$alice',
        AtTelemetryAttributes.serviceInstanceId: 'boot-1',
        AtTelemetryAttributes.serviceVersion: '3.0.0',
      });
    });

    test('the heartbeat carries uptime and outbox health', () async {
      final List<(AtTelemetryLogRecord, AtTelemetryResource)> exports =
          <(AtTelemetryLogRecord, AtTelemetryResource)>[];
      final AtServerTelemetry telemetry = AtServerTelemetry(
        heartbeatInterval: const Duration(milliseconds: 10),
      )..enable(
          exporter: _RecordingExporter(exports),
          serverId: '$alice',
          bootId: 'boot-1',
          health: () => <String, Object?>{
            atServerOutboxBatchesAttribute: 3,
          },
        );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await telemetry.shutdown();

      final AtTelemetryLogRecord heartbeat = exports.first.$1;
      expect(heartbeat.eventName, atServerHeartbeatEventName);
      expect(heartbeat.attributes.keys, <String>[
        atServerOutboxBatchesAttribute,
        AtTelemetryAttributes.atServerUptimeSeconds,
      ]);
      expect(heartbeat.attributes[atServerOutboxBatchesAttribute], 3);
      expect(heartbeat.attributes[AtTelemetryAttributes.atServerUptimeSeconds],
          isA<double>());
    });

    test('ignores events outside atsign.atserver', () async {
      final List<(AtTelemetryLogRecord, AtTelemetryResource)> exports =
          <(AtTelemetryLogRecord, AtTelemetryResource)>[];
      final AtServerTelemetry telemetry =
          AtServerTelemetry(heartbeatInterval: null)
            ..enable(
              exporter: _RecordingExporter(exports),
              serverId: '$alice',
              bootId: 'boot-1',
            );

      telemetry.emitEvent('app.started');
      telemetry.emitEvent('atsign.atserver.');
      await telemetry.shutdown();

      expect(exports, isEmpty);
    });

    test('shutdown returns at its deadline when the exporter hangs', () async {
      final AtServerTelemetry telemetry =
          AtServerTelemetry(heartbeatInterval: null)
            ..enable(
              exporter: _HangingExporter(),
              serverId: '$alice',
              bootId: 'boot-1',
            );

      final Stopwatch stopwatch = Stopwatch()..start();
      await telemetry.shutdown(timeout: const Duration(milliseconds: 50));

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(telemetry.isEnabled, isFalse);
    });
  });
}

http.StreamedResponse _status(int status) =>
    http.StreamedResponse(const Stream<List<int>>.empty(), status);

final class _Request {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int> body;

  _Request(this.method, this.url, this.headers, this.body);

  static Future<_Request> read(http.BaseRequest request) async {
    return _Request(
      request.method,
      request.url,
      Map<String, String>.of(request.headers),
      request is http.Request ? request.bodyBytes : <int>[],
    );
  }
}

final class _CallbackClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      _handler;

  _CallbackClient(this._handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);
}

final class _RecordingExporter implements AtTelemetryLogRecordExporter {
  final List<(AtTelemetryLogRecord, AtTelemetryResource)> exports;

  _RecordingExporter(this.exports);

  @override
  Future<bool> export(
    AtTelemetryLogRecord logRecord,
    AtTelemetryResource resource,
  ) async {
    exports.add((logRecord, resource));
    return true;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}
}

final class _HangingExporter implements AtTelemetryLogRecordExporter {
  @override
  Future<bool> export(
    AtTelemetryLogRecord logRecord,
    AtTelemetryResource resource,
  ) =>
      Completer<bool>().future;

  @override
  Future<void> flush() => Completer<void>().future;

  @override
  Future<void> shutdown() => Completer<void>().future;
}
