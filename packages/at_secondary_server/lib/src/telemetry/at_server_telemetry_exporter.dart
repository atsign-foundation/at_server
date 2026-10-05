import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_utils/at_logger.dart';
import 'package:http/http.dart' as http;

/// Builds the signed OTLP/HTTP exporter for this server, or returns null
/// (after logging why) when telemetry is not configured or cannot be set up.
///
/// [endpoint] is `host:port` (https is assumed) or a full URL.
Future<AtTelemetrySignedHttpExporter?> createAtServerTelemetryExporter({
  required String? endpoint,
  required String serverId,
  required String signingKey,
  http.Client? client,
}) async {
  final AtSignLogger logger = AtSignLogger('AtServerTelemetry');

  if (endpoint == null || endpoint.isEmpty) {
    logger.info('Not pushing telemetry anywhere: no telemetry endpoint set');
    return null;
  }

  final Uri? endpointUri =
      Uri.tryParse(endpoint.contains('://') ? endpoint : 'https://$endpoint');
  if (endpointUri == null || endpointUri.host.isEmpty) {
    logger.warning(
        'Not pushing telemetry anywhere: invalid telemetry endpoint $endpoint');
    return null;
  }

  if (signingKey.isEmpty) {
    logger
        .warning('Not pushing telemetry anywhere: signing key is empty String');
    return null;
  }

  try {
    final AtTelemetrySignedHttpExporter exporter =
        AtTelemetrySignedHttpExporter(
      endpoint: endpointUri,
      keyId: serverId,
      audience: endpointUri.host,
      signer: AtTelemetryRsaSigner.fromBase64(signingKey),
      client: client,
    );
    logger.info('Pushing signed telemetry to ${endpointUri.origin}');
    return exporter;
  } on Object catch (error) {
    logger.warning('Not pushing telemetry anywhere: '
        'exporter setup failed: ${error.runtimeType}');
    return null;
  }
}
