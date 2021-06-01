import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:at_commons/at_commons.dart';

void main() {
  group('A group of monitor verb syntax tests', () {
    test('test monitor without regex or epochMillis', () {
      var verb = Monitor();
      var command = 'monitor';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_REGEX], null);
      expect(paramsMap[EPOCH_MILLIS], null);
    });

    test('test monitor with only regex', () {
      var verb = Monitor();
      var command = 'monitor *.myApp';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_REGEX], '*.myApp');
      expect(paramsMap[EPOCH_MILLIS], null);
    });

    test('test monitor with only epochMillis', () {
      var verb = Monitor();
      var command = 'monitor:123456789';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_REGEX], null);
      expect(paramsMap[EPOCH_MILLIS], '123456789');
    });

    test('test monitor with regex and epochMillis', () {
      var verb = Monitor();
      var command = 'monitor:123456789 *.myApp';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_REGEX], '*.myApp');
      expect(paramsMap[EPOCH_MILLIS], '123456789');
    });
  });
}