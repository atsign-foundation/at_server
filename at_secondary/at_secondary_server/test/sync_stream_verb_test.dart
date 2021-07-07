import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:at_commons/at_commons.dart';

void main() {
  group('A group of sync verb regex test', () {
    test('test sync correct syntax', () {
      var verb = SyncStream();
      var command = 'sync:stream:5';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['from_commit_seq'], '5');
    });

    test('test sync correct syntax with regex', () {
      var verb = SyncStream();
      var command = 'sync:stream:5:.buzz';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['from_commit_seq'], '5');
      expect(paramsMap['regex'], '.buzz');
    });

    test('test sync incorrect no sequence number', () {
      var verb = Sync();
      var command = 'sync:stream:';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test sync incorrect multiple sequence number', () {
      var verb = Sync();
      var command = 'sync:stream:5 6 7';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test sync incorrect sequence number with alphabet', () {
      var verb = Sync();
      var command = 'sync:stream:5a';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });
}
