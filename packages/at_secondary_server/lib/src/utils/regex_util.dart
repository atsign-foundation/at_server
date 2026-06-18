import 'dart:collection';
import 'package:at_commons/at_commons.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_utils/at_utils.dart';

final logger = AtSignLogger('RegexUtil');

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

/// True if [atKey] should be included in a sync-shaped response
/// (server-to-client sync, or the lastCommitID metric) for [regex]
/// (and, if non-null, [enrolledNamespace]). Included when its
/// namespace is authorised for the enrollment AND it either
/// matches the regex or is in the always-include set.
bool shouldIncludeKeyInSyncResponse(String atKey, String regex,
    {List<String>? enrolledNamespace}) {
  return isNamespaceAuthorised(atKey, enrolledNamespace) &&
      (RegExp(regex).hasMatch(atKey) || alwaysIncludeInSync(atKey));
}

/// True when the atKey's namespace is in [enrolledNamespace] (or
/// authorisation is effectively unrestricted: caller passed
/// null/empty, the atKey carries no namespace, or the enrollment
/// list contains '*'). The bare 'configkey' is always authorised
/// — see github.com/atsign-foundation/at_server/issues/1570.
bool isNamespaceAuthorised(
    String atKeyAsString, List<String>? enrolledNamespace) {
  if (atKeyAsString.toLowerCase() == 'configkey') return true;
  late AtKey atKey;
  try {
    atKey = AtKey.fromString(atKeyAsString);
  } on InvalidSyntaxException catch (_) {
    logger.warning(
        'isNamespaceAuthorised found an invalid key "$atKeyAsString" in the commit log. Returning false');
    return false;
  }
  final keyNamespace = atKey.namespace;
  if (enrolledNamespace == null ||
      enrolledNamespace.isEmpty ||
      keyNamespace == null ||
      keyNamespace.isEmpty) {
    return true;
  }
  return enrolledNamespace.contains('*') ||
      enrolledNamespace.contains(keyNamespace);
}
