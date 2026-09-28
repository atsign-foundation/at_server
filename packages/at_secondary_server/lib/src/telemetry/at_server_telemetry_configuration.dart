import 'dart:io';

import 'package:at_commons/at_commons.dart' show InvalidAtSignException;
import 'package:at_utils/at_utils.dart' show AtUtils;

final class AtServerTelemetryConfiguration {
  final Uri endpoint;
  final String? collectorAtsign;
  final String? apiKey;

  const AtServerTelemetryConfiguration({
    required this.endpoint,
    this.collectorAtsign,
    this.apiKey,
  });

  static AtServerTelemetryConfiguration? fromEnvironment([
    Map<String, String>? environment,
  ]) {
    final Map<String, String> values = environment ?? Platform.environment;
    final String? endpointValue = _nonEmpty(
      values['AT_TELEMETRY_ENDPOINT'],
    );
    final String? apiKey = _nonEmpty(values['AT_TELEMETRY_API_KEY']);
    final String? collectorAtsign =
        _nonEmpty(values['AT_TELEMETRY_COLLECTOR_ATSIGN']);

    if (endpointValue == null && apiKey == null && collectorAtsign == null) {
      return null;
    }
    if (endpointValue == null) {
      throw const FormatException('AT_TELEMETRY_ENDPOINT is required');
    }
    if (collectorAtsign == null && apiKey == null) {
      throw const FormatException(
        'AT_TELEMETRY_API_KEY or AT_TELEMETRY_COLLECTOR_ATSIGN is required',
      );
    }
    if (collectorAtsign != null) {
      if (!collectorAtsign.startsWith('@')) {
        throw const FormatException('Invalid collector Atsign');
      }
      try {
        if (AtUtils.fixAtSign(collectorAtsign) != collectorAtsign) {
          throw const FormatException('Collector Atsign must be canonical');
        }
      } on InvalidAtSignException {
        throw const FormatException('Invalid collector Atsign');
      }
    }

    final Uri endpoint = Uri.parse(endpointValue);
    if (!endpoint.hasAuthority ||
        (endpoint.scheme != 'http' && endpoint.scheme != 'https')) {
      throw const FormatException(
        'AT_TELEMETRY_ENDPOINT must be an HTTP or HTTPS URL',
      );
    }

    return AtServerTelemetryConfiguration(
      endpoint: endpoint,
      apiKey: apiKey,
      collectorAtsign: collectorAtsign,
    );
  }

  static String? _nonEmpty(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }
}
