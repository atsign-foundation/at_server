import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_utils.dart';

abstract class SyncKeysFetchStrategy {
  final _logger = AtSignLogger('SyncKeysFetchStrategy');
  bool shouldIncludeEntryInSyncResponse(
      CommitEntry commitEntry, int commitId, String regex,
      {List<String>? enrolledNamespace});

  bool shouldIncludeKeyInSyncResponse(String atKey, String regex,
      {List<String>? enrolledNamespace}) {
    return isNamespaceAuthorised(atKey, enrolledNamespace) &&
        (keyMatchesRegex(atKey, regex) || alwaysIncludeInSync(atKey));
  }

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
