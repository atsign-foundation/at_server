import 'dart:io';

import 'package:at_secondary/src/conf/config_util.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_utils/at_utils.dart';

class TestConfigUtil {
  static String testConfigPath1 =
      '${Directory.current.absolute.path}/test/assets/test_config_1.yaml';
  static String testConfigPath2 =
      '${Directory.current.absolute.path}/test/assets/test_config_2.yaml';
  static ApplicationConfiguration testConfig1 =
      ApplicationConfiguration(testConfigPath1);
  static ApplicationConfiguration testConfig2 =
      ApplicationConfiguration(testConfigPath2);

  /// sets [testConfig1] as the [AtSecondaryConfig.configYamlMap]
  static Future<void> setTestConfig(int configFlavour) async {
    switch (configFlavour) {
      case 1:
        AtSecondaryConfig.configYamlMap = testConfig1.getYaml()!;
        break;
      case 2:
        AtSecondaryConfig.configYamlMap = testConfig2.getYaml()!;
        break;
    }
  }

  /// sets the default config yaml as [AtSecondaryConfig.configYamlMap]
  static void resetTestConfig() {
    /// [ConfigUtil.getYaml()] is the original config of the server fetched from
    /// [ConfigUtil] in [AtSecondaryServer]
    AtSecondaryConfig.configYamlMap = ConfigUtil.getYaml()!;
  }
}
