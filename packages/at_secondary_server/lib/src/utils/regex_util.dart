import 'dart:collection';
import 'package:at_commons/at_commons.dart';

Iterable<RegExpMatch> getMatches(RegExp regex, String command) {
  var matches = regex.allMatches(command);
  return matches;
}

HashMap<String, String?> processMatches(Iterable<RegExpMatch> matches) {
  var paramsMap = HashMap<String, String?>();
  for (var f in matches) {
    for (var name in f.groupNames) {
      paramsMap.putIfAbsent(name, () => f.namedGroup(name));
    }
  }
  return paramsMap;
}

/// True for atKeys that are always included in sync responses
/// regardless of any caller-supplied regex: encryption shared
/// keys, encryption public keys, and top-level public keys
/// without a namespace (e.g. `public:phone@alice`).
bool alwaysIncludeInSync(String atKey) {
  return (atKey.contains(AtConstants.atEncryptionSharedKey) &&
          RegexUtil.keyType(atKey, false) == KeyType.reservedKey) ||
      atKey.startsWith(AtConstants.atEncryptionPublicKey) ||
      (atKey.startsWith('public:') && !atKey.contains('.'));
}
