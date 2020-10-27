import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/notify_list_verb_handler.dart';
import 'package:test/test.dart';
import 'package:at_server_spec/at_verb_spec.dart';

void main() {
  group('A group of notify list verb tests', () {
    test('test notify getVerb', () {
      var handler = NotifyListVerbHandler(null);
      var verb = handler.getVerb();
      expect(verb is NotifyList, true);
    });

    test('test notify command accept test', () {
      var command = 'notify:list .me';
      var handler = NotifyListVerbHandler(null);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test notify list with params', () {
      var verb = NotifyList();
      var command = 'notify:list .me';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect('.me', paramsMap['regex']);
    });

    test('test notify list with regex', () {
      var verb = NotifyList();
      var command = 'notify:list ^phone';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect('^phone', paramsMap['regex']);
    });
  });

  group('A group of notify list negative test', () {
    test('test notify key- invalid keyword', () {
      var verb = NotifyList();
      var command = 'notif:list';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });
}
