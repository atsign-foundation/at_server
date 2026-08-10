import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';
import 'package:crypton/crypton.dart';
import 'package:uuid/uuid.dart';

class SecondaryUtil {
  static var logger = AtSignLogger('Secondary_Util');

  /// It is very important that this always begin with a *single*
  /// underscore, otherwise we would fill up the commit log with unnecessary
  /// entries.
  ///
  /// Explanation: The From handler creates records to support the
  /// challenge-response mechanisms of cram, pkam and pol commands. Those
  /// record IDs begin with this sessionId, and the records for pol are created
  /// as `public:<sessionId>`. AtCommitLog **won't** make entries for records
  /// whose IDs start with `public:_`, but **will** make entries for records
  /// whose IDs start with `public:__`
  static String makeSessionId() {
    return '_${Uuid().v4()}';
  }

  static Future<void> saveCookie(
      String key, String value, AtKeyValueStore keyValueStore) async {
    logger.finer('In Secondary Util saveCookie');
    logger.finer('saveCookie key : $key');
    logger.finer('signed challenge : $value');
    var atData = AtData();
    atData.data = value;
    atData.metaData = AtMetaData()..ttl = 60 * 1000;
    await keyValueStore.put('public:$key', atData); //expire in 1 min
  }

  static List<String> getSecondaryInfo(String url) {
    var result = <String>[];
    if (url.contains(':')) {
      var arr = url.split(':');
      result.add(arr[0]);
      result.add(arr[1]);
    }
    return result;
  }

  static List<String> getCookieParams(String fromResult) {
    var proof = fromResult.replaceFirst('\n@', '');
    proof = proof.trim();
    logger.info('proof : $proof');
    List listAnswer = proof.split(':');
    return listAnswer as List<String>;
  }

  static String convertCommand(String command) {
    var index = command.indexOf(':');
    // For verbs that does not have ':'. For example verbs like scan, pol.
    if (index == -1) {
      command = command.toLowerCase();
      return command;
    }
    var verb = command.substring(0, index);
    var key = command.substring(index, command.length);
    verb = verb.toLowerCase().replaceAll(' ', '');
    command = verb + key;
    return command;
  }

  /// Checks if this record is 'active' i.e. it is non-null, it's been 'born', and it is still 'alive'.
  /// * If [Metadata.availableAt] is set, and we've not reached that time yet, return `false`,
  ///   as the record hasn't yet been 'born'
  /// * If [Metadata.expiresAt] is set, and we've passed that time, return `false`,
  ///   as the record is no longer 'alive'
  /// * Otherwise return `true`
  static bool isActiveKey(AtData? atData) {
    if (atData == null) {
      return false;
    }
    var now = DateTime.now().millisecondsSinceEpoch;
    if (atData.metaData != null) {
      var birthTime = atData.metaData!.availableAt;
      var endOfLifeTime = atData.metaData!.expiresAt;
      if (logger.isLoggable('finest')) {
        logger.finest(
            'isActiveKey ${atData.key} found birthTime $birthTime and endOfLifeTime $endOfLifeTime');
      }
      if (birthTime == null && endOfLifeTime == null) return true;
      if (birthTime != null) {
        var ttbMillis = birthTime.toUtc().millisecondsSinceEpoch;
        if (ttbMillis > now) {
          return false;
        }
      }
      if (endOfLifeTime != null) {
        var ttlMillis = endOfLifeTime.toUtc().millisecondsSinceEpoch;
        if (ttlMillis < now) {
          return false;
        }
      }
      return true;
    } else {
      return true;
    }
  }

  static String signChallenge(String challenge, String privateKey) {
    var key = RSAPrivateKey.fromString(privateKey);
    challenge = challenge.trim();
    var signature = key.createSHA256Signature(utf8.encode(challenge));
    return base64Encode(signature);
  }

  /// Marks a verifier-bound pol challenge. A challenge issued to a peer for
  /// pol authentication has the form `<polChallengeV1Prefix><base64Url(json)>`,
  /// where the json names the verifier that issued it (`v`) and carries a fresh
  /// nonce (`n`). The encoding is colon-free so the challenge survives
  /// [getCookieParams]'s `split(':')`, and whitespace-free so it signs and
  /// verifies verbatim.
  ///
  /// The prover ([OutboundClient]) refuses to sign such a challenge unless `v`
  /// names the atSign it actually dialed. A legacy / verifier issues a bare
  /// UUID (no prefix); a legacy prover signs the token / verbatim without
  /// inspecting it — so every version pairing interoperates.
  static const String polChallengeV1Prefix = 'pol1.';

