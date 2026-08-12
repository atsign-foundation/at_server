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
  });
}
