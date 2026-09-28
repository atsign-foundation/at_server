import 'dart:async';
import 'dart:io';

import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_disk_exporter.dart';
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

  AtServerTelemetryDiskExporter open({
    required http.Client client,
    int maxRecords = 1000,
    int maxBytes = 10 * 1024 * 1024,
  }) {
    return AtServerTelemetryDiskExporter.open(
      endpoint: Uri.parse('https://collector.example.org:4318'),
      keyId: '@denise',
      audience: 'collector.example.org',
      signer: AtTelemetryRsaSigner.fromBase64(keys.privateKey.toString()),
      storagePath: storage.path,
      maxRecords: maxRecords,
      maxBytes: maxBytes,
      client: client,
    );
  }

  test('retains failures on disk and deletes only after signed HTTP 200',
      () async {
    final AtTelemetryEvent event = _event('atsign.server.heartbeat');
    final AtServerTelemetryDiskExporter first = open(
      client:
          MockClient((http.Request request) async => http.Response('', 503)),
    );
    await first.export(event);
    await first.flush();
    await first.shutdown();
    expect(_storedEvents(storage).single.name, event.name);

    final List<http.Request> delivered = <http.Request>[];
    final Completer<void> sent = Completer<void>();
    final AtServerTelemetryDiskExporter second = open(
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
    final AtTelemetryHttpSignature signature = AtTelemetryHttpSignature.parse(
      input: request.headers[AtTelemetryHttpSignature.inputHeader]!,
      signature: request.headers[AtTelemetryHttpSignature.signatureHeader]!,
      digest: request.headers[AtTelemetryHttpSignature.digestHeader]!,
      audience: request.headers[AtTelemetryHttpSignature.audienceHeader]!,
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

  test('persists a push before export and keeps it after flush times out',
      () async {
    final Completer<http.Response> response = Completer<http.Response>();
    final AtServerTelemetryDiskExporter exporter = open(
      client: MockClient((http.Request request) => response.future),
    );
    final AtServerTelemetry telemetry = AtServerTelemetry()
      ..enable(exporter: exporter, serverId: '@denise');
    telemetry.push('atsign.server.heartbeat');

    expect(_storedEvents(storage).single.name, 'atsign.server.heartbeat');
    await telemetry.flush(timeout: const Duration(milliseconds: 20));
    expect(_storedEvents(storage), hasLength(1));
    response.complete(http.Response('', 503));
    await exporter.shutdown();
    expect(_storedEvents(storage), hasLength(1));
  });

  test('switches future events to direct export after a disk write fails',
      () async {
    final List<http.Request> delivered = <http.Request>[];
    final AtServerTelemetryDiskExporter exporter = open(
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
            .containsKey(AtTelemetryHttpSignature.signatureHeader)),
        isTrue);
  });

  test('keeps queued records when writes switch to direct export', () async {
    final List<String> delivered = <String>[];
    bool available = false;
    final AtServerTelemetryDiskExporter exporter = open(
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
    final AtServerTelemetryDiskExporter exporter = open(
      client:
          MockClient((http.Request request) async => http.Response('', 401)),
    );
    await exporter.export(_event('atsign.server.heartbeat'));
    await exporter.flush();
    await exporter.shutdown();

    expect(_storedEvents(storage).single.name, 'atsign.server.heartbeat');
  });

  test('discards oldest records when count limit is reached', () async {
    final AtServerTelemetryDiskExporter exporter = open(
      maxRecords: 2,
      client:
          MockClient((http.Request request) async => http.Response('', 503)),
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
    final AtServerTelemetryDiskExporter exporter = open(
      maxRecords: 2,
      client:
          MockClient((http.Request request) async => http.Response('', 503)),
    );
    final AtServerTelemetry telemetry = AtServerTelemetry(maxPendingEvents: 1)
      ..enable(exporter: exporter, serverId: '@denise');
    telemetry.push('first');
    telemetry.push('second');
    telemetry.push('third');
    await telemetry.flush();
    await exporter.shutdown();

    expect(exporter.droppedRecords, 1);
    expect(
      _storedEvents(storage).map((AtTelemetryEvent event) => event.name),
      <String>['second', 'third'],
    );
  });

  test('applies reduced queue limits when reopening existing records',
      () async {
    final http.Client unavailable =
        MockClient((http.Request request) async => http.Response('', 503));
    final AtServerTelemetryDiskExporter first = open(
      maxRecords: 3,
      client: unavailable,
    );
    await first.export(_event('first'));
    await first.export(_event('second'));
    await first.export(_event('third'));
    await first.shutdown();

    final AtServerTelemetryDiskExporter second = open(
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
    final AtServerTelemetryDiskExporter exporter = open(
      maxBytes: payloadBytes + 1,
      client:
          MockClient((http.Request request) async => http.Response('', 503)),
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
    final AtServerTelemetryDiskExporter exporter = open(
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

AtTelemetryEvent _event(String name) => AtTelemetryEvent(
      name: name,
      timestamp: DateTime.utc(2026, 9, 28),
      attributes: const <String, Object?>{'atsign.server.id': '@denise'},
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
