import 'dart:async';

import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_constants.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_exporter.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_telemetry/at_telemetry_otel.dart';
import 'package:crypton/crypton.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late RSAKeypair keys;

  setUp(() => keys = RSAKeypair.fromRandom());

  Future<AtTelemetryOtelSignedHttpExporter> create(http.Client client) async {
    final AtTelemetryOtelSignedHttpExporter? exporter =
        await createAtServerTelemetryExporter(
      serverId: '@denise',
      signingKey: keys.privateKey.toString(),
      yaml: const <String, Object?>{},
      environment: <String, String>{
        'AT_TELEMETRY_ENDPOINT': 'https://collector.example.org:4318',
      },
      client: client,
    );
    return exporter!;
  }

  test('sends each event as a signed OTLP request', () async {
    final List<http.Request> delivered = <http.Request>[];
    final AtTelemetryOtelSignedHttpExporter exporter = await create(
      MockClient((http.Request request) async {
        delivered.add(request);
        return http.Response('', 200);
      }),
    );

    await exporter.export(_event(atServerHeartbeatEventName));
    await exporter.shutdown();

    expect(delivered, hasLength(1));
    final http.Request request = delivered.single;
    expect(request.url.path, '/v1/logs');
    expect(request.followRedirects, isFalse);
    expect(request.headers, isNot(contains('authorization')));
    final AtTelemetryOtelHttpSignature signature =
        AtTelemetryOtelHttpSignature.parse(
      input: request.headers[AtTelemetryOtelHttpSignature.inputHeader]!,
      signature: request.headers[AtTelemetryOtelHttpSignature.signatureHeader]!,
      digest: request.headers[AtTelemetryOtelHttpSignature.digestHeader]!,
      audience: request.headers[AtTelemetryOtelHttpSignature.audienceHeader]!,
    );
    expect(signature.keyId, '@denise');
    expect(signature.audience, 'collector.example.org');
    expect(signature.matchesBody(request.bodyBytes), isTrue);
    expect(
      await signature.verify(
        path: request.url.path,
        publicKey: keys.publicKey.toString(),
      ),
      isTrue,
    );
    expect(
      const AtTelemetryOtelLogsCodec()
          .decodeExportRequest(request.bodyBytes)
          .single
          .name,
      atServerHeartbeatEventName,
    );
  });

  test('sends gauges as signed OTLP metrics', () async {
    final List<http.Request> delivered = <http.Request>[];
    final AtTelemetryOtelSignedHttpExporter exporter = await create(
      MockClient((http.Request request) async {
        delivered.add(request);
        return http.Response('', 200);
      }),
    );
    final AtServerTelemetry telemetry = AtServerTelemetry()
      ..enable(exporter: exporter, serverId: '@denise');

    telemetry.pushGauge('$atServerTelemetryEventPrefix.uptime', 12, unit: 's');
    await telemetry.shutdown();

    expect(delivered, hasLength(1));
    expect(delivered.single.url.path, '/v1/metrics');
    expect(delivered.single.headers,
        contains(AtTelemetryOtelHttpSignature.signatureHeader));
  });

  test('does not follow redirects', () async {
    final List<http.Request> requests = <http.Request>[];
    final AtTelemetryOtelSignedHttpExporter exporter = await create(
      MockClient((http.Request request) async {
        requests.add(request);
        return http.Response('', 302, headers: <String, String>{
          'location': 'https://other.example.org/v1/logs',
        });
      }),
    );

    await exporter.export(_event(atServerHeartbeatEventName));
    await exporter.shutdown();

    expect(requests, hasLength(1));
    expect(requests.single.followRedirects, isFalse);
  });

  test('drops an event that the collector rejects', () async {
    int requests = 0;
    final List<Object> errors = <Object>[];
    final AtTelemetryOtelSignedHttpExporter exporter =
        AtTelemetryOtelSignedHttpExporter(
      endpoint: Uri.parse('https://collector.example.org'),
      serviceName: 'at_secondary_server',
      keyId: '@denise',
      audience: 'collector.example.org',
      signer: AtTelemetryRsaSigner.fromBase64(keys.privateKey.toString()),
      client: MockClient((http.Request request) async {
        requests++;
        return http.Response('', 401);
      }),
      onError: errors.add,
    );

    await exporter.export(_event(atServerHeartbeatEventName));
    await exporter.shutdown();

    expect(requests, 1);
    expect(errors, hasLength(1));
  });

  test('the backlog limit drops events while the collector is stuck', () async {
    final Completer<http.Response> stuck = Completer<http.Response>();
    final List<String> delivered = <String>[];
    final AtTelemetryOtelSignedHttpExporter exporter = await create(
      MockClient((http.Request request) async {
        delivered.add(const AtTelemetryOtelLogsCodec()
            .decodeExportRequest(request.bodyBytes)
            .single
            .name);
        return stuck.future;
      }),
    );
    final AtServerTelemetry telemetry = AtServerTelemetry(maxPendingEvents: 2)
      ..enable(exporter: exporter, serverId: '@denise');

    telemetry.push('$atServerTelemetryEventPrefix.first');
    telemetry.push('$atServerTelemetryEventPrefix.second');
    telemetry.push('$atServerTelemetryEventPrefix.third');
    await telemetry.flush(timeout: const Duration(milliseconds: 50));
    stuck.complete(http.Response('', 200));
    await telemetry.shutdown();

    expect(delivered, <String>[
      'atsign.atserver.first',
      'atsign.atserver.second',
    ]);
  });
}

AtTelemetryEvent _event(String name) => AtTelemetryEvent(
      name: name,
      timestamp: DateTime.utc(2026, 9, 28),
      attributes: const <String, Object?>{'atsign.atserver.id': '@denise'},
    );
