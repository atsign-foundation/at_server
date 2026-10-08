import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';
import 'package:http/http.dart' as http;

import 'at_server_telemetry_buffer.dart';
import 'at_server_telemetry_http_exporter.dart';
import 'at_server_telemetry_signing_key.dart';

// Builds the signed OTLP/HTTP exporter for this server, creating the signing
// key, or returns null after logging why when telemetry is off or cannot be
// set up. endpoint is host:port (https is assumed) or a full URL, and plain
// http only to a loopback collector. No key is created for an endpoint that
// is refused.
Future<AtServerTelemetryHttpExporter?> createAtServerTelemetryExporter({
  required String? endpoint,
  required String atSign,
  required String bootId,
  required AtKeyValueStore<String, AtData, AtMetaData?> keyStore,
  http.Client? client,
}) async {
  final AtSignLogger logger = AtSignLogger('AtServerTelemetry');

  if (endpoint == null || endpoint.isEmpty) {
    logger.info('Not pushing telemetry anywhere: no telemetry endpoint set');
    return null;
  }

  final Uri? endpointUri =
      Uri.tryParse(endpoint.contains('://') ? endpoint : 'https://$endpoint');
  try {
    if (endpointUri == null) {
      throw ArgumentError.value(endpoint, 'endpoint', 'not a URL');
    }
    AtServerTelemetryHttpExporter.logsEndpointFor(endpointUri);
  } on ArgumentError catch (error) {
    logger.warning('Not pushing telemetry anywhere: invalid telemetry '
        'endpoint $endpoint: ${error.message}');
    return null;
  }

  try {
    final AtServerTelemetrySigningKey key =
        await AtServerTelemetrySigningKey.loadOrCreate(keyStore, atSign);
    final AtServerTelemetryHttpExporter exporter =
        AtServerTelemetryHttpExporter(
      endpoint: endpointUri,
      producer: atSign,
      key: key,
      buffer: AtServerTelemetryBuffer(bootId: bootId),
      client: client,
    );
    logger.info('Pushing signed telemetry to ${exporter.endpoint.origin} '
        'with key ${key.keyId}');
    return exporter;
  } on Object catch (error) {
    logger.warning('Not pushing telemetry anywhere: '
        'exporter setup failed: $error');
    return null;
  }
}
