import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/config_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:at_commons/at_commons.dart';

import 'test_utils.dart';

void main() {
  SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();

  group('a group of config verb regex test', () {
    test('test config add operation', () {
      var verb = Config();
      var command = 'config:block:add:@alice @bob';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atSign], '@alice @bob');
      expect(paramsMap[AtConstants.operation], 'add');
    });

    test('test config remove operation', () {
      var verb = Config();
      var command = 'config:block:remove:@alice';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atSign], '@alice');
      expect(paramsMap[AtConstants.operation], 'remove');
    });

    test('test config show operation', () {
      var verb = Config();
      var command = 'config:block:show';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atSign], isNull);
      expect(paramsMap[AtConstants.operation], 'show');
    });

    test('test config with wrong show syntax', () {
      var verb = Config();
      var command = 'config:show:block';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test config with wrong add syntax', () {
      var verb = Config();
      var command = 'config:block:add';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('config verb with upper case', () {
      var verb = Config();
      var command = 'CONFIG:block:add:@alice @bob';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atSign], '@alice @bob');
      expect(paramsMap[AtConstants.operation], 'add');
    });
  });

  test('config verb with emoji', () {
    var verb = Config();
    var command = 'config:block:add:@🦄 @🐫🐫';
    var regex = verb.syntax();
    var paramsMap = getVerbParam(regex, command);
    expect(paramsMap[AtConstants.atSign], '@🦄 @🐫🐫');
    expect(paramsMap[AtConstants.operation], 'add');
  });

  test('config verb with emoji with invalid syntax', () {
    var verb = Config();
    var command = 'config:block:@🦄 @🐫🐫';
    var regex = verb.syntax();
    expect(
        () => getVerbParam(regex, command),
        throwsA(predicate((dynamic e) =>
            e is InvalidSyntaxException && e.message == 'Syntax Exception')));
  });

  test('config verb with emoji and no @', () {
    var verb = Config();
    var command = 'config:block:add:🦄 🐫🐫';
    var regex = verb.syntax();
    expect(
        () => getVerbParam(regex, command),
        throwsA(predicate((dynamic e) =>
            e is InvalidSyntaxException && e.message == 'Syntax Exception')));
  });

  group('A group of config verb handler test', () {
    test('test config verb handler - add config', () {
      var command = 'config:block:add:@alice @bob';
      AbstractVerbHandler verbHandler = ConfigVerbHandler(mockKeyStore);
      var verbParameters = verbHandler.parse(command);
      var verb = verbHandler.getVerb();
      expect(verb is Config, true);
      expect(verbParameters, isNotNull);
      expect(verbParameters[AtConstants.atSign], '@alice @bob');
      expect(verbParameters[AtConstants.operation], 'add');
    });

    test('test config verb handler - remove config', () {
      var command = 'config:block:remove:@alice @bob';
      AbstractVerbHandler verbHandler = ConfigVerbHandler(mockKeyStore);
      var verbParameters = verbHandler.parse(command);
      var verb = verbHandler.getVerb();
      expect(verb is Config, true);
      expect(verbParameters, isNotNull);
      expect(verbParameters[AtConstants.atSign], '@alice @bob');
      expect(verbParameters[AtConstants.operation], 'remove');
    });

    test('test config verb handler - show config', () {
      var command = 'config:block:show';
      AbstractVerbHandler verbHandler = ConfigVerbHandler(mockKeyStore);
      var verbParameters = verbHandler.parse(command);
      var verb = verbHandler.getVerb();
      expect(verb is Config, true);
      expect(verbParameters, isNotNull);
      expect(verbParameters[AtConstants.atSign], isNull);
      expect(verbParameters[AtConstants.operation], 'show');
    });

    test('test config key- invalid add command', () {
      var command = 'config:block:add';
      AbstractVerbHandler handler = ConfigVerbHandler(mockKeyStore);
      expect(
          () => handler.parse(command), throwsA(isA<InvalidSyntaxException>()));
    });

    test('test config key- invalid remove command', () {
      var command = 'config:block:remove:';
      AbstractVerbHandler handler = ConfigVerbHandler(mockKeyStore);
      expect(
          () => handler.parse(command), throwsA(isA<InvalidSyntaxException>()));
    });

    test('test config key- invalid show command', () {
      var command = 'config:block:show:@alice';
      AbstractVerbHandler handler = ConfigVerbHandler(mockKeyStore);
      expect(
          () => handler.parse(command), throwsA(isA<InvalidSyntaxException>()));
    });
  });
}
