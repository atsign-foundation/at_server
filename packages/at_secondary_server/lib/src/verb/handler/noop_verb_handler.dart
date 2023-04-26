import 'dart:collection';
import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'abstract_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class NoOpVerbHandler extends AbstractVerbHandler {
  static NoOp noOpVerb = NoOp();
  NoOpVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) => command.startsWith('noop:');

  @override
  Verb getVerb() => noOpVerb;

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    String? delayMillisParam = verbParams[
        'delayMillis']; // as per NoOp documentation, delayMillis may not be more than 5000
    if (delayMillisParam == null) {
      throw IllegalArgumentException(
          "${noOpVerb.usage()} where the duration maximum is 5000 milliseconds");
    }
    var delayMillis = int.parse(delayMillisParam);
    if (delayMillis > 5000) {
      throw IllegalArgumentException(
          "${noOpVerb.usage()} where the duration maximum is 5000 milliseconds");
    }
    await Future.delayed(Duration(milliseconds: delayMillis));
    response.data = 'ok';
  }
}
