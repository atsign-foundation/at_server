import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_utils/at_logger.dart';
import 'package:http/http.dart' as http;

import 'at_server_telemetry_configuration.dart';

/// Builds the signed OTLP/HTTP exporter for this server, or returns null
/// (after logging why) when telemetry is not configured or cannot be set up.
Future<AtTelemetrySignedHttpExporter?> createAtServerTelemetryExporter({
  required String serverId,
  required String signingKey,
  Map<Object?, Object?>? yaml,
  Map<String, String>? environment,
  http.Client? client,
}) async {
  final AtSignLogger logger = AtSignLogger('AtServerTelemetry');

  final AtServerTelemetryConfiguration? configuration;
  try {
    configuration = AtServerTelemetryConfiguration.load(
      yaml: yaml,
      environment: environment,
    );
  } on FormatException catch (error) {
    logger.warning('Not pushing telemetry anywhere: ${error.message}');
    return null;
  }
  if (configuration == null) {
    logger.warning(
        'Not pushing telemetry anywhere: no telemetry endpoint is configured');
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
      endpoint: configuration.endpoint,
      serviceName: 'at_secondary_server',
      keyId: serverId,
      audience: configuration.endpoint.host,
      signer: AtTelemetryRsaSigner.fromBase64(signingKey),
      client: client,
      onError: (Object error) =>
          logger.warning('Telemetry export failed: ${error.runtimeType}'),
    );
    logger.info('Pushing signed telemetry to ${configuration.endpoint.origin}');
    return exporter;
  } on Object catch (error) {
    logger.warning('Not pushing telemetry anywhere: '
        'exporter setup failed: ${error.runtimeType}');
    return null;
  }
}
