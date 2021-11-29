import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';

void main() {
  late final SecondaryKeyStoreManager keyStoreManager;
  var testDataStoragePath = Directory.current.path + '/test/hive/pkam_verb_test';
  // String thisTestFileName = 'pkam_verb_test.dart';

  setUpAll(() async {
    // print(thisTestFileName + ' setUpAll starting');

    AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';

    var secondaryPersistenceStore =
        SecondaryPersistenceStoreFactory.getInstance().getSecondaryPersistenceStore(AtSecondaryServerImpl.getInstance().currentAtSign)!;

    await secondaryPersistenceStore.getHivePersistenceManager()!.init(testDataStoragePath);

    keyStoreManager = secondaryPersistenceStore.getSecondaryKeyStoreManager()!;

    // print(thisTestFileName + ' setUpAll complete');
  });

  tearDownAll(() async {
    // print(thisTestFileName + ' tearDownAll: removing data from ' + testDataStoragePath);
    await Directory(testDataStoragePath).delete(recursive: true);
    // print(thisTestFileName + ' tearDownAll complete');
  });

  group("test group: pkam syntax", () {
    test("test for pkam correct syntax", () {
      var verb = Pkam();
      var command = 'pkam:edgvb1234';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['signature'], 'edgvb1234');
    });

    test("test for incorrect syntax", () {
      var verb = Pkam();
      var command = 'pkam@:edgvb1234';
      var regex = verb.syntax();
      expect(() => getVerbParam(regex, command), throwsA(predicate((dynamic e) => e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test pkam accept', () {
      var command = 'pkam:abc123';
      var handler = PkamVerbHandler(null);
      expect(handler.accept(command), true);
    });

    test('test pkam accept invalid keyword', () {
      var command = 'pkamer:';
      var handler = PkamVerbHandler(null);
      expect(handler.accept(command), false);
    });

    test('test pkam verb - upper case with spaces', () {
      var command = 'PK AM:';
      command = SecondaryUtil.convertCommand(command);
      var handler = PkamVerbHandler(null);
      var result = handler.accept(command);
      // print('result : $result');
      expect(result, true);
    });

    test('test pkam verb handler getVerb', () {
      PkamVerbHandler verbHandler = PkamVerbHandler(keyStoreManager.getKeyStore());
      var verb = verbHandler.getVerb();
      expect(verb is Pkam, true);
    });
  });
}
