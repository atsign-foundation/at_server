import 'dart:io';

import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:path/path.dart' as p;

final class AtServerTelemetryConfiguration {
  // Used when neither config.yaml nor the environment sets a value.
  static const String? _defaultEndpoint = null;
  static const int defaultMaxRecords = 1000;
  static const int defaultMaxBytes = 10 * 1024 * 1024;

  final Uri endpoint;
  final String storagePath;
  final int maxRecords;
  final int maxBytes;

  const AtServerTelemetryConfiguration({
    required this.endpoint,
    required this.storagePath,
    required this.maxRecords,
    required this.maxBytes,
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
    if (endpointValue == null) {
      return null;
    }

    final Uri endpoint = Uri.parse(endpointValue);
    if (endpoint.scheme != 'https' ||
        !endpoint.hasAuthority ||
        endpoint.host.isEmpty) {
      throw const FormatException('Telemetry endpoint must be an HTTPS URL');
    }

    int positiveLimit(String yamlKey, String environmentKey, int fallback) {
      final String? value = setting(yamlKey, environmentKey, null);
      if (value == null) {
        return fallback;
      }
      final int? parsed = int.tryParse(value);
      if (parsed == null || parsed < 1) {
        throw FormatException('Telemetry $yamlKey must be a positive integer');
      }
      return parsed;
    }

    final String storagePath = setting(
      'storagePath',
      'AT_TELEMETRY_STORAGE_PATH',
      p.join(AtSecondaryConfig.storageRoot, 'telemetry'),
    )!;
    return AtServerTelemetryConfiguration(
      endpoint: endpoint,
      storagePath: storagePath,
      maxRecords: positiveLimit(
        'maxRecords',
        'AT_TELEMETRY_MAX_RECORDS',
        defaultMaxRecords,
      ),
      maxBytes: positiveLimit(
        'maxBytes',
        'AT_TELEMETRY_MAX_BYTES',
        defaultMaxBytes,
      ),
    );
  }

  static String? _nonEmpty(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }
}
