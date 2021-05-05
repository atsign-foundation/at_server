import 'package:at_secondary/src/verb/handler/search_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';

void main() {
  group('A group of search verb tests', () {
    test('test search getVerb', () {
      var handler = SearchVerbHandler(null);
      var verb = handler.getVerb();
      expect(true, verb is Search);
    });

    group('A group of search key-value tests', () {
      test('test fuzzy search key-value', () {
        var handler = SearchVerbHandler(null);
        var command = 'search:fuzzy:2:something';
        var paramsMap = handler.parse(command);
        expect('2', paramsMap['fuzzy']);
        expect('something', paramsMap['keywords']);
      });

      test('test contains search key-value', () {
        var handler = SearchVerbHandler(null);
        var command = 'search:contains:jagan';
        var paramsMap = handler.parse(command);
        expect(true, paramsMap.containsKey('contains'));
        expect('jagan', paramsMap['keywords']);
      });

      test('test normal search key-value', () {
        var handler = SearchVerbHandler(null);
        var command = 'search:jagannadh karthik';
        var paramsMap = handler.parse(command);
        expect('jagannadh karthik', paramsMap['keywords']);
        expect(false, paramsMap.containsKey('contains'));
        expect(null, paramsMap['fuzzy']);
      });
    });

    group('A group of acceptance tests for search verb', () {
      test('test fuzzy search acceptance', () {
        var handler = SearchVerbHandler(null);
        var command = 'search:fuzzy:2:karthik';
        expect(true, handler.accept(command));
      });

      test('test contains search acceptance', () {
        var handler = SearchVerbHandler(null);
        var command = 'search:contains:kart';
        expect(true, handler.accept(command));
      });

      test('test normal search acceptance', () {
        var handler = SearchVerbHandler(null);
        var command = 'search:karthik';
        expect(true, handler.accept(command));
      });
    });
  });
}