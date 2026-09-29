import 'dart:async';
import 'dart:io';

import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_exporter.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_constants.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_telemetry/at_telemetry_otel.dart';
import 'package:crypton/crypton.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory storage;
  late RSAKeypair keys;

  setUp(() async {
    storage = await Directory.systemTemp.createTemp('atserver-telemetry-');
    keys = RSAKeypair.fromRandom();
  });
  tearDown(() => storage.delete(recursive: true));

  AtServerTelemetryExporter open({
    required http.Client client,
    int maxRecords = 1000,
    int maxBytes = 10 * 1024 * 1024,
    bool persistToDisk = true,
  }) {
    return AtServerTelemetryExporter.open(
      endpoint: Uri.parse('https://collector.example.org:4318'),
      keyId: '@denise',
      audience: 'collector.example.org',
      signer: AtTelemetryRsaSigner.fromBase64(keys.privateKey.toString()),
      storagePath: storage.path,
      maxRecords: maxRecords,
      maxBytes: maxBytes,
      persistToDisk: persistToDisk,
      client: client,
    );
  }

  test('retains failures on disk and deletes only after signed HTTP 200',
      () async {
    final AtTelemetryEvent event = _event(atServerHeartbeatEventName);
    final AtServerTelemetryExporter first = open(
      client: _unavailableClient(),
    );
    await first.export(event);
    await first.flush();
    await first.shutdown();
    expect(_storedEvents(storage).single.name, event.name);

    final List<http.Request> delivered = <http.Request>[];
    final Completer<void> sent = Completer<void>();
    final AtServerTelemetryExporter second = open(
      client: MockClient((http.Request request) async {
        delivered.add(request);
        sent.complete();
        return http.Response('', 200);
      }),
    );
    await sent.future.timeout(const Duration(seconds: 2));
    await second.shutdown();

    expect(_storedEvents(storage), isEmpty);
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
      event.name,
    );
  });

  test('sends directly without opening a disk queue when disabled', () async {
    final List<http.Request> delivered = <http.Request>[];
    final AtServerTelemetryExporter exporter = open(
      persistToDisk: false,
      client: MockClient((http.Request request) async {
        delivered.add(request);
        return http.Response('', 200);
      }),
    );

    await exporter.export(_event('direct'));
    await exporter.flush();
    await exporter.shutdown();

    expect(exporter.isDirectExport, isTrue);
    expect(exporter.droppedRecords, 0);
    expect(delivered, hasLength(1));
    expect(delivered.single.headers,
        contains(AtTelemetryOtelHttpSignature.signatureHeader));
    expect(storage.listSync(), isEmpty);
  });

  test('persists a push before export and keeps it after flush times out',
      () async {
    final Completer<http.Response> response = Completer<http.Response>();
    final AtServerTelemetryExporter exporter = open(
      client: MockClient((http.Request request) => response.future),
    );
    final AtServerTelemetry telemetry = AtServerTelemetry()
      ..enable(exporter: exporter, serverId: '@denise');
    telemetry.push(atServerHeartbeatEventName);

    expect(_storedEvents(storage).single.name, 'atsign.atserver.heartbeat');
    await telemetry.flush(timeout: const Duration(milliseconds: 20));
    expect(_storedEvents(storage), hasLength(1));
    response.complete(http.Response('', 503));
    await exporter.shutdown();
    expect(_storedEvents(storage), hasLength(1));
  });

  test('switches future events to direct export after a disk write fails',
      () async {
    final List<http.Request> delivered = <http.Request>[];
    final AtServerTelemetryExporter exporter = open(
      client: MockClient((http.Request request) async {
        delivered.add(request);
        return http.Response('', 200);
      }),
    );
    final File file = storage.listSync().whereType<File>().single;
    final Database database = sqlite3.open(file.path);
    database.execute('DROP TABLE telemetry_queue');
    database.dispose();

    await exporter.export(_event('first'));
    await exporter.export(_event('second'));
    await exporter.flush();
    await exporter.shutdown();

    expect(exporter.isDirectExport, isTrue);
    expect(delivered, hasLength(2));
    expect(
      <String>[
        for (final http.Request request in delivered)
          const AtTelemetryOtelLogsCodec()
              .decodeExportRequest(request.bodyBytes)
              .single
              .name,
      ],
      <String>['first', 'second'],
    );
    expect(
        delivered.every((http.Request request) => request.headers
            .containsKey(AtTelemetryOtelHttpSignature.signatureHeader)),
        isTrue);
  });

  test('keeps queued records when writes switch to direct export', () async {
    final List<String> delivered = <String>[];
    bool available = false;
    final AtServerTelemetryExporter exporter = open(
      client: MockClient((http.Request request) async {
        final String name = const AtTelemetryOtelLogsCodec()
            .decodeExportRequest(request.bodyBytes)
            .single
            .name;
        delivered.add(name);
        return http.Response('', available ? 200 : 503);
      }),
    );
    await exporter.export(_event('queued'));
    await exporter.flush();
    expect(_storedEvents(storage).single.name, 'queued');

    final File file = storage.listSync().whereType<File>().single;
    final Database blocker = sqlite3.open(file.path);
    blocker.execute('BEGIN EXCLUSIVE');
    try {
      available = true;
      await exporter.export(_event('direct'));
      expect(exporter.isDirectExport, isTrue);
    } finally {
      blocker.execute('ROLLBACK');
      blocker.dispose();
    }
    await exporter.flush();
    await exporter.shutdown();

    expect(_storedEvents(storage), isEmpty);
    expect(delivered, containsAll(<String>['queued', 'direct']));
  });

  test('retains records rejected by the collector', () async {
    final AtServerTelemetryExporter exporter = open(
      client:
          MockClient((http.Request request) async => http.Response('', 401)),
    );
    await exporter.export(_event(atServerHeartbeatEventName));
    await exporter.flush();
    await exporter.shutdown();

    expect(_storedEvents(storage).single.name, atServerHeartbeatEventName);
  });

  test('does not follow redirects or acknowledge redirected records', () async {
    final List<http.Request> requests = <http.Request>[];
    final AtServerTelemetryExporter exporter = open(
      client: MockClient((http.Request request) async {
        requests.add(request);
        return http.Response('', 302, headers: <String, String>{
          'location': 'https://other.example.org/v1/logs',
        });
      }),
    );
    await exporter.export(_event(atServerHeartbeatEventName));
    await exporter.flush();
    await exporter.shutdown();

    expect(requests, hasLength(1));
    expect(requests.single.followRedirects, isFalse);
    expect(_storedEvents(storage).single.name, atServerHeartbeatEventName);
  });

  test('discards oldest records when count limit is reached', () async {
    final AtServerTelemetryExporter exporter = open(
      maxRecords: 2,
      client: _unavailableClient(),
    );
    await exporter.export(_event('first'));
    await exporter.export(_event('second'));
    await exporter.export(_event('third'));
    await exporter.shutdown();

    expect(exporter.droppedRecords, 1);
    expect(
      _storedEvents(storage).map((AtTelemetryEvent event) => event.name),
      <String>['second', 'third'],
    );
  });

  test('the disk cap drops oldest even when the memory backlog is full',
      () async {
    final AtServerTelemetryExporter exporter = open(
      maxRecords: 2,
      client: _unavailableClient(),
    );
    final AtServerTelemetry telemetry = AtServerTelemetry(maxPendingEvents: 1)
      ..enable(exporter: exporter, serverId: '@denise');
    telemetry.push('$atServerTelemetryEventPrefix.first');
    telemetry.push('$atServerTelemetryEventPrefix.second');
    telemetry.push('$atServerTelemetryEventPrefix.third');
    await telemetry.flush();
    await exporter.shutdown();

    expect(exporter.droppedRecords, 1);
    expect(
      _storedEvents(storage).map((AtTelemetryEvent event) => event.name),
      <String>['atsign.atserver.second', 'atsign.atserver.third'],
    );
  });

  test('applies reduced queue limits when reopening existing records',
      () async {
    final http.Client unavailable = _unavailableClient();
    final AtServerTelemetryExporter first = open(
      maxRecords: 3,
      client: unavailable,
    );
    await first.export(_event('first'));
    await first.export(_event('second'));
    await first.export(_event('third'));
    await first.shutdown();

    final AtServerTelemetryExporter second = open(
      maxRecords: 2,
      client: unavailable,
    );
    expect(second.droppedRecords, 1);
    expect(
      _storedEvents(storage).map((AtTelemetryEvent event) => event.name),
      <String>['second', 'third'],
    );
    await second.shutdown();
  });

  test('discards oldest records when byte limit is reached', () async {
    final AtTelemetryEvent first = _event('first');
    final int payloadBytes =
        const AtTelemetryOtelLogsCodec().encodeExportRequest(
      <AtTelemetryEvent>[first],
      serviceName: 'at_secondary_server',
    ).length;
    final AtServerTelemetryExporter exporter = open(
      maxBytes: payloadBytes + 1,
      client: _unavailableClient(),
    );
    await exporter.export(first);
    await exporter.export(_event('other'));
    await exporter.shutdown();

    expect(exporter.droppedRecords, 1);
    expect(_storedEvents(storage).single.name, 'other');
  });

  test('does not store an individual record larger than the byte cap',
      () async {
    int requests = 0;
    final AtServerTelemetryExporter exporter = open(
      maxBytes: 1,
      client: MockClient((http.Request request) async {
        requests++;
        return http.Response('', 200);
      }),
    );
    await exporter.export(_event('oversized'));
    await exporter.flush();
    await exporter.shutdown();

    expect(exporter.droppedRecords, 1);
    expect(requests, 0);
    expect(_storedEvents(storage), isEmpty);
  });
}

http.Client _unavailableClient() =>
    MockClient((http.Request request) async => http.Response('', 503));

AtTelemetryEvent _event(String name) => AtTelemetryEvent(
      name: name,
      timestamp: DateTime.utc(2026, 9, 28),
      attributes: const <String, Object?>{'atsign.atserver.id': '@denise'},
    );

List<AtTelemetryEvent> _storedEvents(Directory storage) {
  final File file = storage.listSync().whereType<File>().single;
  final Database database = sqlite3.open(file.path);
  try {
    return <AtTelemetryEvent>[
      for (final Row row in database.select(
        'SELECT payload FROM telemetry_queue ORDER BY id',
      ))
        ...const AtTelemetryOtelLogsCodec()
            .decodeExportRequest(row['payload'] as List<int>),
    ];
  } finally {
    database.dispose();
  }
}
