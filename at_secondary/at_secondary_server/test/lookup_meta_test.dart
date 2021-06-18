import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_commons/at_commons.dart';

void main() {
  group('A group of lookup meta verb tests', () {
    test('test lookup meta', () {
      var verb = Lookup();
      var command = 'lookup:meta:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
      expect(paramsMap[OPERATION], 'meta');
    });

    test('test lookup all', () {
      var verb = Lookup();
      var command = 'lookup:all:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
      expect(paramsMap[OPERATION], 'all');
    });

    test('test lookup data', () {
      var verb = Lookup();
      var command = 'lookup:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
      expect(paramsMap[OPERATION], null);
    });

    test('test lookup meta command accept test without operation', () {
      var command = 'lookup:location@alice';
      var handler = LookupVerbHandler(null);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test lookup meta command accept test for meta', () {
      var command = 'lookup:meta:location@alice';
      var handler = LookupVerbHandler(null);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test lookup meta command accept test for all', () {
      var command = 'lookup:all:location@alice';
      var handler = LookupVerbHandler(null);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test lookup key- no atSign', () {
      var verb = Lookup();
      var command = 'lookup:meta:location';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test lookup with out atSign', () {
      var verb = Lookup();
      var command = 'lookup:meta:location@';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test lookup with out atSign for al', () {
      var verb = Lookup();
      var command = 'lookup:all:email@';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test lookup with emoji-invalid syntax', () {
      var verb = Lookup();
      var command = 'lookup:meta:email🐼';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test lookup key- invalid keyword', () {
      var verb = Lookup();
      var command = 'lokup:location@alice';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });
}
