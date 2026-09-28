import 'dart:io';

import 'package:at_commons/at_commons.dart' show InvalidAtSignException;
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_utils/at_utils.dart' show AtUtils;

final class AtServerTelemetryConfiguration {
  // Used when neither config.yaml nor the environment sets a value.
  static const String? _defaultEndpoint = null;
  static const String? _defaultCollectorAtsign = null;
  static const String? _defaultApiKey = null;

  final Uri endpoint;
  final String? collectorAtsign;
  final String? apiKey;

  const AtServerTelemetryConfiguration({
    required this.endpoint,
    this.collectorAtsign,
    this.apiKey,
  });

  // config.yaml first, then the environment, then the defaults above.
  static AtServerTelemetryConfiguration? load({
    Map<Object?, Object?>? yaml,
    Map<String, String>? environment,
  }) {
    final Map<String, String> values = environment ?? Platform.environment;
    String? fromYaml(String key) => yaml != null
        ? yaml[key]?.toString()
        : AtSecondaryConfig.getStringValueFromYaml(['telemetry', key]);
    String? setting(String yamlKey, String environmentKey, String? fallback) {
      return _nonEmpty(fromYaml(yamlKey)) ??
          _nonEmpty(values[environmentKey]) ??
          fallback;
    }

    final String? endpointValue =
        setting('endpoint', 'AT_TELEMETRY_ENDPOINT', _defaultEndpoint);
    final String? apiKey =
        setting('apiKey', 'AT_TELEMETRY_API_KEY', _defaultApiKey);
    final String? collectorAtsign = setting(
      'collectorAtsign',
      'AT_TELEMETRY_COLLECTOR_ATSIGN',
      _defaultCollectorAtsign,
    );

    if (endpointValue == null && apiKey == null && collectorAtsign == null) {
      return null;
    }
    if (endpointValue == null) {
      throw const FormatException(
        'telemetry.endpoint or AT_TELEMETRY_ENDPOINT is required',
      );
    }
    if (collectorAtsign == null && apiKey == null) {
      throw const FormatException(
        'telemetry.apiKey, telemetry.collectorAtsign, AT_TELEMETRY_API_KEY or '
        'AT_TELEMETRY_COLLECTOR_ATSIGN is required',
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
        'Telemetry endpoint must be an HTTP or HTTPS URL',
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
