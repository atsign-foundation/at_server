import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_buffer.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_constants.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_http_exporter.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_signing_key.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  setUpAll(() async {
    await verbTestsSetUpAll();
  });

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
    requests = <_Request>[];
    respond = (http.BaseRequest request) async => _status(200);
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  AtServerTelemetryBuffer newBuffer(
      {String? bootId,
      int maxBytes = AtServerTelemetryBuffer.defaultMaxBytes}) {
    return AtServerTelemetryBuffer(
      bootId: bootId ?? AtTelemetrySequence.newBootId(),
      maxBytes: maxBytes,
    );
  }

  AtServerTelemetryHttpExporter exporter(
    AtServerTelemetryBuffer buffer, {
    int maxBatchRecords = 100,
    Duration requestTimeout = const Duration(seconds: 10),
    Duration shutdownTimeout = const Duration(seconds: 10),
  }) {
    return AtServerTelemetryHttpExporter(
      endpoint: Uri.parse('https://collector.example.com'),
      producer: '$alice',
      key: key,
      buffer: buffer,
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
          exporter(newBuffer(bootId: bootId));
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
      expect(signature.audience, 'collector.example.com:443');
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

    test('numbers batches in the order they enter the buffer', () async {
      final AtServerTelemetryHttpExporter subject =
          exporter(newBuffer(), maxBatchRecords: 1);
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
      test('$status removes the batch from the buffer', () async {
        respond = (http.BaseRequest request) async => _status(status);
        final AtServerTelemetryBuffer buffer = newBuffer();
        final AtServerTelemetryHttpExporter subject = exporter(buffer);
        final Future<bool> delivery = subject.export(heartbeat(), resource);

        await subject.flush();

        expect(await delivery, isTrue);
        expect(buffer.batchCount, 0);
      });
    }

    for (final int status in <int>[400, 401, 413, 415]) {
      test('$status drops the batch for good', () async {
        respond = (http.BaseRequest request) async => _status(status);
        final AtServerTelemetryBuffer buffer = newBuffer();
        final AtServerTelemetryHttpExporter subject = exporter(buffer);
        final Future<bool> delivery = subject.export(heartbeat(), resource);

        await subject.flush();
        await subject.flush();

        expect(await delivery, isFalse);
        expect(buffer.batchCount, 0);
        expect(requests, hasLength(1));
      });
    }

    for (final int status in <int>[408, 429, 500, 503]) {
      test('$status keeps the batch, with its sequence, for a retry', () async {
        respond = (http.BaseRequest request) async => _status(status);
        final AtServerTelemetryBuffer buffer = newBuffer();
        final AtServerTelemetryHttpExporter subject = exporter(buffer);
        bool? delivered;
        unawaited(subject
            .export(heartbeat(), resource)
            .then((bool value) => delivered = value));

        await subject.flush();
        expect(buffer.batchCount, 1);
        expect(delivered, isNull, reason: 'not delivered yet');

        respond = (http.BaseRequest request) async => _status(200);
        await subject.flush();
        await pumpEventQueue();

        expect(delivered, isTrue);
        expect(buffer.batchCount, 0);
        expect(requests, hasLength(2));
        expect(requests.first.headers['at-telemetry-sequence'],
            requests.last.headers['at-telemetry-sequence']);
        expect(requests.first.body, requests.last.body);
      });
    }

    test('a network error keeps the batch', () async {
      respond = (http.BaseRequest request) async =>
          throw const SocketException('refused');
      final AtServerTelemetryBuffer buffer = newBuffer();
      final AtServerTelemetryHttpExporter subject = exporter(buffer);
      unawaited(subject.export(heartbeat(), resource));

      await subject.flush();

      expect(buffer.batchCount, 1);
    });

    test('warns on the first failure after a success, and logs repeats at info',
        () async {
      final AtServerTelemetryHttpExporter subject = exporter(newBuffer());
      subject.logger.level = 'info';
      final List<LogRecord> records = <LogRecord>[];
      final StreamSubscription<LogRecord> subscription =
          subject.logger.logger.onRecord.listen(records.add);
      addTearDown(subscription.cancel);
      List<String> logged(Level level) => <String>[
            for (final LogRecord record in records)
              if (record.level == level) record.message,
          ];
      respond = (http.BaseRequest request) async =>
          throw const SocketException('collector unreachable');

      unawaited(subject.export(heartbeat(), resource));
      await subject.flush();
      await subject.flush();
      respond = (http.BaseRequest request) async => _status(200);
      await subject.flush();
      respond = (http.BaseRequest request) async =>
          throw const SocketException('collector unreachable');
      unawaited(subject.export(heartbeat(), resource));
      await subject.flush();

      expect(logged(Level.WARNING), hasLength(2),
          reason: 'one for each run of failures');
      expect(logged(Level.WARNING),
          everyElement(contains('collector unreachable')));
      expect(
          logged(Level.INFO),
          containsAll(<Matcher>[
            contains('collector unreachable'),
            contains('Telemetry sending recovered'),
          ]));
    });

    test('aborts a request that runs past its deadline', () async {
      final Completer<void> aborted = Completer<void>();
      respond = (http.BaseRequest request) async {
        await (request as http.Abortable).abortTrigger;
        aborted.complete();
        throw http.RequestAbortedException(request.url);
      };
      final AtServerTelemetryBuffer buffer = newBuffer();
      final AtServerTelemetryHttpExporter subject = exporter(
        buffer,
        requestTimeout: const Duration(milliseconds: 20),
      );
      unawaited(subject.export(heartbeat(), resource));

      await subject.flush();

      expect(aborted.isCompleted, isTrue);
      expect(buffer.batchCount, 1);
    });

    test('shutdown returns at its deadline and aborts the request', () async {
      final Completer<void> aborted = Completer<void>();
      respond = (http.BaseRequest request) async {
        await (request as http.Abortable).abortTrigger;
        aborted.complete();
        throw http.RequestAbortedException(request.url);
      };
      final AtServerTelemetryBuffer buffer = newBuffer();
      final AtServerTelemetryHttpExporter subject = exporter(
        buffer,
        requestTimeout: const Duration(hours: 1),
        shutdownTimeout: const Duration(milliseconds: 50),
      );
      final Future<bool> delivery = subject.export(heartbeat(), resource);

      final Stopwatch stopwatch = Stopwatch()..start();
      await subject.shutdown();
      await pumpEventQueue();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(aborted.isCompleted, isTrue);
      expect(await delivery, isFalse, reason: 'abandoned at shutdown');
      expect(buffer.batchCount, 0);
      expect(await subject.export(heartbeat(), resource), isFalse);
    });

    test('keeps no hold on a request once it has finished', () async {
      final List<Future<void>> abortTriggers = <Future<void>>[];
      respond = (http.BaseRequest request) async {
        abortTriggers.add((request as http.Abortable).abortTrigger!);
        return _status(200);
      };
      final AtServerTelemetryHttpExporter subject =
          exporter(newBuffer(), maxBatchRecords: 1);
      for (int index = 0; index < 3; index++) {
        expect(await subject.export(heartbeat(), resource), isTrue);
      }
      int fired = 0;
      for (final Future<void> trigger in abortTriggers) {
        unawaited(trigger.whenComplete(() => fired++));
      }

      await subject.shutdown();
      await pumpEventQueue();

      expect(abortTriggers, hasLength(3));
      expect(fired, 0,
          reason: 'shutdown reaching a finished request means the exporter '
              'still holds it, and so everything sent since boot');
    });

    test('gives up on a collector that never finishes connecting', () async {
      // Accepts the TCP connection but never answers the TLS handshake
      final ServerSocket silent =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final List<Socket> held = <Socket>[];
      silent.listen(held.add);
      final AtServerTelemetryBuffer buffer = newBuffer();
      final AtServerTelemetryHttpExporter subject =
          AtServerTelemetryHttpExporter(
        endpoint: Uri.parse('https://127.0.0.1:${silent.port}'),
        producer: '$alice',
        key: key,
        buffer: buffer,
        flushInterval: const Duration(hours: 1),
        requestTimeout: const Duration(milliseconds: 200),
        initialBackoff: const Duration(hours: 1),
        maxBackoff: const Duration(hours: 1),
      );
      unawaited(subject.export(heartbeat(), resource));

      try {
        await subject.flush().timeout(const Duration(seconds: 5));
        expect(buffer.batchCount, 1, reason: 'kept for a retry');
      } finally {
        await subject.shutdown();
        for (final Socket socket in held) {
          socket.destroy();
        }
        await silent.close();
      }
    });

    test('rejects an endpoint that is not an OTLP base URL', () async {
      final AtServerTelemetryBuffer buffer = newBuffer();
      for (final String endpoint in <String>[
        'ftp://collector.example.com',
        'https://collector.example.com/other',
        'https://user@collector.example.com',
        'https://collector.example.com?x=1',
        'http://collector.example.com',
        'https://[2001:db8::1]',
      ]) {
        expect(
          () => AtServerTelemetryHttpExporter(
            endpoint: Uri.parse(endpoint),
            producer: '$alice',
            key: key,
            buffer: buffer,
            client: _CallbackClient((http.BaseRequest _) async => _status(200)),
          ),
          throwsArgumentError,
          reason: endpoint,
        );
      }
    });

    test('names the endpoint port in the audience', () async {
      for (final (String endpoint, String audience) in <(String, String)>[
        ('https://collector.example.com:2777', 'collector.example.com:2777'),
        ('https://collector.example.com:443', 'collector.example.com:443'),
        ('http://localhost', 'localhost:80'),
      ]) {
        final AtServerTelemetryHttpExporter subject =
            AtServerTelemetryHttpExporter(
          endpoint: Uri.parse(endpoint),
          producer: '$alice',
          key: key,
          buffer: newBuffer(),
          client: _CallbackClient((http.BaseRequest _) async => _status(200)),
        );
        expect(subject.audience, audience, reason: endpoint);
        await subject.shutdown();
      }
    });
  });

  group('AtServerTelemetryBuffer', () {
    test('drops the oldest batches past its size limit', () async {
      final AtServerTelemetryBuffer buffer = newBuffer(maxBytes: 300);
      final List<Completer<bool>> deliveries = <Completer<bool>>[];
      for (int index = 0; index < 5; index++) {
        final Completer<bool> delivery = Completer<bool>();
        deliveries.add(delivery);
        buffer.add(
          utf8.encode('{"n":$index,"padding":"${'x' * 100}"}'),
          <Completer<bool>>[delivery],
        );
      }

      // Each body is 120 bytes, so only the newest two fit under 300
      expect(buffer.bytes, lessThanOrEqualTo(300));
      expect(buffer.batchCount, 2);
      expect(buffer.oldest!.sequence.number, 3);
      for (final Completer<bool> delivery in deliveries.take(3)) {
        expect(await delivery.future, isFalse);
      }
      for (final Completer<bool> delivery in deliveries.skip(3)) {
        expect(delivery.isCompleted, isFalse);
      }
    });

    test('abandoning reports every record as not delivered', () async {
      final AtServerTelemetryBuffer buffer = newBuffer();
      final Completer<bool> delivery = Completer<bool>();
      buffer.add(utf8.encode('{}'), <Completer<bool>>[delivery]);

      buffer.abandonAll();

      expect(await delivery.future, isFalse);
      expect(buffer.batchCount, 0);
      expect(buffer.bytes, 0);
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
          final AtServerTelemetryHttpExporter subject = exporter(newBuffer());
          telemetry = AtServerTelemetry(
            heartbeatInterval: const Duration(milliseconds: 10),
          )..enable(
              exporter: subject,
              serverId: '$alice',
              bootId: 'boot-1',
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
          exports.singleWhere(
              ((AtTelemetryLogRecord, AtTelemetryResource) export) =>
                  export.$1.eventName == atServerHeartbeatEventName);
      expect(record.eventName, 'atsign.atserver.lifecycle.heartbeat');
      expect(resource.attributes, <String, Object?>{
        AtTelemetryAttributes.serviceName: atServerServiceName,
        AtTelemetryAttributes.atServerId: '$alice',
        AtTelemetryAttributes.serviceInstanceId: 'boot-1',
        AtTelemetryAttributes.serviceVersion: '3.0.0',
      });
    });

    test('the heartbeat carries no attributes', () async {
      final List<(AtTelemetryLogRecord, AtTelemetryResource)> exports =
          <(AtTelemetryLogRecord, AtTelemetryResource)>[];
      final AtServerTelemetry telemetry = AtServerTelemetry(
        heartbeatInterval: const Duration(milliseconds: 10),
      )..enable(
          exporter: _RecordingExporter(exports),
          serverId: '$alice',
          bootId: 'boot-1',
        );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await telemetry.shutdown();

      final AtTelemetryLogRecord heartbeat = exports
          .firstWhere(((AtTelemetryLogRecord, AtTelemetryResource) export) =>
              export.$1.eventName == atServerHeartbeatEventName)
          .$1;
      expect(heartbeat.attributes, isEmpty);
    });

    test(
        'sends started when enabled, and stopped before the exporter shuts '
        'down', () async {
      final List<(AtTelemetryLogRecord, AtTelemetryResource)> exports =
          <(AtTelemetryLogRecord, AtTelemetryResource)>[];
      final _RecordingExporter exporter = _RecordingExporter(exports);
      final AtServerTelemetry telemetry =
          AtServerTelemetry(heartbeatInterval: null)
            ..enable(
              exporter: exporter,
              serverId: '$alice',
              bootId: 'boot-1',
            );
      List<String?> names() => exports
          .map(((AtTelemetryLogRecord, AtTelemetryResource) export) =>
              export.$1.eventName)
          .toList();

      expect(names(), <String>[atServerStartedEventName]);

      await telemetry.shutdown();

      expect(names(),
          <String>[atServerStartedEventName, atServerStoppedEventName]);
      expect(exporter.exportsAtShutdown, 2,
          reason: 'stopped must reach the exporter before it shuts down');
      expect(exports.first.$1.attributes, isEmpty);
      expect(exports.last.$1.attributes, isEmpty);
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

      expect(
          exports.map(((AtTelemetryLogRecord, AtTelemetryResource) export) =>
              export.$1.eventName),
          <String>[atServerStartedEventName, atServerStoppedEventName]);
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
  int? exportsAtShutdown;

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
  Future<void> shutdown() async {
    exportsAtShutdown = exports.length;
  }
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
