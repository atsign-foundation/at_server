import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Pins `update:json` and plain `update:` to one verdict, running each shape
/// through both forms. The key's NAME is deliberately excluded: which keys a
/// caller may write is an authorisation question.
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

    /// Whether the PLAIN form of [command] is accepted.
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

    /// A well-formed metadata map with [extra] folded in.
    Map<String, dynamic> md([Map<String, dynamic> extra = const {}]) => {
          'isBinary': false,
          'isEncrypted': false,
          'isPublic': false,
          ...extra,
        };

    /// Each case: a description, the plain command, the json document, and
    /// the verdict BOTH must reach.
    final cases = <(String, String, Map<String, dynamic>, String)>[
      // The controls for the refusals below.
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
        // NOTE the one atKey the update grammar special-cases; the charset
        // rules must not catch it.
        'the literal the grammar special-cases',
        'update:privatekey:at_pkam_publickey KEYVALUE',
        {'atKey': 'privatekey:at_pkam_publickey', 'value': 'KEYVALUE', 'metadata': md()},
        'ACCEPTED',
      ),

      // NOTE the atKey CHARSET is deliberately not among the refusals.
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
