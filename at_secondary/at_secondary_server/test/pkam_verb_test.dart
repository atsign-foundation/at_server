import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:at_utils/at_logger.dart';

void main() {
  var storageDir = Directory.current.path + '/test/hive';
  final AtSignLogger _logger = AtSignLogger('pkam_verb_test.dart');

  group("test group: pkam syntax", () {
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
      print('result : $result');
      expect(result, true);
    });
  });


  group("test group: pkam verb handler", () {
    late final SecondaryKeyStoreManager keyStoreManager;

    setUpAll(() async {
      _logger.info('setUpAll starting');
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var secondaryPersistenceStore =
      SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(
          AtSecondaryServerImpl.getInstance().currentAtSign)!;
      var persistenceManager =
      secondaryPersistenceStore.getHivePersistenceManager()!;
      await persistenceManager.init(storageDir);
      keyStoreManager =
      secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
      _logger.info('setUpAll complete');
    });

    test('test pkam verb handler getVerb', () {
      PkamVerbHandler verbHandler = PkamVerbHandler(keyStoreManager.getKeyStore());
      var verb = verbHandler.getVerb();
      expect(verb is Pkam, true);
    });

    tearDownAll(() async {
      var isExists = await Directory('test/hive').exists();
      if (isExists) {
        Directory('test/hive/').deleteSync(recursive: true);
      }
    });
  });
}
