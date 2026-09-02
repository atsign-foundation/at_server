import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_access.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// The access level on an enrollment grant is client-supplied JSON, stored
/// verbatim and then read by every authorisation decision on the atSign.
///
/// It used to be compared exactly — `access == 'rw'` — at ten sites, while
/// one site (the retrofit escalation check) read it as a set of letters. The
/// two disagreed about the same string in the same request, and the
/// disagreement was not symmetric: exact comparison fails CLOSED for the
/// powers a grant confers, and fails OPEN for every question of the form "is
/// this enrollment powerful enough that I need authority over it".
///
/// Both halves are pinned here: the letters are refused at intake so no new
/// record can hold a spelling the server does not act on, and the records
/// already on disk are read as letter sets so every site answers alike.
void main() {
  AtSignLogger.root_level = 'WARNING';

  group('the access-letter predicates', () {
    test('read the letters as a set, not as an exact spelling', () {
      expect(EnrollmentAccess.allowsRead('r'), isTrue);
      expect(EnrollmentAccess.allowsWrite('r'), isFalse);
      expect(EnrollmentAccess.allowsRead('rw'), isTrue);
      expect(EnrollmentAccess.allowsWrite('rw'), isTrue);

      // The spelling that made the ten exact sites disagree with the one
      // letter-set site. Whatever else is decided about it, every reader has
      // to reach the SAME answer, which is the defect being closed.
      expect(EnrollmentAccess.allowsRead('wr'), isTrue,
          reason: 'the escalation check already read wr as {r,w}; the other '
              'sites read it as neither, which is how one request got two '
              'answers');
      expect(EnrollmentAccess.allowsWrite('wr'), isTrue);
    });

    test('an absent or empty grant confers nothing', () {
      // Load-bearing: an empty access level is how a caller reaching a
      // __manage KEY is spelled, and it must not read as a grant.
      expect(EnrollmentAccess.allowsRead(''), isFalse);
      expect(EnrollmentAccess.allowsWrite(''), isFalse);
      expect(EnrollmentAccess.allowsRead(null), isFalse);
      expect(EnrollmentAccess.allowsWrite(null), isFalse);
    });

    test('canonicalise accepts exactly the two wire spellings', () {
      // A RAW-LITERAL pin: these two strings are a wire vocabulary that
      // clients and every atServer implementation spell out, so an intended
      // change edits this assertion.
      expect(EnrollmentAccess.canonicalise('r'), 'r');
      expect(EnrollmentAccess.canonicalise('rw'), 'rw');

      for (final rejected in ['wr', 'RW', 'R', 'rw ', ' rw', 'rwx', 'w', '']) {
        expect(EnrollmentAccess.canonicalise(rejected), isNull,
            reason: '"$rejected" is not a spelling the server acts on, and a '
                'grant is an authorisation decision — guessing what it meant '
                'hands out an authority nobody asked for');
      }
      expect(EnrollmentAccess.canonicalise(null), isNull);
    });
  });

  group('a non-canonical grant is refused at intake', () {
    late EnrollVerbHandler enrollVerbHandler;

    setUpAll(() async => await verbTestsSetUpAll());
    setUp(() async {
      await verbTestsSetUp();
      enrollVerbHandler = EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
    });
    tearDown(() async => await verbTestsTearDown());

    Future<Response> request(Map<String, String> namespaces) async {
      inboundConnection.metaData
        ..isAuthenticated = true
        // A legacy connection: authenticated, carrying no enrollment id, and
        // NOT the self-enrollment path — so a well-formed request on it
        // succeeds and the positive control below means something.
        ..authType = AuthType.pkamLegacy
        ..sessionID = Uuid().v4();
      inboundConnection.metadata.enrollmentId = null;
      final response = Response();
      await enrollVerbHandler.processVerb(
          response,
          getVerbParam(
              VerbSyntax.enroll,
              'enroll:request:${jsonEncode({
                    'appName': 'wavi',
                    'deviceName': 'pixel-${Uuid().v4()}',
                    'namespaces': namespaces,
                    'apkamPublicKey': 'aPublicKeyValue',
                    'encryptedAPKAMSymmetricKey': 'anEncryptedKey',
                  })}'),
          inboundConnection);
      return response;
    }

    test('refuses "wr", naming the namespace and the valid spellings',
        () async {
      await expectLater(
          () => request({'wavi': 'wr'}),
          throwsA(isA<IllegalArgumentException>()),
          reason: 'a spelling the server does not act on must not reach the '
              'store: it produced an enrollment that could do nothing while '
              'still counting as read-only to the checks that ask how '
              'powerful it is');
    });

    test('refuses a valid letter set with stray whitespace', () async {
      await expectLater(() => request({'wavi': 'rw '}),
          throwsA(isA<IllegalArgumentException>()));
    });

    test('accepts the two canonical spellings', () async {
      // Positive control: the refusals above are about the LETTERS, not about
      // the request shape this helper builds.
      expect((await request({'wavi': 'rw'})).isError, isFalse,
          reason: 'rw is a grant the server acts on');
      expect((await request({'buzz': 'r'})).isError, isFalse,
          reason: 'and so is r');
    });
  });

  group('a stored non-canonical grant answers every site alike', () {
    EnrollDataStoreValue valueWith(Map<String, String> namespaces) =>
        EnrollDataStoreValue('session', 'wavi', 'pixel', 'aKey')
          ..namespaces = namespaces;

    test('a root spelled "wr" counts as a root', () {
      // The fail-OPEN half, and the one that can strand an atSign. This feeds
      // isUsableRootEnrollment and the guard that refuses to revoke an
      // atSign's last root: reading it as "not a root" made that guard count
      // zero roots and permit the revoke that leaves nobody able to enroll.
      expect(valueWith({'*': 'wr', '__manage': 'wr'}).isRootEnrollment, isTrue,
          reason: 'the last-root stranding guard has to see this record as '
              'the root its author meant it to be');
    });

    test('a canonical root still counts, and a non-root still does not', () {
      // Controls on both sides, so the assertion above is not simply "any
      // map is a root".
      expect(valueWith({'*': 'rw', '__manage': 'rw'}).isRootEnrollment, isTrue);
      expect(valueWith({'*': 'rw', '__manage': 'r'}).isRootEnrollment, isFalse,
          reason: 'read-only on __manage is not a root: it can admit new '
              'enrollments but can never restore a root');
      expect(valueWith({'*': 'rw'}).isRootEnrollment, isFalse,
          reason: '__manage must be held explicitly');
      expect(valueWith({'wavi': 'rw'}).isRootEnrollment, isFalse);
    });
  });
}
