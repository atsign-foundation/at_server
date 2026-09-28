import 'dart:io';

import 'package:at_secondary/src/server/at_secondary_config.dart';

final class AtServerTelemetryConfiguration {
  // Used when neither config.yaml nor the environment sets a value.
  static const String? _defaultEndpoint = null;

  final Uri endpoint;

  const AtServerTelemetryConfiguration({required this.endpoint});

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
