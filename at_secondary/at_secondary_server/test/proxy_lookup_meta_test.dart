import 'package:at_secondary/src/verb/handler/proxy_lookup_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_commons/at_commons.dart';

void main() {
  group('A group of plookup meta verb tests', () {
    test('test plookup meta', () {
      var verb = ProxyLookup();
      var command = 'plookup:meta:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
      expect(paramsMap[OPERATION], 'meta');
    });

    test('test plookup all', () {
      var verb = ProxyLookup();
      var command = 'plookup:all:public:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'public:email');
      expect(paramsMap[AT_SIGN], 'colin');
      expect(paramsMap[OPERATION], 'all');
    });

    test('test plookup data', () {
      var verb = ProxyLookup();
      var command = 'plookup:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
      expect(paramsMap[OPERATION], null);
    });

    test('test plookup meta command accept test without operation', () {
      var command = 'plookup:location@alice';
      var handler = ProxyLookupVerbHandler(null);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test plookup meta command accept test for meta', () {
      var command = 'plookup:meta:location@alice';
      var handler = ProxyLookupVerbHandler(null);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test plookup meta command accept test for all', () {
      var command = 'plookup:all:location@alice';
      var handler = ProxyLookupVerbHandler(null);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test plookup key- no atSign', () {
      var verb = ProxyLookup();
      var command = 'plookup:meta:location';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test plookup with out atSign', () {
      var verb = ProxyLookup();
      var command = 'plookup:meta:location@';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test plookup with out atSign for al', () {
      var verb = ProxyLookup();
      var command = 'plookup:all:email@';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test plookup with emoji-invalid syntax', () {
      var verb = ProxyLookup();
      var command = 'plookup:meta:email🐼';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test plookup key- invalid keyword', () {
      var verb = ProxyLookup();
      var command = 'lokup:location@alice';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });
}
