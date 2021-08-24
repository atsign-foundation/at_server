import 'dart:io';

import 'package:at_root_server/src/config_util.dart';

class AtRootConfig {
  static int _rootServerPort = 64;
  static bool _debugLog = false;
  static bool? _useSSL = true;
  static String _certificateChainLocation = 'certs/fullchain.pem';
  static String _privateKeyLocation = 'certs/privkey.pem';
  static String? _root_server_version =
      (ConfigUtil.getPubspecConfig() != null &&
              ConfigUtil.getPubspecConfig()!['version'] != null)
          ? ConfigUtil.getPubspecConfig()!['version']
          : null;

  static final Map<String, String> _envVars = Platform.environment;

  static String? get root_server_version => _root_server_version;

  static int? get rootServerPort {
    if (_envVars.containsKey('rootServerPort')) {
      return int.parse(_envVars['rootServerPort']!);
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()!['server'] != null &&
        ConfigUtil.getYaml()!['server']['port'] != null) {
      return ConfigUtil.getYaml()!['server']['port'];
    }
    return _rootServerPort;
  }

  static bool? get debugLog {
    var result = _getBoolEnvVar('debugLog');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()!['log'] != null &&
        ConfigUtil.getYaml()!['log']['debug'] != null) {
      return ConfigUtil.getYaml()!['log']['debug'];
    }
    return _debugLog;
  }

  static String? get privateKeyLocation {
    if (_envVars.containsKey('privateKeyLocation')) {
      return _envVars['privateKeyLocation'];
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()!['security'] != null &&
        ConfigUtil.getYaml()!['security']['privateKeyLocation'] != null) {
      return ConfigUtil.getYaml()!['security']['privateKeyLocation'];
    }
    return _privateKeyLocation;
  }

  static String? get certificateChainLocation {
    if (_envVars.containsKey('certificateChainLocation')) {
      return _envVars['certificateChainLocation'];
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()!['security'] != null &&
        ConfigUtil.getYaml()!['security']['certificateChainLocation'] != null) {
      return ConfigUtil.getYaml()!['security']['certificateChainLocation'];
    }
    return _certificateChainLocation;
  }

  static bool? get useSSL {
    var result = _getBoolEnvVar('useSSL');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()!['security'] != null &&
        ConfigUtil.getYaml()!['security']['useSSL'] != null) {
      return _useSSL = ConfigUtil.getYaml()!['security']['useSSL'];
    }
    return _useSSL;
  }

  static bool? _getBoolEnvVar(String envVar) {
    if (_envVars.containsKey(envVar)) {
      (_envVars[envVar]!.toLowerCase() == 'true') ? true : false;
    }
    return null;
  }
}
