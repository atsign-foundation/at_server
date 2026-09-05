import 'dart:io';

import 'package:at_utils/at_utils.dart';
import 'package:yaml/yaml.dart';

class ConfigUtil {
  static final ApplicationConfiguration appConfig =
      ApplicationConfiguration('config/config.yaml');

  /// The functional-test config from `config/config.yaml`.
  ///
  /// When the `VIRTUALENV_BASE_PORT` environment variable is set, every
  /// atServer port in the config is shifted into the virtualenv's range, so
  /// tests run against a virtualenv launched on shifted ports without editing
  /// the config file. Unset => the config file's ports are used unchanged.
  ///
  /// The shift is the ve entrypoint's own: it binds the atDirectory to BASE
  /// and the atServers from BASE + 1, where the unshifted range starts at
  /// 25000 — so `shifted = declared + BASE + 1 - 25000`
  /// (`tools/build_virtual_environment/ve/contents/atsign/entrypoint.sh`).
  /// Applied to EVERY `*Port` under every `*AtSignServer` map rather than to
  /// the first by name, so an atSign added to the config is shifted too
  /// instead of silently keeping an unshifted port that nothing is listening
  /// on.
  static YamlMap? getYaml() {
    final yaml = appConfig.getYaml();
    final basePort =
        int.tryParse(Platform.environment['VIRTUALENV_BASE_PORT'] ?? '');
    if (yaml == null || basePort == null) {
      return yaml;
    }
    final int shift = basePort + 1 - _unshiftedFirstAtServerPort;
    final overlaid = _deepCopy(yaml) as Map;
    for (final entry in overlaid.entries) {
      if (!'${entry.key}'.endsWith('AtSignServer')) continue;
      final server = entry.value;
      if (server is! Map) continue;
      for (final field in server.keys.toList()) {
        final value = server[field];
        if ('$field'.endsWith('Port') && value is int) {
          server[field] = value + shift;
        }
      }
    }
    return YamlMap.wrap(overlaid);
  }

  /// The port the ve assigns to the FIRST demo atServer when it is not
  /// shifting (`create_demo_accounts.sh`).
  static const int _unshiftedFirstAtServerPort = 25000;

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
