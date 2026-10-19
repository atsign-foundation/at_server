import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:crypto/crypto.dart';

/// A key an `_apsk` record advertises.
typedef ApskKey = ({String alg, String pub});

/// The links that vouch for an enrollment's client data signing keys: one per
/// key its `_apsk` record advertises, keyed by kid, in that record's
/// appMetadata.
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

    final Map<String, ApskKey> keys = {};
    for (final Object? entry in listedEntries(value)) {
      if (entry is! Map) continue;
      final Object? kid = entry['kid'];
      final Object? alg = entry['alg'];
      final Object? pub = entry['pub'];
      if (kid is! String || alg is! String || pub is! String) continue;
      keys.putIfAbsent(kid, () => (alg: alg, pub: pub));
    }
    return keys;
  }

  /// The entries [value], an `_apsk` record's value in the list form, lists
  /// as sent, repeated kids and malformed entries included; empty for a bare
  /// value or one that does not decode as the list form.
  static List<Object?> listedEntries(String? value) {
    if (value == null || !value.trimLeft().startsWith('{')) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      return const [];
    }
    final Object? entries = decoded is Map ? decoded['keys'] : null;
    return entries is List ? entries : const [];
  }

  /// How many keys [value] lists: one for a bare value, and every entry of
  /// the list form, repeated or malformed ones included.
  static int listedCount(String? value) {
    if (value == null || value.isEmpty) return 0;
    if (!value.trimLeft().startsWith('{')) return 1;
    return listedEntries(value).length;
  }

  /// Each public key [value] lists, with the kid it is listed under, or null
  /// where that is not a string; a bare value is one key.
  static List<({String? kid, String pub})> listedKeys(String? value) {
    if (value == null || value.isEmpty) return const [];
    if (!value.trimLeft().startsWith('{')) {
      return [(kid: kidOf(value), pub: value)];
    }
    return [
      for (final Object? entry in listedEntries(value))
        if (entry is Map && entry['pub'] is String)
          (
            kid: entry['kid'] is String ? entry['kid'] as String : null,
            pub: entry['pub'] as String
          )
    ];
  }

  /// The first entry of [value] that lists no string `kid`, `alg` and `pub`,
  /// or repeats an earlier entry's kid, described for a refusal; null when
  /// every entry is well formed.
  static String? malformedEntry(String? value) {
    final List<Object?> entries = listedEntries(value);
    final Set<String> kids = {};
    for (int i = 0; i < entries.length; i++) {
      final Object? entry = entries[i];
      if (entry is! Map ||
          entry['kid'] is! String ||
          entry['alg'] is! String ||
          entry['pub'] is! String) {
        return 'entry ${i + 1} lists no string kid, alg and pub';
      }
      if (!kids.add(entry['kid'] as String)) {
        return 'entry ${i + 1} lists kid ${entry['kid']} a second time';
      }
    }
    return null;
  }

  /// The link map [appMetadata] holds, or an empty map.
  static Map<String, dynamic> linksIn(AppMetadata? appMetadata) {
    final Object? links = appMetadata?.additional?[field];
    return links is Map ? Map<String, dynamic>.from(links) : {};
  }

  /// [links] less those [advertised] no longer lets stand: a link for a kid
  /// it does not list, a link whose payload names another alg or pub than
  /// the one listed under its kid, and a link on a key
  /// [isAuthenticationKey] names.
  static Map<String, dynamic> pruned(
          Map<String, dynamic> links, Map<String, ApskKey> advertised,
          {bool Function(String pub)? isAuthenticationKey}) =>
      {
        for (final MapEntry<String, dynamic> link in links.entries)
          if (_namesListedKey(link.key, link.value, advertised[link.key]) &&
              !(isAuthenticationKey?.call(advertised[link.key]!.pub) ?? false))
            link.key: link.value
      };

  /// Whether [link], stored under [kid], names [listed], the key the record
  /// lists under that kid.
  static bool _namesListedKey(String kid, Object? link, ApskKey? listed) {
    if (listed == null) return false;
    final Map<String, dynamic>? payload = payloadOf(link);
    return payload != null &&
        payload['kid'] == kid &&
        payload['alg'] == listed.alg &&
        payload['pub'] == listed.pub;
  }

  /// [appMetadata] with its link map replaced by [links], dropped when
  /// [links] is empty; null when there is nothing left to store, including
  /// when removing the last link leaves only the [providerId] the atServer
  /// gives.
  static AppMetadata? withLinks(
      AppMetadata? appMetadata, Map<String, dynamic> links) {
    if (appMetadata == null && links.isEmpty) return null;
    final Map<String, dynamic> additional = {...?appMetadata?.additional}
      ..remove(field);
    if (links.isNotEmpty) additional[field] = links;
    final String provider = appMetadata?.providerId ?? providerId;
    if (links.isEmpty &&
        additional.isEmpty &&
        provider == providerId &&
        (appMetadata?.additional?.containsKey(field) ?? false)) {
      return null;
    }
    return AppMetadata(providerId: provider, additional: additional);
  }

  /// The appMetadata a write of an `_apsk` record other than `enroll:link`
  /// stores: [written], or [stored] when it sends none, carrying [stored]'s
  /// link map less the links [value] no longer lets stand, whatever
  /// [written] holds.
  static AppMetadata? carriedOver(
          {required AppMetadata? written,
          required AppMetadata? stored,
          required String? value,
          bool Function(String pub)? isAuthenticationKey}) =>
      withLinks(
          written ?? stored,
          pruned(linksIn(stored), advertisedKeys(value),
              isAuthenticationKey: isAuthenticationKey));

  /// The length of an `_apsk` record holding [value] and [appMetadata],
  /// measured as `enroll:link` measures it: the value's bytes and the
  /// appMetadata's JSON bytes.
  static int recordBytes(String? value, AppMetadata? appMetadata) =>
      utf8.encode(value ?? '').length +
      utf8.encode(jsonEncode(appMetadata?.toJson())).length;

  /// Throws [IllegalArgumentException] when an `_apsk` record holding [value]
  /// and [appMetadata] keeps links and is over [limit] bytes as
  /// [recordBytes] measures it; [writer] names the write in the message.
  static void refuseOverLimit(
      String writer, String? value, AppMetadata? appMetadata,
      {required int limit}) {
    if (linksIn(appMetadata).isEmpty) return;
    final int length = recordBytes(value, appMetadata);
    if (length > limit) {
      throw IllegalArgumentException('$writer: the _apsk record would be'
          ' $length bytes encoded with the links it keeps, over the $limit'
          ' byte enrollment record limit');
    }
  }

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
