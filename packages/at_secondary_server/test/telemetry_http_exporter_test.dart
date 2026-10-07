import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_constants.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_http_exporter.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_signing_key.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:http/http.dart' as http;
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

  AtServerTelemetryHttpExporter exporter(
    String bootId, {
    Duration requestTimeout = const Duration(seconds: 10),
    Duration shutdownTimeout = const Duration(seconds: 10),
  }) {
    return AtServerTelemetryHttpExporter(
      endpoint: Uri.parse('https://collector.example.com'),
      producer: '$alice',
      bootId: bootId,
      key: key,
      client: _CallbackClient((http.BaseRequest request) async {
        requests.add(await _Request.read(request));
        return respond(request);
      }),
      requestTimeout: requestTimeout,
      shutdownTimeout: shutdownTimeout,
    );
  }

  AtTelemetryLogRecord heartbeat() => AtTelemetryLogRecord(
        eventName: atServerHeartbeatEventName,
        timestamp: DateTime.utc(2024),
      );

  group('AtServerTelemetryHttpExporter', () {
    test('sends a signed OTLP/JSON POST the collector can verify', () async {
      final String bootId = AtTelemetrySequence.newBootId();
      final AtServerTelemetryHttpExporter subject = exporter(bootId);

      expect(await subject.export(heartbeat(), resource), isTrue);

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

    test('sends each record at once, in sequence order', () async {
      final String bootId = AtTelemetrySequence.newBootId();
      final AtServerTelemetryHttpExporter subject = exporter(bootId);
      for (int index = 0; index < 3; index++) {
        unawaited(subject.export(heartbeat(), resource));
      }

      await subject.flush();

      expect(
        requests.map(
            (_Request request) => request.headers['at-telemetry-sequence']),
        <String>[
          'boot=$bootId;seq=0',
          'boot=$bootId;seq=1',
          'boot=$bootId;seq=2',
        ],
      );
    });

    for (final int status in <int>[200, 202, 204, 299]) {
      test('$status means delivered', () async {
        respond = (http.BaseRequest request) async => _status(status);

        expect(
          await exporter(AtTelemetrySequence.newBootId())
              .export(heartbeat(), resource),
          isTrue,
        );
      });
    }

    for (final int status in <int>[400, 401, 408, 413, 429, 500, 503]) {
      test('$status drops the record without a retry', () async {
        respond = (http.BaseRequest request) async => _status(status);
        final AtServerTelemetryHttpExporter subject =
            exporter(AtTelemetrySequence.newBootId());

        expect(await subject.export(heartbeat(), resource), isFalse);
        await subject.flush();

        expect(requests, hasLength(1));
      });
    }

    test('a network error drops the record and the next one still goes',
        () async {
      final String bootId = AtTelemetrySequence.newBootId();
      respond = (http.BaseRequest request) async =>
          throw const SocketException('refused');
      final AtServerTelemetryHttpExporter subject = exporter(bootId);

      expect(await subject.export(heartbeat(), resource), isFalse);

      respond = (http.BaseRequest request) async => _status(200);
      expect(await subject.export(heartbeat(), resource), isTrue);
      expect(
          requests.last.headers['at-telemetry-sequence'], 'boot=$bootId;seq=1');
    });

    test('aborts a request that runs past its deadline', () async {
      final Completer<void> aborted = Completer<void>();
      respond = (http.BaseRequest request) async {
        await (request as http.Abortable).abortTrigger;
        aborted.complete();
        throw http.RequestAbortedException(request.url);
      };
      final AtServerTelemetryHttpExporter subject = exporter(
        AtTelemetrySequence.newBootId(),
        requestTimeout: const Duration(milliseconds: 20),
      );

      expect(await subject.export(heartbeat(), resource), isFalse);
      expect(aborted.isCompleted, isTrue);
    });

    test('shutdown returns at its deadline and aborts the request', () async {
      final Completer<void> aborted = Completer<void>();
      respond = (http.BaseRequest request) async {
        await (request as http.Abortable).abortTrigger;
        aborted.complete();
        throw http.RequestAbortedException(request.url);
      };
      final AtServerTelemetryHttpExporter subject = exporter(
        AtTelemetrySequence.newBootId(),
        requestTimeout: const Duration(hours: 1),
        shutdownTimeout: const Duration(milliseconds: 50),
      );
      final Future<bool> delivery = subject.export(heartbeat(), resource);

      final Stopwatch stopwatch = Stopwatch()..start();
      await subject.shutdown();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(await delivery, isFalse);
      expect(aborted.isCompleted, isTrue);
      expect(await subject.export(heartbeat(), resource), isFalse);
    });

    test('rejects an endpoint that is not an OTLP base URL', () async {
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
            bootId: AtTelemetrySequence.newBootId(),
            key: key,
            client: _CallbackClient((http.BaseRequest _) async => _status(200)),
          ),
          throwsArgumentError,
          reason: endpoint,
        );
      }
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

    test('the heartbeat carries only the uptime', () async {
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

      expect(exports, isNotEmpty);
      for (final (AtTelemetryLogRecord record, AtTelemetryResource _)
          in exports) {
        expect(record.eventName, atServerHeartbeatEventName);
        expect(record.attributes.keys,
            <String>[AtTelemetryAttributes.atServerUptimeSeconds]);
        expect(record.attributes[AtTelemetryAttributes.atServerUptimeSeconds],
            isA<double>());
      }
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
