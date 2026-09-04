import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:test/test.dart';

void main() {
  group(
      'a group of tests to verify enroll data store value - toJson and fromJson',
      () {
    test('enroll approval object fromJson', () {
      final enrollApprovalJson = {'state': 'requested'};
      final enrollApprovalObject = EnrollApproval.fromJson(enrollApprovalJson);
      expect(enrollApprovalObject, isA<EnrollApproval>());
      expect(enrollApprovalObject.state, 'requested');
    });
    test('enroll approval object toJson', () {
      final enrollApproval = EnrollApproval('requested');
      final enrollApprovalJson = enrollApproval.toJson();
      expect(enrollApprovalJson['state'], 'requested');
    });

    test('enroll data store value object toJson', () {
      var namespaceMap = {'wavi': 'rw', 'buzz': 'r'};
      final enrollApproval = EnrollApproval('requested');
      final enrollDataStoreValue =
          EnrollDataStoreValue('123', 'testclient', 'iphone', 'mykey')
            ..namespaces = namespaceMap
            ..approval = enrollApproval
            ..requestType = EnrollRequestType.newEnrollment;
      final enrollJson = enrollDataStoreValue.toJson();
      expect(enrollJson['sessionId'], '123');
      expect(enrollJson['appName'], 'testclient');
      expect(enrollJson['deviceName'], 'iphone');
      expect(enrollJson['apkamPublicKey'], 'mykey');
      expect(enrollJson['requestType'], 'newEnrollment');
      expect(enrollJson['namespaces']['wavi'], 'rw');
      expect(enrollJson['namespaces']['buzz'], 'r');
      expect(enrollJson['approval'], enrollApproval);
    });
    test('enroll data store value object fromJson', () {
      final enrollJson = {
        'sessionId': '123',
        'appName': 'testclient',
        'deviceName': 'iphone',
        'namespaces': {'wavi': 'rw', 'buzz': 'r'},
        'apkamPublicKey': 'mykey',
        'requestType': 'newEnrollment',
        'approval': {'state': 'requested'}
      };
      final enrollValueObject = EnrollDataStoreValue.fromJson(enrollJson);
      expect(enrollValueObject, isA<EnrollDataStoreValue>());
      expect(enrollValueObject.approval, isA<EnrollApproval>());
      expect(enrollValueObject.namespaces, isA<Map<String, String>>());
      expect(enrollValueObject.sessionId, '123');
      expect(enrollValueObject.appName, 'testclient');
      expect(enrollValueObject.deviceName, 'iphone');
      expect(enrollValueObject.apkamPublicKey, 'mykey');
      expect(enrollValueObject.requestType, EnrollRequestType.newEnrollment);
    });

    test('the two _apsk shapes survive a round trip under their own names', () {
      // ⚠️ AT-REST PIN, on the raw field names. The serialisation is
      // hand-maintained (nothing regenerates the .g.dart), and a shape that
      // does not round-trip is a signing key the enrollment silently stops
      // publishing after a restart.
      final array = {
        'v': 1,
        'keys': [
          {'kid': 'k', 'use': 'sign', 'alg': 'mldsa65', 'pub': 'bWxkc2E='}
        ]
      };
      final withArray =
          EnrollDataStoreValue('123', 'testclient', 'iphone', 'mykey')
            ..apsk = array;
      expect(withArray.toJson()['apsk'], array);
      expect(withArray.toJson().containsKey('apskLegacy'), false,
          reason: 'an absent shape is omitted, not written as null');
      expect(EnrollDataStoreValue.fromJson(withArray.toJson()).apsk, array);

      const bare = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A';
      final withBare =
          EnrollDataStoreValue('123', 'testclient', 'iphone', 'mykey')
            ..apskLegacy = bare;
      expect(withBare.toJson()['apskLegacy'], bare);
      expect(withBare.toJson().containsKey('apsk'), false);
      expect(EnrollDataStoreValue.fromJson(withBare.toJson()).apskLegacy, bare);
    });

    test('predecessorCapArmedAt round-trips under its at-rest name', () {
      // ⚠️ AT-REST PIN. The stamp makes "the cap arms once" decidable across
      // a restart, and its writer and reader are the same hand-maintained
      // pair, so a symmetric rename stays green while every stored record
      // loses its stamp and re-arms, extending its predecessor by a whole
      // grace period.
      final armedAt = DateTime.utc(2026, 8, 31, 12, 34, 56, 789);
      final v = EnrollDataStoreValue('123', 'testclient', 'iphone', 'mykey')
        ..predecessorCapArmedAt = armedAt;

      expect(v.toJson()['predecessorCapArmedAt'], '2026-08-31T12:34:56.789Z',
          reason: 'raw literal: the key name and the ISO-8601 encoding are '
              'what a record written by an earlier server is read back '
              'through');
      expect(EnrollDataStoreValue.fromJson(v.toJson()).predecessorCapArmedAt,
          armedAt);

      final unarmed =
          EnrollDataStoreValue('123', 'testclient', 'iphone', 'mykey');
      expect(unarmed.toJson().containsKey('predecessorCapArmedAt'), false,
          reason: 'omitted rather than written null, so a record from before '
              'this field existed reads back as "never armed"');
      expect(
          EnrollDataStoreValue.fromJson(unarmed.toJson())
              .predecessorCapArmedAt,
          isNull);
    });

    test('parentEnrollmentId round-trips under its at-rest name', () {
      // ⚠️ AT-REST PIN. This is the edge revocation cascades along, and a
      // symmetric rename of the hand-maintained writer and reader stays green
      // while every stored record loses its approver and drops out of the
      // cascade.
      final v = EnrollDataStoreValue('123', 'testclient', 'iphone', 'mykey')
        ..parentEnrollmentId = 'approver-abc';

      expect(v.toJson()['parentEnrollmentId'], 'approver-abc',
          reason: 'raw literal: the key name is what a record written by an '
              'earlier server is read back through');
      expect(
          EnrollDataStoreValue.fromJson(v.toJson()).parentEnrollmentId,
          'approver-abc');

      final unapproved =
          EnrollDataStoreValue('123', 'testclient', 'iphone', 'mykey');
      expect(unapproved.toJson().containsKey('parentEnrollmentId'), false,
          reason: 'omitted rather than written null, so a record from before '
              'this field existed reads back as "nothing here admitted it" '
              'and is simply never cascaded to');
      expect(
          EnrollDataStoreValue.fromJson(unapproved.toJson())
              .parentEnrollmentId,
          isNull);
    });

    test('retrofitPredecessorEnrollmentId round-trips under its at-rest name',
        () {
      // ⚠️ AT-REST PIN. The once-off rule reads this to refuse a second
      // retrofit and the cap reads it to know whose expiry to cap, so a
      // symmetric rename would let every stored successor be retrofitted
      // again and cap nothing.
      final v = EnrollDataStoreValue('123', 'testclient', 'iphone', 'mykey')
        ..retrofitPredecessorEnrollmentId = 'predecessor-abc';

      expect(v.toJson()['retrofitPredecessorEnrollmentId'], 'predecessor-abc',
          reason: 'raw literal: the key name is what a record written by an '
              'earlier server is read back through');
      expect(
          EnrollDataStoreValue.fromJson(v.toJson())
              .retrofitPredecessorEnrollmentId,
          'predecessor-abc');

      final minted =
          EnrollDataStoreValue('123', 'testclient', 'iphone', 'mykey');
      expect(minted.toJson().containsKey('retrofitPredecessorEnrollmentId'),
          false,
          reason: 'omitted rather than written null: an enrollment that '
              'replaced nothing reads back as one that may still retrofit');
      expect(
          EnrollDataStoreValue.fromJson(minted.toJson())
              .retrofitPredecessorEnrollmentId,
          isNull);
    });

    test('a stored record carrying revokedAt still decodes', () {
      // ⚠️ AT-REST PIN on a field the class does not carry: stored records
      // hold `revokedAt`, and the hand-maintained decoder must go on ignoring
      // an unknown key rather than failing on one.
      final stored = <String, dynamic>{
        'sessionId': '123',
        'appName': 'testclient',
        'deviceName': 'iphone',
        'apkamPublicKey': 'mykey',
        'namespaces': {'wavi': 'rw'},
        'apkamKeysExpiryInMillis': 0,
        'revokedAt': '2026-08-31T12:34:56.789Z',
      };

      final v = EnrollDataStoreValue.fromJson(stored);
      expect(v.namespaces, {'wavi': 'rw'});
      expect(v.toJson().containsKey('revokedAt'), false,
          reason: 're-encoding drops it, which is the intended one-way door: '
              'the revocation history is the record of when, and a stale copy '
              'on the enrollment would disagree with it the moment an '
              'un-revoke landed');
    });
  });
}
