import 'dart:io';

import 'package:at_root_server/src/config_util.dart';
import 'package:yaml/yaml.dart';

class AtRootConfig {
  static final int _rootServerPort = 64;
  static final int _httpsPort = 443;
  static final bool _httpsEnabled = false;
  static final bool _debugLog = false;
  static final bool _useSSL = true;
  static final String _certificateChainLocation = 'certs/fullchain.pem';
  static final String _privateKeyLocation = 'certs/privkey.pem';
  static final String? _rootServerVersion =
      (ConfigUtil.getPubspecConfig() != null &&
              ConfigUtil.getPubspecConfig()!['version'] != null)
          ? ConfigUtil.getPubspecConfig()!['version']
          : null;

  static YamlMap? yaml = ConfigUtil.getYaml();
  static Map<String, String> envVars = Platform.environment;

  static String? get rootServerVersion => _rootServerVersion;

  static int get rootServerPort {
    if (envVars.containsKey('rootServerPort')) {
      return int.parse(envVars['rootServerPort']!);
    }
    if (yaml != null &&
        yaml!['server'] != null &&
        yaml!['server']['port'] != null) {
      return yaml!['server']['port'];
    }
    return _rootServerPort;
  }

  static int get httpsPort {
    if (envVars.containsKey('httpsPort')) {
      return int.parse(envVars['httpsPort']!);
    }
    if (yaml != null &&
        yaml!['server'] != null &&
        yaml!['server']['httpsPort'] != null) {
      return yaml!['server']['httpsPort'];
    }
    return _httpsPort;
  }

  static bool get httpsEnabled {
    var result = _getBoolEnvVar('httpsEnabled');
    if (result != null) {
      return result;
    }
    if (yaml != null &&
        yaml!['server'] != null &&
        yaml!['server']['httpsEnabled'] != null) {
      return yaml!['server']['httpsEnabled'];
    }
    return _httpsEnabled;
  }

  static bool get debugLog {
    var result = _getBoolEnvVar('debugLog');
    if (result != null) {
      return result;
    }
    if (yaml != null && yaml!['log'] != null && yaml!['log']['debug'] != null) {
      return yaml!['log']['debug'];
    }
    return _debugLog;
  }

  static String get privateKeyLocation {
    if (envVars.containsKey('privateKeyLocation')) {
      return envVars['privateKeyLocation']!;
    }
    if (yaml != null &&
        yaml!['security'] != null &&
        yaml!['security']['privateKeyLocation'] != null) {
      return yaml!['security']['privateKeyLocation'];
    }
    return _privateKeyLocation;
  }

  static String get certificateChainLocation {
    if (envVars.containsKey('certificateChainLocation')) {
      return envVars['certificateChainLocation']!;
    }
    if (yaml != null &&
        yaml!['security'] != null &&
        yaml!['security']['certificateChainLocation'] != null) {
      return yaml!['security']['certificateChainLocation'];
    }
    return _certificateChainLocation;
  }

  static bool get useSSL {
    var result = _getBoolEnvVar('useSSL');
    if (result != null) {
      return result;
    }
    if (yaml != null &&
        yaml!['security'] != null &&
        yaml!['security']['useSSL'] != null) {
      return yaml!['security']['useSSL'];
    }
    return _useSSL;
  }

  static bool? _getBoolEnvVar(String envVar) {
    if (envVars.containsKey(envVar)) {
      return (envVars[envVar]!.toLowerCase() == 'true') ? true : false;
    } else {
      return null;
    }
  }
}
