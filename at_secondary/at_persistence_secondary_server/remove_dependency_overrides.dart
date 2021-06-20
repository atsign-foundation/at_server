import 'dart:io';
import 'package:json2yaml/json2yaml.dart';
import 'package:yaml/yaml.dart';

void remove_dependency_overrides(String path) {
  var _yamlMap = YamlMap();
  if (File(path).existsSync()) {
    _yamlMap = loadYaml(File(path).readAsStringSync());
  }
  var yamlMap = Map<String, dynamic>.from(_yamlMap);
  //Quotes are not preserved. Hence inserting a custom map.
  yamlMap['environment'] = {'sdk': yamlMap['environment']['sdk']};
  yamlMap.remove('dependency_overrides');
  var test = json2yaml(yamlMap, yamlStyle: YamlStyle.pubspecYaml);
  print(test);
  File(path).writeAsStringSync(test);
}

void main(){
  remove_dependency_overrides('pubspec.yaml');
}