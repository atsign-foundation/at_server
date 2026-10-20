import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';

/// The namespaces this atServer keeps for itself that a segment uses when it
/// begins with one of them.
final List<String> _ownNamespaces = [
  EnrollmentConstants.enrollManageNamespace,
  EnrollmentConstants.globalNamespace,
  AtConstants.atServerReservedNamespace,
  '__private',
  _passcodeNamespace,
  '__config',
];

/// The namespace this atServer keeps for itself that a segment uses only
/// when it is that namespace.
const String _ownExactNamespace = '__e';

/// The namespace in which this atServer keeps passcodes.
const String _passcodeNamespace = '__otp';

/// The key, without its owner, at which a semi-permanent passcode may be held
/// outside [_passcodeNamespace].
const String _sppOutsidePasscodeNamespace = 'private:spp';

/// The characters at_commons allows in a key it builds.
final RegExp _wellFormedAtKey =
    RegExp('^(?:${Regexes.charsInEntity}|${Regexes.allowedEmoji})+\$');

/// A leading `cached:` and then `public:`, each at most once.
final RegExp _scope = RegExp('^(?:cached:)?(?:public:)?', caseSensitive: false);

/// Every leading `cached:` and `public:`, however many.
final RegExp _everyScope =
    RegExp('^(?:cached:|public:)*', caseSensitive: false);

/// Whether [atKey], without any `cached:` or `public:` prefix, has only the
/// characters at_commons allows in a key it builds.
bool isWellFormedAtKey(String atKey) =>
    _wellFormedAtKey.hasMatch(atKey.replaceFirst(_scope, ''));

/// The reserved namespace [atKey] uses, after every `cached:` and `public:`
/// prefix: its last dot-separated segment when that, folded, begins with "__",
/// else its first segment that, folded, is `__e` or begins with another of
/// this atServer's own namespaces; null when it uses none.
String? reservedNamespaceOf(String atKey) {
  final List<String> segments = atKey.replaceFirst(_everyScope, '').split('.');
  if (canonicalAtKey(segments.last).startsWith('__')) {
    return segments.last;
  }
  for (final String segment in segments) {
    final String folded = canonicalAtKey(segment);
    if (folded == _ownExactNamespace || _ownNamespaces.any(folded.startsWith)) {
      return segment;
    }
  }
  return null;
}

/// The reserved namespace that keeps a client of [atSign], on a connection
/// that is enrollment [enrollmentId], from changing the record [atKey]
/// directly; null when [atKey] is a cached copy of another atSign's record,
/// uses no reserved namespace, or lies in that enrollment's own
/// per-enrollment namespace. A cram connection, which has no [enrollmentId],
/// counts as enrollment primary.
String? reservedNamespaceBarringChange(String atKey,
    {required Atsign atSign, required String? enrollmentId}) {
  String key = canonicalAtKey(atKey);
  final int owner = key.lastIndexOf('@');
  if (owner > 0) {
    if (key.startsWith('${AtConstants.cached}:') &&
        key.substring(owner) != canonicalAtKey('$atSign')) {
      return null;
    }
    key = key.substring(0, owner);
  }
  key = key.replaceFirst(_everyScope, '');
  if (key.startsWith('@')) {
    key = key.substring(key.indexOf(':') + 1);
  }
  final String ownNamespace =
      '.${canonicalAtKey(enrollmentId ?? EnrollmentManager.primaryEnrollmentId)}'
      '.${EnrollmentConstants.perEnrollmentApproved}';
  if (key.endsWith(ownNamespace)) {
    return null;
  }
  return reservedNamespaceOf(key);
}

/// A per-enrollment namespace at the end of a key: `<enrollmentId>.a.__e`,
/// `.r.__e` or `.d.__e`.
final RegExp _perEnrollmentNamespace = RegExp(r'\.[^.:@]+\.[ard]\.__e$');

/// Whether [atKey], a record of [atSign], lies in a per-enrollment namespace
/// and is shared with an atSign other than [atSign].
bool isPerEnrollmentRecordForAnotherAtSign(String atKey,
    {required Atsign atSign}) {
  String key = canonicalAtKey(atKey);
  final int owner = key.lastIndexOf('@');
  if (owner > 0) {
    key = key.substring(0, owner);
  }
  key = key.replaceFirst(_everyScope, '');
  if (!key.startsWith('@') ||
      !key.contains(':') ||
      !_perEnrollmentNamespace.hasMatch(key)) {
    return false;
  }
  return key.substring(0, key.indexOf(':')) != canonicalAtKey('$atSign');
}

/// Whether [atKey] is a record that holds a passcode: one in `__otp`, or a
/// semi-permanent passcode held outside it.
bool isPasscodeRecord(String atKey) {
  final String key = canonicalAtKey(atKey);
  final int owner = key.lastIndexOf('@');
  return (owner > 0 ? key.substring(0, owner) : key) ==
          _sppOutsidePasscodeNamespace ||
      canonicalAtKey(reservedNamespaceOf(atKey) ?? '')
          .startsWith(_passcodeNamespace);
}

/// The reserved namespace the notification keyed [notification] uses, read
/// from the key between any leading `@recipient:` and any trailing
/// `@sender`; null when it uses none.
String? reservedNamespaceOfNotification(String notification) {
  String atKey = notification;
  if (atKey.startsWith('@')) {
    atKey = atKey.substring(atKey.indexOf(':') + 1);
  }
  final int sender = atKey.lastIndexOf('@');
  if (sender > 0) {
    atKey = atKey.substring(0, sender);
  }
  return reservedNamespaceOf(atKey);
}
