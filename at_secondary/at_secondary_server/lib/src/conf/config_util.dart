import 'package:at_utils/at_utils.dart';
import 'package:yaml/yaml.dart';

class ConfigUtil {
  static final ApplicationConfiguration appConfig =
      ApplicationConfiguration('config/config.yaml');

  static final ApplicationConfiguration pubspecConfig =
      ApplicationConfiguration('pubspec.yaml');

  static YamlMap getYaml() {
    var yamlMap = YamlMap();
    if (appConfig.getYaml() != null) {
      yamlMap = appConfig.getYaml();
    }
    return yamlMap;
  }

  static YamlMap getPubspecConfig() {
    return pubspecConfig.getYaml();
  }
}
