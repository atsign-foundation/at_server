import 'package:at_secondary/src/enroll/enrollment_revocation_event.dart';
import 'package:test/test.dart';

/// The at-rest format of a revocation event.
///
/// Pinned as RAW LITERALS rather than round-tripped through the class,
/// because the writer and the reader are the same pair of hand-written
/// methods: a symmetric rename passes every round-trip test there is while
/// every already-stored event becomes unreadable. These records are the only
/// surviving evidence of a revocation once the enrollment is reaped, so
/// losing them silently is the failure this file exists to catch.
///
/// An intended change edits the literal in the same commit, and that edit is
/// the review.
void main() {
  final at = DateTime.utc(2026, 8, 31, 12, 34, 56, 789);

  group('the at-rest shape', () {
    test('a cascaded revocation writes every field under its stored name', () {
      final json = EnrollmentRevocationEvent(
        type: EnrollmentRevocationEventType.revoked,
        enrollmentId: 'aaaa-1111',
        at: at,
        namespaces: {'wavi': 'rw', '__manage': 'r'},
        byEnrollmentId: 'bbbb-2222',
        cascadedFrom: 'cccc-3333',
      ).toJson();

      expect(json, {
        'event': 'revoked',
        'enrollmentId': 'aaaa-1111',
        'at': '2026-08-31T12:34:56.789Z',
        'namespaces': {'wavi': 'rw', '__manage': 'r'},
        'byEnrollmentId': 'bbbb-2222',
        'cascadedFrom': 'cccc-3333',
      });
    });

    test('and an un-revocation is the same shape with the other kind', () {
      expect(
          EnrollmentRevocationEvent(
            type: EnrollmentRevocationEventType.unrevoked,
            enrollmentId: 'aaaa-1111',
            at: at,
            namespaces: {'wavi': 'rw'},
            byEnrollmentId: null,
            cascadedFrom: null,
          ).toJson()['event'],
          'unrevoked',
          reason: 'the two kinds are distinguished by this literal alone, and '
              'a reader that cannot tell them apart nets a revocation the '
              'wrong way');
    });

    test('the optional fields are omitted, not written null', () {
      final json = EnrollmentRevocationEvent(
        type: EnrollmentRevocationEventType.revoked,
        enrollmentId: 'aaaa-1111',
        at: at,
        namespaces: const {},
        byEnrollmentId: null,
        cascadedFrom: null,
      ).toJson();

      expect(json.containsKey('byEnrollmentId'), false,
          reason: 'a CRAM or legacy-PKAM owner carries no enrollment id, and '
              'an absent key says that more plainly than a null');
      expect(json.containsKey('cascadedFrom'), false);
      expect(json.keys.toSet(), {'event', 'enrollmentId', 'at', 'namespaces'});
    });

    test('every field survives the round trip', () {
      final event = EnrollmentRevocationEvent(
        type: EnrollmentRevocationEventType.revoked,
        enrollmentId: 'aaaa-1111',
        at: at,
        namespaces: {'wavi': 'rw'},
        byEnrollmentId: 'bbbb-2222',
        cascadedFrom: 'cccc-3333',
      );
      final back = EnrollmentRevocationEvent.fromJson(event.toJson());

      expect(back.type, event.type);
      expect(back.enrollmentId, event.enrollmentId);
      expect(back.at, event.at);
      expect(back.namespaces, event.namespaces);
      expect(back.byEnrollmentId, event.byEnrollmentId);
      expect(back.cascadedFrom, event.cascadedFrom);
    });

    test('a record written with no namespaces reads back as none, not null',
        () {
      expect(
          EnrollmentRevocationEvent.fromJson({
            'event': 'revoked',
            'enrollmentId': 'aaaa-1111',
            'at': '2026-08-31T12:34:56.789Z',
          }).namespaces,
          isEmpty);
    });
  });

  group('a record it cannot read', () {
    test('an unknown event kind is refused rather than guessed', () {
      // A future kind that neither revokes nor un-revokes would be miscounted
      // by any default, and miscounting here moves a security answer. The
      // reader logs and skips what this throws.
      expect(
          () => EnrollmentRevocationEvent.fromJson({
                'event': 'suspended',
                'enrollmentId': 'aaaa-1111',
                'at': '2026-08-31T12:34:56.789Z',
              }),
          throwsA(isA<FormatException>()));
    });

    test('and so is one with no enrollment id or no timestamp', () {
      expect(
          () => EnrollmentRevocationEvent.fromJson({
                'event': 'revoked',
                'at': '2026-08-31T12:34:56.789Z',
              }),
          throwsA(isA<FormatException>()));
      expect(
          () => EnrollmentRevocationEvent.fromJson({
                'event': 'revoked',
                'enrollmentId': 'aaaa-1111',
              }),
          throwsA(isA<FormatException>()));
    });

    test('the control: the same record with all three reads fine', () {
      // Without this the three refusals above are satisfied by a decoder that
      // refuses everything.
      expect(
          EnrollmentRevocationEvent.fromJson({
            'event': 'revoked',
            'enrollmentId': 'aaaa-1111',
            'at': '2026-08-31T12:34:56.789Z',
          }).enrollmentId,
          'aaaa-1111');
    });
  });
}
