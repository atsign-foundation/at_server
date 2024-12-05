import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_utils.dart';

abstract class SyncKeysFetchStrategy {
  final _logger = AtSignLogger('SyncKeysFetchStrategy');

  /// Returns true if the commit entry should be included in sync response, false otherwise
  bool shouldIncludeEntryInSyncResponse(
      CommitEntry commitEntry, int commitId, String regex,
      {List<String>? enrolledNamespace});

  /// if enrolledNamespace is passed, key namespace should be in enrolledNamespace list and
  /// atKey should match regex or should be a special key that is always included in sync.
  bool shouldIncludeKeyInSyncResponse(String atKey, String regex,
      {List<String>? enrolledNamespace}) {
    return isNamespaceAuthorised(atKey, enrolledNamespace) &&
        (keyMatchesRegex(atKey, regex) || alwaysIncludeInSync(atKey));
  }

  /// Returns true if atKey namespace is empty or null/ enrolledNamespace is empty or null
  /// if enrolledNamespace contains atKey namespace, return true. false otherwise
  bool isNamespaceAuthorised(
      String atKeyAsString, List<String>? enrolledNamespace) {
    // This is work-around for : https://github.com/atsign-foundation/at_server/issues/1570
    if (atKeyAsString.toLowerCase() == 'configkey') {
      return true;
    }
    late AtKey atKey;
    try {
      atKey = AtKey.fromString(atKeyAsString);
    } on InvalidSyntaxException catch (_) {
      _logger.warning(
          '_isNamespaceAuthorized found an invalid key "$atKeyAsString" in the commit log. Returning false');
      return false;
    }
    String? keyNamespace = atKey.namespace;
    // If enrolledNamespace is null or keyNamespace is null, fallback to
    // existing behaviour - the key is authorized for the client to receive. So return true.
    if (enrolledNamespace == null ||
        enrolledNamespace.isEmpty ||
        (keyNamespace == null || keyNamespace.isEmpty)) {
      return true;
    }
    if (enrolledNamespace.contains('*') ||
        enrolledNamespace.contains(keyNamespace)) {
      return true;
    }
    return false;
  }

  /// Returns true if atKey matches regex. false otherwise
  bool keyMatchesRegex(String atKey, String regex) {
    return RegExp(regex).hasMatch(atKey);
  }

  /// match keys which have to included in sync irrespective of whether regex matches
  /// e.g @bob:shared_key@alice, shared_key.bob@alice, public:publickey@alice,
  /// public:phone@alice (public key without namespace)
  bool alwaysIncludeInSync(String atKey) {
    return (atKey.contains(AtConstants.atEncryptionSharedKey) &&
            RegexUtil.keyType(atKey, false) == KeyType.reservedKey) ||
        atKey.startsWith(AtConstants.atEncryptionPublicKey) ||
        (atKey.startsWith('public:') && !atKey.contains('.'));
  }
}
