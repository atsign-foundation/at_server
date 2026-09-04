import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Pins `update:json` and plain `update:` to one verdict. They are the same
/// keystore behind two doors, and the plain door's validation sits in two
/// places the json door does not pass through: the wire grammar, which pins
/// the atKey to a colon-free token, the value to one non-empty line and the
/// asserted timestamps to UTC, and the tail of `getUpdateParams`.
///
/// The key's NAME is deliberately excluded: the json route exists to reach
/// keys the plain grammar cannot express, and which of those a caller may
/// write is an authorisation question, pinned in root_key_authz_test.dart.
///
/// Every case is a DIFFERENTIAL, running one shape through both forms; a
/// one-armed test here would stay green while the two doors drifted apart.
void main() {
  AtSignLogger.root_level = 'WARNING';

  group('the two update grammars agree on what they refuse', () {
    late UpdateVerbHandler handler;

    setUpAll(() async => await verbTestsSetUpAll());
    setUp(() async {
      await verbTestsSetUp();
      handler = UpdateVerbHandler(
          keyValueStore, statsNotificationService, notificationManager, alice);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = null;
    });
    tearDown(() async => await verbTestsTearDown());

    /// Whether the PLAIN form of [command] is accepted, all the way through
    /// parsing and parameter validation.
    String plainVerdict(String command) {
      try {
        handler.getUpdateParams(
            HashMap<String, String?>.from(getVerbParam(VerbSyntax.update, command)));
        return 'ACCEPTED';
      } on AtException {
        return 'REFUSED';
      }
    }

    /// The same, for the json form carrying [document].
    String jsonVerdict(Map<String, dynamic> document) {
      try {
        handler.getUpdateParams(HashMap<String, String?>.from(getVerbParam(
            VerbSyntax.update, 'update:json:${jsonEncode(document)}')));
        return 'ACCEPTED';
      } on AtException {
        return 'REFUSED';
      }
    }

    /// A well-formed metadata map with [extra] folded in. `Metadata.fromJson`
    /// assigns isBinary/isEncrypted/isPublic into non-nullable bools, so every
    /// document a real client sends carries all three; omitting them exercises
    /// the decoder rather than the validator, asserted separately below.
    Map<String, dynamic> md([Map<String, dynamic> extra = const {}]) => {
          'isBinary': false,
          'isEncrypted': false,
          'isPublic': false,
          ...extra,
        };

    /// Each case: a description, the plain command, the json document, and
    /// the verdict BOTH must reach.
    final cases = <(String, String, Map<String, dynamic>, String)>[
      // ---- the controls: without them a validator that refused everything
      // would satisfy every REFUSED row below.
      (
        'an ordinary key',
        'update:phone@alice 1234',
        {'atKey': 'phone', 'value': '1234', 'sharedBy': '@alice', 'metadata': md()},
        'ACCEPTED',
      ),
      (
        'a shared key with metadata',
        'update:ttl:60000:@bob:phone@alice 1234',
        {
          'atKey': 'phone',
          'value': '1234',
          'sharedBy': '@alice',
          'sharedWith': '@bob',
          'metadata': md({'ttl': 60000})
        },
        'ACCEPTED',
      ),
      (
        // The one atKey the update grammar special-cases, so a CRAM
        // connection can install the atSign's first PKAM key. The charset
        // rules must not catch it.
        'the literal the grammar special-cases',
        'update:privatekey:at_pkam_publickey KEYVALUE',
        {'atKey': 'privatekey:at_pkam_publickey', 'value': 'KEYVALUE', 'metadata': md()},
        'ACCEPTED',
      ),

      // ---- the refusals. The atKey CHARSET is deliberately not among them:
      // update:json exists to name keys the plain grammar cannot express, a
      // namespace-less `privatekey:` key among them, and that wider surface
      // is answered for by authorisation. See root_key_authz_test.dart.
      (
        'an empty value',
        'update:emptyval@alice ',
        {'atKey': 'emptyval', 'value': '', 'sharedBy': '@alice', 'metadata': md()},
        'REFUSED',
      ),
      (
        'a newline in the value, in a line-oriented protocol',
        'update:k@alice a\ndata:injected',
        {'atKey': 'k', 'value': 'a\ndata:injected', 'sharedBy': '@alice', 'metadata': md()},
        'REFUSED',
      ),
      (
        'a negative ttl',
        'update:ttl:-5:negttl@alice v',
        {
          'atKey': 'negttl',
          'value': 'v',
          'sharedBy': '@alice',
          'metadata': md({'ttl': -5})
        },
        'REFUSED',
      ),
      (
        'a foreign sharedBy — another atSign inside this keystore',
        'update:spoof@bob v',
        {'atKey': 'spoof', 'value': 'v', 'sharedBy': '@bob', 'metadata': md()},
        'REFUSED',
      ),
      (
        'an empty atKey',
        'update:@alice v',
        {'atKey': '', 'value': 'v', 'sharedBy': '@alice', 'metadata': md()},
        'REFUSED',
      ),
    ];

    for (final (description, plain, document, expected) in cases) {
      test('$description: both forms $expected it', () {
        expect(plainVerdict(plain), expected,
            reason: 'the PLAIN grammar is the specification here; if this arm '
                'is wrong the case is mis-stated, not the validator');
        expect(jsonVerdict(document), expected,
            reason: 'update:json must reach the same verdict — it is the same '
                'keystore behind a different door');
      });
    }

    test('a non-String value is refused as a bad request, not a server fault',
        () {
      // A raw Dart TypeError would reach the client as InternalServerError,
      // leaving a caller unable to tell its own malformed document from a
      // server fault.
      for (final bad in [42, true, null, <String, String>{}]) {
        expect(
            () => jsonVerdict({'atKey': 'k', 'value': bad, 'sharedBy': '@alice', 'metadata': md()}),
            returnsNormally,
            reason: 'no raw TypeError escapes for value $bad');
        expect(jsonVerdict({'atKey': 'k', 'value': bad, 'sharedBy': '@alice', 'metadata': md()}),
            'REFUSED');
      }
    });

    test('a metadata map missing the non-nullable bools is a bad request', () {
      // Metadata.fromJson assigns isBinary/isEncrypted/isPublic into
      // non-nullable bools, so `"metadata":{}` raises a TypeError two
      // packages away, which must still surface as a bad request.
      expect(
          () => jsonVerdict({
                'atKey': 'k',
                'value': 'v',
                'sharedBy': '@alice',
                'metadata': <String, dynamic>{}
              }),
          returnsNormally,
          reason: 'the failure is well-typed, whatever the verdict');
    });

    test('a non-UTC asserted timestamp is refused', () {
      // The grammar pins :cAt/:uAt/:eAt/:aAt to ISO-8601 with a trailing Z.
      // These are ordered against the commit log and compared with other
      // atSigns', so a local time silently shifts by the server's offset.
      expect(
          jsonVerdict({
            'atKey': 'k',
            'value': 'v',
            'sharedBy': '@alice',
            'metadata': {
              'isBinary': false,
              'isEncrypted': false,
              'isPublic': false,
              'createdAt': '2020-01-01T00:00:00'
            }
          }),
          'REFUSED');
      // Control: the same instant with the Z the grammar demands.
      expect(
          jsonVerdict({
            'atKey': 'k',
            'value': 'v',
            'sharedBy': '@alice',
            'metadata': {
              'isBinary': false,
              'isEncrypted': false,
              'isPublic': false,
              'createdAt': '2020-01-01T00:00:00Z'
            }
          }),
          'ACCEPTED');
    });

    test('public and sharedWith together are refused', () {
      // The grammar makes them alternatives of one group, so a plain command
      // cannot say both.
      expect(
          jsonVerdict({
            'atKey': 'k',
            'value': 'v',
            'sharedBy': '@alice',
            'sharedWith': '@bob',
            'metadata': {
              'isBinary': false,
              'isEncrypted': false,
              'isPublic': true
            }
          }),
          'REFUSED');
    });

    test('sharedBy and sharedWith are normalised the way the plain path does',
        () {
      // fixAtSign lowercases and prepends the '@', which is what lets the
      // sharedBy-is-me check compare the right string.
      final params = handler.getUpdateParams(HashMap<String, String?>.from(
          getVerbParam(
              VerbSyntax.update,
              'update:json:${jsonEncode({
                    'atKey': 'k',
                    'value': 'v',
                    'sharedBy': 'ALICE',
                    'sharedWith': 'BOB',
                    'metadata': md()
                  })}')));
      expect(params.sharedBy, '@alice',
          reason: 'and it is what lets the sharedBy-is-me check see a match');
      expect(params.sharedWith, '@bob');
    });
  });
}
