import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/index_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';

void main() {
  group('A group of index verb tests', () {
    test('test index getVerb', () {
      var handler = IndexVerbHandler(null);
      var verb = handler.getVerb();
      expect(verb is Index, true);
    });

    test('test index key-value', () {
      var verb = Index();
      var command = 'index:Bob Martin, Microsoft';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect('Bob Martin, Microsoft', paramsMap['json']);
    });

    test('test index command acceptance', () {
      var command = 'index:Bob Martin, Microsoft';
      var handler = IndexVerbHandler(null);
      var result = handler.accept(command);
      expect(true, result);
    });
  });
}