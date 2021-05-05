import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/handler/pol_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';

void main() {
  test('test pol Verb', () {
    var handler = PolVerbHandler(null);
    var verb = handler.getVerb();
    expect(verb is Pol, true);
  });

  test('test pol command accept test', () {
    var command = 'pol';
    var handler = PolVerbHandler(null);
    var result = handler.accept(command);
    print('result : $result');
    expect(result, true);
  });

  test('test pol verb - upper case with spaces', () {
    var verb = Pol();
    var command = 'PO L';
    command = SecondaryUtil.convertCommand(command);
    var regex = verb.syntax();
    expect(
        () => getVerbParam(regex, command),
        throwsA(predicate((e) =>
            e is InvalidSyntaxException && e.message == 'Syntax Exception')));
  });

  test('test pol verb - invalid syntax', () {
    var command = 'poll';
    var inbound = InboundConnectionImpl(null, null);
    var defaultVerbExecutor = DefaultVerbExecutor();
    var defaultVerbHandlerManager = DefaultVerbHandlerManager();
    defaultVerbHandlerManager.init();

    expect(
        () => defaultVerbExecutor.execute(
            command, inbound, defaultVerbHandlerManager),
        throwsA(predicate((e) =>
            e is InvalidSyntaxException && e.message == 'invalid command')));
  });
}
