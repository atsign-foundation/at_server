import 'dart:collection';
import 'package:at_utils/at_logger.dart';

var logger = AtSignLogger('RegexUtil');

Iterable<RegExpMatch> getMatches(RegExp regex, String command) {
  var matches = regex.allMatches(command);
  return matches;
}

HashMap<String, String> processMatches(Iterable<RegExpMatch> matches) {
  var paramsMap = HashMap<String, String>();
  matches.forEach((f) {
    for (var name in f.groupNames) {
      paramsMap.putIfAbsent(name, () => f.namedGroup(name));
    }
  });
  return paramsMap;
}