  /// Builds a verifier-bound pol challenge naming [verifierAtSign] and, when
  /// non-null, demanding the one signature type the verifier has chosen.
  ///
  /// The choice lives *inside* the challenge rather than beside it on the
  /// `proof:` line because the prover signs the challenge verbatim: a sibling
  /// field would be unsigned and could be stripped in transit to force a silent
  /// downgrade to RSA. Here, stripping it changes the signed bytes, so the
  /// handshake fails instead.
  ///
  /// `alg` is omitted entirely when [chosenAlgo] is `null` — the verifier
  /// demands nothing, so the prover falls back to legacy RSA. This keeps a
  /// server with no negotiable keys, or no mutual type with this peer, emitting
  /// a token byte-identical to one built before this field existed.
  static String buildBoundPolChallenge(Atsign verifierAtSign,
      {String? chosenAlgo}) {
    final payload = <String, dynamic>{'v': verifierAtSign, 'n': Uuid().v4()};
    if (chosenAlgo != null) {
      payload['alg'] = chosenAlgo;
    }
    return '$polChallengeV1Prefix${base64Url.encode(utf8.encode(jsonEncode(payload)))}';
  }

  /// If [challenge] is a verifier-bound pol challenge, decodes it; returns
  /// `null` for a legacy bare-UUID challenge.
  ///
  /// Fails closed rather than signing something it cannot validate: throws
  /// [FormatException] on a malformed bound challenge (bad base64/JSON, or a
  /// missing/empty `v`), and [InvalidAtSignException] (via [String.toAtsign])
  /// if `v` is present but is not a valid atSign.
  ///
  /// `alg`, by contrast, is lenient — absent or unparseable means "nothing
  /// demanded", never an exception. That opens no downgrade hole: a *stripped*
  /// or mangled `alg` is already caught when the signature over the challenge
  /// is verified against the copy the verifier stored.
  static BoundPolChallenge? decodeBoundPolChallenge(String challenge) {
    if (!challenge.startsWith(polChallengeV1Prefix)) {
      return null;
    }
    final encoded = challenge.substring(polChallengeV1Prefix.length);
    final decoded = jsonDecode(utf8.decode(base64Url.decode(encoded)));
    if (decoded is! Map ||
        decoded['v'] is! String ||
        (decoded['v'] as String).isEmpty) {
      throw const FormatException('malformed bound pol challenge');
    }
    final rawAlg = decoded['alg'];
    return BoundPolChallenge(
        verifier: (decoded['v'] as String).toAtsign(),
        chosenAlgo: (rawAlg is String && rawAlg.isNotEmpty) ? rawAlg : null);
  }

  /// When [key] is supplied, it will be used even if the [atData] already has a key.
  /// This is relevant in the lookup and plookup verb handlers when we need the
  /// client to be able to determine from the response whether the data was
  /// served from cache or not
  static String? prepareResponseData(String? operation, AtData? atData,
      {String? key}) {
    String? result;
    if (atData == null) {
      return result;
    }
    switch (operation) {
      case 'meta':
        result = json.encode(removeNulls(atData.metaData!.toJson()));
        break;
      case 'all':
        var atDataAsMap = atData.toJson();
        if (key != null) {
          atDataAsMap['key'] = key;
        }
        result = json.encode(removeNulls(atDataAsMap));
        break;
      default:
        result = atData.data;
        break;
    }
    if (logger.isLoggable('finer')) {
      logger.finer('prepareResponseData result : $result');
    }
    return result;
  }

  static Map? removeNulls(Map? map) {
    if (map == null) {
      return null;
    }

    Map out = {};
    for (var key in map.keys) {
      var val = map[key];
      if (val == null) {
        continue;
      }
      if (val is Map) {
        val = removeNulls(val);
      }
      out[key] = val;
    }
    return out;
  }

  static NotificationPriority getNotificationPriority(String? arg1) {
    if (arg1 == null) {
      return NotificationPriority.low;
    }
    switch (arg1.toLowerCase()) {
      case 'low':
        return NotificationPriority.low;
      case 'medium':
        return NotificationPriority.medium;
      case 'high':
        return NotificationPriority.high;
      default:
        return NotificationPriority.low;
    }
  }

