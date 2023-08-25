import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';

class MockSecondaryKeyStore extends Mock implements SecondaryKeyStore {}

void main() {
  SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();
  var storageDir = '${Directory.current.path}/test/hive';
  SecondaryKeyStoreManager? keyStoreManager;

  group('pkam tests', () {
    setUpAll(() async => keyStoreManager = await setUpFunc(storageDir));
    test('test for pkam correct syntax', () {
      var verb = Pkam();
      var command = 'pkam:edgvb1234';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['signature'], 'edgvb1234');
    });

    test('test for incorrect syntax', () {
      var verb = Pkam();
      var command = 'pkam@:edgvb1234';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test pkam accept', () {
      var command = 'pkam:abc123';
      var handler = PkamVerbHandler(mockKeyStore);
      expect(handler.accept(command), true);
    });

    test('test pkam accept invalid keyword', () {
      var command = 'pkamer:';
      var handler = PkamVerbHandler(mockKeyStore);
      expect(handler.accept(command), false);
    });

    test('test pkam verb handler getVerb', () {
      var verbHandler = PkamVerbHandler(keyStoreManager!.getKeyStore());
      var verb = verbHandler.getVerb();
      expect(verb is Pkam, true);
    });

    test('test pkam verb - upper case with spaces', () {
      var command = 'PK AM:';
      command = SecondaryUtil.convertCommand(command);
      var handler = PkamVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });
    tearDownAll(() async => await tearDownFunc());
  });

  group('apkam tests', () {
    setUpAll(() async {
      keyStoreManager = await setUpFunc(storageDir);
    });

    // dummy enroll value
    EnrollDataStoreValue enrollData = EnrollDataStoreValue(
        'enrollId', 'unit_test', 'test_device', 'dummy_public_key');
    PkamVerbHandler pkamVerbHandler = PkamVerbHandler(mockKeyStore);

    test('verify apkam behaviour - case: enrollment approved ', () async {
      enrollData.approval = EnrollApproval('approved');
      AtData data = AtData()..data = jsonEncode(enrollData.toJson());
      when(() => mockKeyStore.get(any()))
          .thenAnswer((invocation) async => data);

      var apkamResult =
          await pkamVerbHandler.handleApkamVerification('enrollId', '@alice');
      expect(apkamResult.publicKey, 'dummy_public_key');
    });

    test('verify apkam behaviour - case: enrollment revoked ', () async {
      enrollData.approval = EnrollApproval('revoked');
      AtData data = AtData()..data = jsonEncode(enrollData.toJson());
      when(() => mockKeyStore.get(any()))
          .thenAnswer((invocation) async => data);

      var apkamResult =
          await pkamVerbHandler.handleApkamVerification('enrollId', '@alice');
      expect(apkamResult.response.isError, true);
      expect(apkamResult.response.errorCode, 'AT0027');
      expect(apkamResult.response.errorMessage,
          'enrollment_id: enrollId is not approved | Status: revoked');
    });

    test('verify apkam behaviour - case: enrollment pending ', () async {
      enrollData.approval = EnrollApproval('pending');
      AtData data = AtData()..data = jsonEncode(enrollData.toJson());
      when(() => mockKeyStore.get(any()))
          .thenAnswer((invocation) async => data);

      var apkamResult =
          await pkamVerbHandler.handleApkamVerification('enrollId', '@alice');
      expect(apkamResult.response.isError, true);
      expect(apkamResult.response.errorCode, 'AT0026');
      expect(apkamResult.response.errorMessage,
          'enrollment_id: enrollId is not approved | Status: pending');
    });

    test('verify apkam behaviour - case: enrollment denied ', () async {
      enrollData.approval = EnrollApproval('denied');
      AtData data = AtData()..data = jsonEncode(enrollData.toJson());
      when(() => mockKeyStore.get(any()))
          .thenAnswer((invocation) async => data);

      var apkamResult =
          await pkamVerbHandler.handleApkamVerification('enrollId', '@alice');
      expect(apkamResult.response.isError, true);
      expect(apkamResult.response.errorCode, 'AT0025');
      expect(apkamResult.response.errorMessage,
          'enrollment_id: enrollId is not approved | Status: denied');
    });


    tearDownAll(() async => await tearDownFunc());
  });
}

Future<SecondaryKeyStoreManager?> setUpFunc(storageDir) async {
  AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(
          AtSecondaryServerImpl.getInstance().currentAtSign)!;
  var persistenceManager =
      secondaryPersistenceStore.getHivePersistenceManager()!;
  await persistenceManager.init(storageDir);
  // persistenceManager.scheduleKeyExpireTask(1); //commented this line for coverage test
  var keyStoreManager = secondaryPersistenceStore.getSecondaryKeyStoreManager();
  // keyStoreManager.init();
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  var isExists = await Directory('test/hive').exists();
  if (isExists) {
    Directory('test/hive/').deleteSync(recursive: true);
  }
}
