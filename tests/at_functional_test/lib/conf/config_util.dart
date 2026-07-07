import 'dart:io';

import 'package:at_utils/at_utils.dart';
import 'package:yaml/yaml.dart';

class ConfigUtil {
  static final ApplicationConfiguration appConfig =
      ApplicationConfiguration('config/config.yaml');

  /// The functional-test config from `config/config.yaml`.
  ///
  /// When the `VIRTUALENV_BASE_PORT` environment variable is set, the first
  /// atSign's port is overlaid with the value the ve entrypoint assigns to the
  /// first atServer (`BASE + 1`), so tests run against a virtualenv launched on
  /// a shifted port range without editing the config file. Unset => the config
  /// file's ports are used unchanged.
  static YamlMap? getYaml() {
    final yaml = appConfig.getYaml();
    final basePort =
        int.tryParse(Platform.environment['VIRTUALENV_BASE_PORT'] ?? '');
    if (yaml == null || basePort == null) {
      return yaml;
    }
    final overlaid = _deepCopy(yaml) as Map;
    (overlaid['firstAtSignServer'] as Map)['firstAtSignPort'] = basePort + 1;
    return YamlMap.wrap(overlaid);
  }

  static dynamic _deepCopy(dynamic node) {
    if (node is Map) {
      return {for (final e in node.entries) e.key: _deepCopy(e.value)};
    }
    if (node is List) {
      return [for (final e in node) _deepCopy(e)];
    }
    return node;
  }
}
