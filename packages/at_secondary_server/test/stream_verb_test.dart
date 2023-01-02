import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:at_secondary/src/utils/handler_util.dart';

void main() async {
  group('A group of stream verb regex test', () {
    test('test steam init syntax', () {
      var verb = StreamVerb();
      var command = 'stream:init@naresh a1 10';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      print(paramsMap);
    });
  });
  //#TODO add more tests
}
