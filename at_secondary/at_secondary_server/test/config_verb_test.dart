import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/config_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:at_commons/at_commons.dart';

void main() {
  group('a group of config verb regex test', () {
    test('test config add operation', () {
      var verb = Config();
      var command = 'config:block:add:@alice @bob';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_SIGN], '@alice @bob');
      expect(paramsMap[AT_OPERATION], 'add');
    });

    test('test config remove operation', () {
      var verb = Config();
      var command = 'config:block:remove:@alice';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_SIGN], '@alice');
      expect(paramsMap[AT_OPERATION], 'remove');
    });

    test('test config show operation', () {
      var verb = Config();
      var command = 'config:block:show';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_SIGN], isNull);
      expect(paramsMap[AT_OPERATION], 'show');
    });

    test('test config with wrong show syntax', () {
      var verb = Config();
      var command = 'config:show:block';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test config with wrong add syntax', () {
      var verb = Config();
      var command = 'config:block:add';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('config verb with upper case', () {
      var verb = Config();
      var command = 'CONFIG:block:add:@alice @bob';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_SIGN], '@alice @bob');
      expect(paramsMap[AT_OPERATION], 'add');
    });
  });

  test('config verb with emoji', () {
    var verb = Config();
    var command = 'config:block:add:@🦄 @🐫🐫';
    var regex = verb.syntax();
    var paramsMap = getVerbParam(regex, command);
    expect(paramsMap[AT_SIGN], '@🦄 @🐫🐫');
    expect(paramsMap[AT_OPERATION], 'add');
  });

  test('config verb with emoji with invalid syntax', () {
    var verb = Config();
    var command = 'config:block:@🦄 @🐫🐫';
    var regex = verb.syntax();
    expect(
        () => getVerbParam(regex, command),
        throwsA(predicate((e) =>
            e is InvalidSyntaxException && e.message == 'Syntax Exception')));
  });

  test('config verb with emoji and no @', () {
    var verb = Config();
    var command = 'config:block:add:🦄 🐫🐫';
    var regex = verb.syntax();
    expect(
        () => getVerbParam(regex, command),
        throwsA(predicate((e) =>
            e is InvalidSyntaxException && e.message == 'Syntax Exception')));
  });

  group('A group of config verb handler test', () {
    test('test config verb handler - add config', () {
      var command = 'config:block:add:@alice @bob';
      AbstractVerbHandler verbHandler = ConfigVerbHandler(null);
      var verbParameters = verbHandler.parse(command);
      var verb = verbHandler.getVerb();
      expect(verb is Config, true);
      expect(verbParameters, isNotNull);
      expect(verbParameters[AT_SIGN], '@alice @bob');
      expect(verbParameters[AT_OPERATION], 'add');
    });

    test('test config verb handler - remove config', () {
      var command = 'config:block:remove:@alice @bob';
      AbstractVerbHandler verbHandler = ConfigVerbHandler(null);
      var verbParameters = verbHandler.parse(command);
      var verb = verbHandler.getVerb();
      expect(verb is Config, true);
      expect(verbParameters, isNotNull);
      expect(verbParameters[AT_SIGN], '@alice @bob');
      expect(verbParameters[AT_OPERATION], 'remove');
    });

    test('test config verb handler - show config', () {
      var command = 'config:block:show';
      AbstractVerbHandler verbHandler = ConfigVerbHandler(null);
      var verbParameters = verbHandler.parse(command);
      var verb = verbHandler.getVerb();
      expect(verb is Config, true);
      expect(verbParameters, isNotNull);
      expect(verbParameters[AT_SIGN], isNull);
      expect(verbParameters[AT_OPERATION], 'show');
    });

    test('test config key- invalid add command', () {
      var command = 'config:block:add';
      AbstractVerbHandler handler = ConfigVerbHandler(null);
      expect(
          () => handler.parse(command), throwsA(isA<InvalidSyntaxException>()));
    });

    test('test config key- invalid remove command', () {
      var command = 'config:block:remove:';
      AbstractVerbHandler handler = ConfigVerbHandler(null);
      expect(
          () => handler.parse(command), throwsA(isA<InvalidSyntaxException>()));
    });

    test('test config key- invalid show command', () {
      var command = 'config:block:show:@alice';
      AbstractVerbHandler handler = ConfigVerbHandler(null);
      expect(
          () => handler.parse(command), throwsA(isA<InvalidSyntaxException>()));
    });
  });
}
