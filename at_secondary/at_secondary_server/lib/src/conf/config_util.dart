import 'package:at_utils/at_utils.dart';
import 'package:yaml/yaml.dart';

class ConfigUtil {
  static final ApplicationConfiguration appConfig =
      ApplicationConfiguration('config/config.yaml');

  static final ApplicationConfiguration pubspecConfig =
      ApplicationConfiguration('pubspec.yaml');

  static YamlMap getYaml() {
    return appConfig.getYaml();
  }

  static YamlMap getPubspecConfig() {
    return pubspecConfig.getYaml();
  }
}
