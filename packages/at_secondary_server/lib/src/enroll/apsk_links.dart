import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:crypto/crypto.dart';

/// A key an `_apsk` record advertises.
typedef ApskKey = ({String alg, String pub});

/// The links that vouch for an enrollment's signing keys: one per key its
/// `_apsk` record advertises, keyed by kid, in that record's appMetadata.
///
/// The atServer checks a link's structure and never its signature; whoever
/// reads a link verifies it.
abstract final class ApskLinks {
  /// The appMetadata field holding the link map.
  static const String field = 'apskLinks';

  /// The providerId given to appMetadata the atServer creates on an `_apsk`
  /// record: the one a reader assumes for a record that carries none.
  static const String providerId = 'legacy';

  /// The longest link `enroll:link` stores, measured on its JSON encoding.
  static const int maxLinkBytes = 16 * 1024;

  /// The algorithm a bare `_apsk` value is: an RSA-2048 public key.
  static const String bareAlgorithm = 'rsa2048';

  static const String _keyPrefix = 'public:_apsk.';

  /// The key of enrollment [enrollmentId]'s `_apsk` record on [atSign].
  static String keyFor(String enrollmentId, String atSign) =>
      '$_keyPrefix$enrollmentId'
      '.${EnrollmentConstants.perEnrollmentApproved}$atSign';

  /// The enrollment id [atKey] names when it is an approved enrollment's
  /// `_apsk` record on [atSign], and null for any other key.
  static String? enrollmentIdOf(String atKey, String atSign) {
    final String key = canonicalAtKey(atKey);
    final String suffix =
        canonicalAtKey('.${EnrollmentConstants.perEnrollmentApproved}$atSign');
    if (!key.startsWith(_keyPrefix) ||
        !key.endsWith(suffix) ||
        key.length <= _keyPrefix.length + suffix.length) {
      return null;
    }
    final String id =
        key.substring(_keyPrefix.length, key.length - suffix.length);
    return RegExp(r'^[^.:@]+$').hasMatch(id) ? id : null;
  }

  /// The kid of the public key [pub] holds as base64: the first 8 bytes,
  /// hex-encoded, of the SHA-256 of the decoded key. Null when [pub] is not
  /// base64.
  static String? kidOf(String pub) {
    try {
      return sha256.convert(base64Decode(pub)).toString().substring(0, 16);
    } on FormatException {
      return null;
    }
  }

  /// Whether [pub] is spelt as clients write a public key: non-empty, padded
  /// standard base64 that encodes back to itself.
  static bool isCanonical(String pub) {
    try {
      return pub.isNotEmpty && base64Encode(base64Decode(pub)) == pub;
    } on FormatException {
      return false;
    }
  }

  /// The keys [value], an `_apsk` record's value, advertises, by kid.
  ///
  /// The list form advertises each entry carrying a string `kid`, `alg` and
  /// `pub`; a bare value is one [bareAlgorithm] key whose kid is [kidOf] it.
  static Map<String, ApskKey> advertisedKeys(String? value) {
    if (value == null || value.isEmpty) return const {};

    if (!value.trimLeft().startsWith('{')) {
      final String? kid = kidOf(value);
      return kid == null ? const {} : {kid: (alg: bareAlgorithm, pub: value)};
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      return const {};
    }
    final Object? entries = decoded is Map ? decoded['keys'] : null;
    if (entries is! List) return const {};
    final Map<String, ApskKey> keys = {};
    for (final Object? entry in entries) {
      if (entry is! Map) continue;
      final Object? kid = entry['kid'];
      final Object? alg = entry['alg'];
      final Object? pub = entry['pub'];
      if (kid is! String || alg is! String || pub is! String) continue;
      keys.putIfAbsent(kid, () => (alg: alg, pub: pub));
    }
    return keys;
  }

  /// The link map [appMetadata] holds, or an empty map.
  static Map<String, dynamic> linksIn(AppMetadata? appMetadata) {
    final Object? links = appMetadata?.additional?[field];
    return links is Map ? Map<String, dynamic>.from(links) : {};
  }

  /// [links] less those for keys not in [advertised].
  static Map<String, dynamic> pruned(
          Map<String, dynamic> links, Map<String, ApskKey> advertised) =>
      {
        for (final MapEntry<String, dynamic> link in links.entries)
          if (advertised.containsKey(link.key)) link.key: link.value
      };

  /// [appMetadata] with its link map replaced by [links], dropped when
  /// [links] is empty; null when there is nothing left to store.
  static AppMetadata? withLinks(
      AppMetadata? appMetadata, Map<String, dynamic> links) {
    if (appMetadata == null && links.isEmpty) return null;
    final Map<String, dynamic> additional = {...?appMetadata?.additional}
      ..remove(field);
    if (links.isNotEmpty) additional[field] = links;
    return AppMetadata(
        providerId: appMetadata?.providerId ?? providerId,
        additional: additional);
  }

  /// The appMetadata a write of an `_apsk` record other than `enroll:link`
  /// stores: [written], or [stored] when it sends none, carrying [stored]'s
  /// link map less links for keys [value] does not advertise, whatever
  /// [written] holds.
  static AppMetadata? carriedOver(
          {required AppMetadata? written,
          required AppMetadata? stored,
          required String? value}) =>
      withLinks(
          written ?? stored, pruned(linksIn(stored), advertisedKeys(value)));

  /// The payload [link] signs, or null when it carries none: a chain link
  /// carries it base64url-encoded, a root link as a JSON object.
  static Map<String, dynamic>? payloadOf(Object? link) {
    if (link is! Map) return null;
    final Object? payload = link['payload'];
    if (payload is Map) return Map<String, dynamic>.from(payload);
    if (payload is! String) return null;
    try {
      final Object? decoded = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(payload))));
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }
}