  static MessageType getMessageType(String? arg1) {
    if (arg1 == null) {
      return MessageType.key;
    }
    switch (arg1.toLowerCase()) {
      case 'key':
        return MessageType.key;
      case 'text':
        return MessageType.text;
      default:
        return MessageType.key;
    }
  }

  static OperationType getOperationType(String? type) {
    if (type == null) {
      return OperationType.update;
    }
    switch (type.toLowerCase()) {
      case 'update':
        return OperationType.update;
      case 'delete':
        return OperationType.delete;
      default:
        return OperationType.update;
    }
  }

  static bool getBoolFromString(String? arg1) {
    if ((arg1 != null && arg1.isNotEmpty) && arg1.toLowerCase() == 'true') {
      return true;
    }
    return false;
  }
}

/// A decoded verifier-bound pol challenge — see
/// [SecondaryUtil.buildBoundPolChallenge].
///
/// Both fields come out of one decode, so a caller checking the verifier and
/// reading the demand parses the token once.
class BoundPolChallenge {
  /// The atSign that issued this challenge, canonicalised so a caller can
  /// compare it directly against a canonicalised dialed atSign. The prover
  /// refuses to sign when this is not who it dialed.
  final Atsign verifier;

  /// The one signature type the verifier has chosen and demands, or `null` if
  /// it demands nothing — the prover then falls back to legacy RSA. The
  /// verifier alone decides this (see [StoredPolChallenge]); it is never the
  /// prover's choice.
  final String? chosenAlgo;

  const BoundPolChallenge({required this.verifier, this.chosenAlgo});
}

/// The verifier's own local record of a pol challenge it issued — what
/// [FromVerbHandler] stores at FROM time and [PolVerbHandler] reads back at
/// POL time, keyed by session and expiring with it.
///
/// This is never sent to the peer as-is (the peer only ever sees [challenge],
/// via [SecondaryUtil.buildBoundPolChallenge]) and is never parsed by anyone
/// but this server, so its shape is free to evolve — unlike [BoundPolChallenge]
/// it carries no wire-compatibility obligation to older builds. It *is*
/// stored under a `public:` key, though, so it is technically fetchable by
/// anyone who guesses the session ID; nothing in it is secret (the peer's
/// public key least of all), but the format still deserves the same care as
/// anything keystore-visible.
///
/// Verification at POL trusts [chosenAlgo] and [peerPublicKey] from here —
/// never anything read off the peer's cookie — which is what makes the
/// verifier's choice of algorithm authoritative rather than advisory.
class StoredPolChallenge {
  /// The exact challenge string handed to the peer, verbatim — what the
  /// peer's signature must be verified against.
  final String challenge;

  /// The signature type this verifier chose and demanded, or `null` if it
  /// demanded nothing (legacy RSA fallback — no mutual type, no peer record,
  /// or this server holds no negotiable key of its own).
  final String? chosenAlgo;

  /// The peer's public key for [chosenAlgo], fetched and cached at FROM time
  /// so POL needs no record fetch of its own. `null` iff [chosenAlgo] is
  /// `null` — the legacy path fetches the peer's RSA key fresh at POL time
  /// instead, since it was never cached.
  final String? peerPublicKey;

  const StoredPolChallenge(
      {required this.challenge, this.chosenAlgo, this.peerPublicKey});

  /// Encodes this record for storage. Deliberately not reusing
  /// [SecondaryUtil.buildBoundPolChallenge]'s wire format: that format has
  /// interop obligations to peers' provers this record does not.
  String encode() => jsonEncode({
        'challenge': challenge,
        if (chosenAlgo != null) 'alg': chosenAlgo,
        if (peerPublicKey != null) 'key': peerPublicKey,
      });

  /// Decodes a value previously produced by [encode]. Throws
  /// [FormatException] on anything else — this server wrote every record it
  /// reads back here, so a decode failure is an internal invariant violation,
  /// not peer-supplied input to fail gracefully on.
  static StoredPolChallenge decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['challenge'] is! String) {
      throw const FormatException('malformed stored pol challenge');
    }
    final alg = decoded['alg'];
    final key = decoded['key'];
    return StoredPolChallenge(
      challenge: decoded['challenge'] as String,
      chosenAlgo: alg is String ? alg : null,
      peerPublicKey: key is String ? key : null,
    );
  }
}
