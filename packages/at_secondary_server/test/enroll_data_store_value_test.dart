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

    test('enroll namespace object fromJson', () {
      final enrollNamespaceJson = {'name': 'buzz', 'access': 'r'};
      final enrollNamespaceObject =
          EnrollNamespace.fromJson(enrollNamespaceJson);
      expect(enrollNamespaceObject, isA<EnrollNamespace>());
      expect(enrollNamespaceObject.name, 'buzz');
      expect(enrollNamespaceObject.access, 'r');
    });

    test('enroll namespace object toJson', () {
      final enrollNamespace = EnrollNamespace('wavi', 'rw');
      final enrollNamespaceJson = enrollNamespace.toJson();
      expect(enrollNamespaceJson['name'], 'wavi');
      expect(enrollNamespaceJson['access'], 'rw');
    });

    test('enroll data store value object toJson', () {
      final enrollNamespace1 = EnrollNamespace('wavi', 'rw');
      final enrollNamespace2 = EnrollNamespace('buzz', 'r');
      final enrollApproval = EnrollApproval('requested');
      final namespaceList = [enrollNamespace1, enrollNamespace2];
      final enrollDataStoreValue =
          EnrollDataStoreValue('123', 'testclient', 'iphone', 'mykey')
            ..namespaces = namespaceList
            ..approval = enrollApproval
            ..requestType = EnrollRequestType.newEnrollment;
      final enrollJson = enrollDataStoreValue.toJson();
      print(enrollJson);
      expect(enrollJson['sessionId'], '123');
      expect(enrollJson['appName'], 'testclient');
      expect(enrollJson['deviceName'], 'iphone');
      expect(enrollJson['apkamPublicKey'], 'mykey');
      expect(enrollJson['requestType'], 'newEnrollment');
      expect(enrollJson['namespaces'][0], enrollNamespace1);
      expect(enrollJson['namespaces'][1], enrollNamespace2);
      expect(enrollJson['approval'], enrollApproval);
    });
    test('enroll data store value object fromJson', () {
      final enrollJson = {
        'sessionId': '123',
        'appName': 'testclient',
        'deviceName': 'iphone',
        'namespaces': [
          {'name': 'wavi', 'access': 'rw'},
          {'name': 'buzz', 'access': 'r'}
        ],
        'apkamPublicKey': 'mykey',
        'requestType': 'newEnrollment',
        'approval': {'state': 'requested'}
      };
      final enrollValueObject = EnrollDataStoreValue.fromJson(enrollJson);
      expect(enrollValueObject, isA<EnrollDataStoreValue>());
      expect(enrollValueObject.approval, isA<EnrollApproval>());
      expect(enrollValueObject.namespaces, isA<List<EnrollNamespace>>());
      expect(enrollValueObject.sessionId, '123');
      expect(enrollValueObject.appName, 'testclient');
      expect(enrollValueObject.deviceName, 'iphone');
      expect(enrollValueObject.apkamPublicKey, 'mykey');
      expect(enrollValueObject.requestType, EnrollRequestType.newEnrollment);
    });
  });
}
