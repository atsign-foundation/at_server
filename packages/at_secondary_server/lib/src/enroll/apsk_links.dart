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

  /// What one write of an approved enrollment's `_apsk` record stores,
  /// decided the same way for every writer.
  ///
  /// The appMetadata stored is [written], or [stored]'s when the write sends
  /// none, carrying [stored]'s links less those [value] no longer lets stand:
  /// a link stays on a key only while its kid is listed once and the link
  /// names the alg and pub listed under it, and never on the enrollment's
  /// authentication key, which [isAuthenticationKey] names.
  ///
  /// Where [refusable], the write is refused with [IllegalStateException]
  /// over an immutable record, and with [IllegalArgumentException] when
  /// [value] lists a kid twice or an entry without a string kid, alg and pub,
  /// lists the authentication key beside another key, carries a link on that
  /// key under [refuseLinkOnAuthenticationKey], or would take the record with
  /// its links over [limit] bytes. Where it is not, an immutable record is
  /// left as it stands, every other case keeps fewer links, and each is
  /// reported to [warn]. [writesRecord] false applies only the
  /// authentication-key checks, for a write that leaves the record itself as
  /// it stands.
  static ApskWrite settle(
      {required String writer,
      required String? value,
      required AtData? stored,
      AppMetadata? written,
      bool Function(String pub)? isAuthenticationKey,
      bool refuseLinkOnAuthenticationKey = false,
      bool writesRecord = true,
      required bool refusable,
      required int limit,
      required void Function(String message) warn}) {
    void refuse(Exception refusal, String message) {
      if (refusable) throw refusal;
      warn('$writer: $message');
    }

    if (writesRecord && stored?.metaData?.immutable == true) {
      refuse(
          IllegalStateException('$writer: the _apsk record is immutable, and'
              ' immutable records may not be updated'),
          'the _apsk record is immutable, and is left as it stands');
      return const ApskWrite._(null, proceeds: false);
    }

    final ApskValue parsed = ApskValue.parse(value);
    final String? malformed = writesRecord ? parsed.malformed : null;
    if (malformed != null) {
      refuse(IllegalArgumentException('$writer: its _apsk $malformed'),
          'its _apsk $malformed, so no link stays on that kid');
    }

    final Map<String, dynamic> links =
        pruned(linksIn(stored?.metaData?.appMetadata), parsed.keys);
    if (isAuthenticationKey != null) {
      for (final ({String? kid, String pub}) key in parsed.listedKeys) {
        if (!isAuthenticationKey(key.pub)) continue;
        final String named = key.kid ?? 'an entry';
        if (parsed.count > 1) {
          refuse(
              IllegalArgumentException('$writer: its _apsk lists its'
                  ' apkamPublicKey as $named beside another key, and an'
                  ' authentication key may be listed only alone'),
              'its _apsk lists its apkamPublicKey as $named beside another'
              ' key');
        }
        if (key.kid != null && links.containsKey(key.kid)) {
          if (refuseLinkOnAuthenticationKey) {
            refuse(
                IllegalArgumentException('$writer: its apkamPublicKey, listed'
                    ' as $named, would carry a link, and an authentication'
                    ' key takes none'),
                'its apkamPublicKey, listed as $named, carried a link, which'
                ' is removed');
          }
          links.remove(key.kid);
        }
      }
    }

    final AppMetadata? base = written ?? stored?.metaData?.appMetadata;
    AppMetadata? appMetadata = withLinks(base, links);
    if (writesRecord &&
        links.isNotEmpty &&
        recordBytes(value, appMetadata) > limit) {
      refuse(
          IllegalArgumentException('$writer: the _apsk record would be'
              ' ${recordBytes(value, appMetadata)} bytes encoded with the links'
              ' it keeps, over the $limit byte enrollment record limit'),
          'the _apsk record would be over the $limit byte enrollment record'
          ' limit with its links, so it keeps none');
      appMetadata = withLinks(base, const {});
    }
    return ApskWrite._(appMetadata, proceeds: true);
  }

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

  /// The length of an `_apsk` record holding [value] and [appMetadata],
  /// measured as `enroll:link` measures it: the value's bytes and the
  /// appMetadata's JSON bytes.
  static int recordBytes(String? value, AppMetadata? appMetadata) =>
      utf8.encode(value ?? '').length +
      utf8.encode(jsonEncode(appMetadata?.toJson())).length;

  /// Throws [IllegalArgumentException] when an `_apsk` record holding [value]
  /// and [appMetadata] is over [limit] bytes as [recordBytes] measures it;
  /// [writer] names the write in the message.
  static void refuseOverLimit(
      String writer, String? value, AppMetadata? appMetadata,
      {required int limit}) {
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

/// What [ApskLinks.settle] decided for one write of an `_apsk` record.
final class ApskWrite {
  const ApskWrite._(this.appMetadata, {required this.proceeds});

  /// The appMetadata the write stores.
  final AppMetadata? appMetadata;

  /// False when the write must leave the record as it stands.
  final bool proceeds;
}

/// An `_apsk` record's value as the atServer reads it: trimmed, as a client
/// reading it trims it, and decoded once.
final class ApskValue {
  ApskValue._(this.text, this.entries);

  /// [value] read as an `_apsk` record's value.
  factory ApskValue.parse(String? value) {
    final String text = value?.trim() ?? '';
    if (text.isEmpty) return ApskValue._(null, const []);
    if (!text.startsWith('{')) return ApskValue._(text, null);
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    final Object? entries = decoded is Map ? decoded['keys'] : null;
    return ApskValue._(text, entries is List ? entries : const []);
  }

  /// The value trimmed, or null when it is empty.
  final String? text;

  /// The list form's entries as sent, repeated and malformed ones included;
  /// null for a bare value, empty for a value that does not decode as the
  /// list form.
  final List<Object?>? entries;

  /// How many keys the value lists: one for a bare value, and every entry of
  /// the list form, repeated or malformed ones included.
  int get count => text == null ? 0 : entries?.length ?? 1;

  /// The first entry that lists no string `kid`, `alg` and `pub`, or repeats
  /// an earlier entry's kid, described for a refusal; null when every entry
  /// is well formed.
  late final String? malformed = () {
    final List<Object?> listed = entries ?? const [];
    final Set<String> kids = {};
    for (int i = 0; i < listed.length; i++) {
      final Object? entry = listed[i];
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
  }();

  /// The kids the list form lists more than once.
  late final Set<String> repeatedKids = () {
    final Set<String> seen = {};
    final Set<String> repeated = {};
    for (final Object? entry in entries ?? const []) {
      final Object? kid = entry is Map ? entry['kid'] : null;
      if (kid is String && !seen.add(kid)) repeated.add(kid);
    }
    return repeated;
  }();

  /// The keys the value lists, by kid: a bare value is one
  /// [ApskLinks.bareAlgorithm] key whose kid is [ApskLinks.kidOf] it, and the
  /// list form each kid it lists once with a string kid, alg and pub.
  late final Map<String, ApskKey> keys = () {
    final String? bare = entries == null ? text : null;
    if (bare != null) {
      final String? kid = ApskLinks.kidOf(bare);
      return kid == null
          ? const <String, ApskKey>{}
          : {kid: (alg: ApskLinks.bareAlgorithm, pub: bare)};
    }
    final Map<String, ApskKey> keys = {};
    for (final Object? entry in entries ?? const []) {
      if (entry is! Map) continue;
      final Object? kid = entry['kid'];
      final Object? alg = entry['alg'];
      final Object? pub = entry['pub'];
      if (kid is! String || alg is! String || pub is! String) continue;
      if (repeatedKids.contains(kid)) continue;
      keys[kid] = (alg: alg, pub: pub);
    }
    return keys;
  }();

  /// Each public key the value lists, with the kid it is listed under, or
  /// null where that is not a string; a bare value is one key.
  late final List<({String? kid, String pub})> listedKeys = () {
    final String? bare = entries == null ? text : null;
    if (bare != null) return [(kid: ApskLinks.kidOf(bare), pub: bare)];
    return [
      for (final Object? entry in entries ?? const [])
        if (entry is Map && entry['pub'] is String)
          (
            kid: entry['kid'] is String ? entry['kid'] as String : null,
            pub: entry['pub'] as String
          )
    ];
  }();
}
