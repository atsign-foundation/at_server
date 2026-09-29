import 'dart:io';

import 'package:at_secondary/src/server/at_secondary_config.dart';

final class AtServerTelemetryConfiguration {
  final Uri endpoint;

  const AtServerTelemetryConfiguration({required this.endpoint});

  // config.yaml first, then the environment.
  static AtServerTelemetryConfiguration? load({
    Map<Object?, Object?>? yaml,
    Map<String, String>? environment,
  }) {
    final Map<String, String> values = environment ?? Platform.environment;
    final String? fromYaml = yaml != null
        ? yaml['endpoint']?.toString()
        : AtSecondaryConfig.getStringValueFromYaml(['telemetry', 'endpoint']);
    final String? endpointValue =
        _nonEmpty(fromYaml) ?? _nonEmpty(values['AT_TELEMETRY_ENDPOINT']);
    if (endpointValue == null) {
      return null;
    }

    final Uri endpoint = Uri.parse(endpointValue);
    if (endpoint.scheme != 'https' ||
        !endpoint.hasAuthority ||
        endpoint.host.isEmpty) {
      throw const FormatException('Telemetry endpoint must be an HTTPS URL');
    }
    return AtServerTelemetryConfiguration(endpoint: endpoint);
  }

  static String? _nonEmpty(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }
}
