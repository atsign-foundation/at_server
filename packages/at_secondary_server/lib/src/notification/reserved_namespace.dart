import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// The namespaces this atServer keeps for itself that a segment uses when it
/// begins with one of them.
final List<String> _ownNamespaces = [
  EnrollmentConstants.enrollManageNamespace,
  EnrollmentConstants.globalNamespace,
  AtConstants.atServerReservedNamespace,
  '__private',
  '__otp',
  '__config',
];

/// The namespace this atServer keeps for itself that a segment uses only
/// when it is that namespace.
const String _ownExactNamespace = '__e';

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
