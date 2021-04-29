import 'package:at_secondary/src/verb/handler/unindex_verb_handler.dart';
import 'package:at_server_spec/verbs.dart';
import 'package:test/test.dart';

void main() {
  group('A group of unindex verb tests', () {
    test('test undindex getVerb', () {
      var handler = UnIndexVerbHandler(null);
      var verb = handler.getVerb();
      expect(true, verb is UnIndex);
    });

    test('test command acceptance', () {
      var handler = UnIndexVerbHandler(null);
      var command = 'unindex';
      expect(true, handler.accept(command));
    });
  });
}