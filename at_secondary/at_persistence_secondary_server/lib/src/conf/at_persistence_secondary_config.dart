import 'dart:io';
import 'package:at_persistence_secondary_server/src/conf/config_util.dart';

class AtPersistenceSecondaryConfig {
  //Storage
  static String _keyStore = 'redis';

  static final Map<String, String> _envVars = Platform.environment;

  static String get keyStore {
    if (_envVars.containsKey('keyStore')) {
      return _envVars['keyStore'];
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['storage'] != null &&
        ConfigUtil.getYaml()['storage']['keyStore'] != null) {
      return _keyStore = ConfigUtil.getYaml()['storage']['keyStore'];
    }
    return _keyStore;
  }
}
