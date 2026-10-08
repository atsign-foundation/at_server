import 'package:at_secondary/src/telemetry/at_server_telemetry_exporter.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_http_exporter.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_key_guard.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  Future<AtServerTelemetryHttpExporter?> create(String? endpoint) {
    return createAtServerTelemetryExporter(
      endpoint: endpoint,
      atSign: '$alice',
      bootId: AtTelemetrySequence.newBootId(),
      keyStore: keyValueStore,
      client: _UnusedClient(),
    );
  }

  group('createAtServerTelemetryExporter', () {
    for (final (String endpoint, String logsUrl, String audience)
        in <(String, String, String)>[
      (
        'collector.example.com:2777',
        'https://collector.example.com:2777/v1/logs',
        'collector.example.com:2777'
      ),
      (
        'https://collector.example.com',
        'https://collector.example.com/v1/logs',
        'collector.example.com:443'
      ),
      (
        'http://localhost:4318',
        'http://localhost:4318/v1/logs',
        'localhost:4318'
      ),
      (
        'http://127.0.0.1:4318',
        'http://127.0.0.1:4318/v1/logs',
        '127.0.0.1:4318'
      ),
    ]) {
      test('accepts $endpoint', () async {
        final AtServerTelemetryHttpExporter? exporter = await create(endpoint);

        expect(exporter, isNotNull);
        expect(exporter!.endpoint, Uri.parse(logsUrl));
        expect(exporter.audience, audience);
        expect(await keyValueStore.exists(AtServerTelemetryKeyGuard.secretKey),
            isTrue);
        await exporter.shutdown();
      });
    }

    for (final String? endpoint in <String?>[
      null,
      '',
      'http://collector.example.com:4318',
      'https://collector.example.com/other',
      'https://[2001:db8::1]:443',
      'http://[::1]:4318',
      'ftp://collector.example.com',
    ]) {
      test('refuses "$endpoint" and creates no signing key', () async {
        expect(await create(endpoint), isNull);
        expect(await keyValueStore.exists(AtServerTelemetryKeyGuard.secretKey),
            isFalse);
      });
    }
  });
}

final class _UnusedClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw StateError('no request is expected');
}
