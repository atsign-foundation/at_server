import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_commons/at_commons.dart';

void main() {
  group('A group of llookup meta verb tests', () {
    test('test llookup meta', () {
      var verb = LocalLookup();
      var command = 'llookup:meta:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
      expect(paramsMap[OPERATION], 'meta');
    });

    test('test llookup all', () {
      var verb = LocalLookup();
      var command = 'llookup:all:@bob:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
      expect(paramsMap[OPERATION], 'all');
    });

    test('test llookup data', () {
      var verb = LocalLookup();
      var command = 'llookup:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
      expect(paramsMap[OPERATION], null);
    });

    test('test llookup meta command accept test without operation', () {
      var command = 'llookup:location@alice';
      var handler = LocalLookupVerbHandler(null);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test llookup meta command accept test for meta', () {
      var command = 'llookup:meta:location@alice';
      var handler = LocalLookupVerbHandler(null);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test llookup meta command accept test for all', () {
      var command = 'llookup:all:location@alice';
      var handler = LocalLookupVerbHandler(null);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test llookup key- no atSign', () {
      var verb = LocalLookup();
      var command = 'llookup:meta:location';
      var regex = verb.syntax();
      expect(
              () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
          e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test llookup with out atSign', () {
      var verb = LocalLookup();
      var command = 'llookup:meta:location@';
      var regex = verb.syntax();
      expect(
              () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
          e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test llookup with out atSign for al', () {
      var verb = LocalLookup();
      var command = 'llookup:all:email@';
      var regex = verb.syntax();
      expect(
              () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
          e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test llookup with emoji-invalid syntax', () {
      var verb = LocalLookup();
      var command = 'llookup:meta:email🐼';
      var regex = verb.syntax();
      expect(
              () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
          e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test llookup key- invalid keyword', () {
      var verb = LocalLookup();
      var command = 'lokup:location@alice';
      var regex = verb.syntax();
      expect(
              () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
          e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });
}
