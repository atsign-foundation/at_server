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
      // The record is what survives a restart, so a shape that does not
      // round-trip is a signing key the enrollment silently stops publishing
      // the next time the server comes up. Asserted on the RAW wire names
      // because the serialisation is hand-maintained here — there is no
      // json_serializable dev dependency to regenerate it, so a typo in
      // enroll_datastore_value.g.dart has nothing else to catch it.
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
      // The stamp that makes "the cap arms once" decidable across a restart.
      // Its writer and reader are the same hand-maintained pair in the .g.dart,
      // so a symmetric rename passes every test that reads it through the
      // typed getter while every already-stored record silently loses its
      // stamp — and re-arms once more, extending its predecessor by a whole
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

    test('approvedByEnrollmentId round-trips under its at-rest name', () {
      // The edge revocation cascades along. Its writer and reader are the same
      // hand-maintained pair in the .g.dart, so a symmetric rename passes
      // every test reading it through the typed getter while every stored
      // record silently loses its approver — and drops out of the cascade,
      // which is exactly the failure the field exists to prevent.
      final v = EnrollDataStoreValue('123', 'testclient', 'iphone', 'mykey')
        ..approvedByEnrollmentId = 'approver-abc';

      expect(v.toJson()['approvedByEnrollmentId'], 'approver-abc',
          reason: 'raw literal: the key name is what a record written by an '
              'earlier server is read back through');
      expect(
          EnrollDataStoreValue.fromJson(v.toJson()).approvedByEnrollmentId,
          'approver-abc');

      final unapproved =
          EnrollDataStoreValue('123', 'testclient', 'iphone', 'mykey');
      expect(unapproved.toJson().containsKey('approvedByEnrollmentId'), false,
          reason: 'omitted rather than written null, so a record from before '
              'this field existed reads back as "nothing here admitted it" '
              'and is simply never cascaded to');
      expect(
          EnrollDataStoreValue.fromJson(unapproved.toJson())
              .approvedByEnrollmentId,
          isNull);
    });

    test('a stored record carrying revokedAt still decodes', () {
      // Records written before the revocation history existed carry a
      // `revokedAt` the class no longer has. `fromJson` reads named keys, so
      // an unknown one is ignored — but that is a property of the
      // hand-maintained decoder rather than of a generator, and the whole
      // reason this file exists is that nothing regenerates it.
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
