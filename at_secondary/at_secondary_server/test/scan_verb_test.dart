import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';

void main() {
  group('A group of scan verb tests', () {
    test('test scan getVerb', () {
      var handler = ScanVerbHandler(null);
      var verb = handler.getVerb();
      expect(verb is Scan, true);
    });

    test('test scan command accept test', () {
      var command = 'scan';
      var handler = ScanVerbHandler(null);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test scan key- invalid keyword', () {
      var verb = Scan();
      var command = 'scaan';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test scan verb - upper case', () {
      var command = 'SCAN';
      command = SecondaryUtil.convertCommand(command);
      var handler = ScanVerbHandler(null);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test scan verb - space in between', () {
      var verb = Scan();
      var command = 'sc an';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test scan verb - invalid syntax', () {
      var command = 'scann';
      var inbound = InboundConnectionImpl(null, null);
      var defaultVerbExecutor = DefaultVerbExecutor();
      var defaultVerbHandlerManager = DefaultVerbHandlerManager();
      defaultVerbHandlerManager.init();

      expect(
          () => defaultVerbExecutor.execute(
              command, inbound, defaultVerbHandlerManager),
          throwsA(predicate((e) => e is InvalidSyntaxException)));
    });

    test('test scan verb with forAtSign and regular expression', () {
      var verb = Scan();
      var command = 'scan:@bob ^@kevin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[FOR_AT_SIGN], '@bob');
      expect(paramsMap[AT_REGEX], '^@kevin');
    });

    test('test scan verb with emoji in forAtSign and regular expression', () {
      var verb = Scan();
      var command = 'scan:@🐼 ^@kevin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[FOR_AT_SIGN], '@🐼');
      expect(paramsMap[AT_REGEX], '^@kevin');
    });
  });
}
