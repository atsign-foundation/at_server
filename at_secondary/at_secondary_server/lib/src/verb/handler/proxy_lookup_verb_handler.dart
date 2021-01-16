import 'dart:collection';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_server_spec/at_server_spec.dart';

// Class which will process plookup (proxy lookup) verb
class ProxyLookupVerbHandler extends AbstractVerbHandler {
  static ProxyLookup pLookup = ProxyLookup();

  ProxyLookupVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  // Method to verify whether command is accepted or not
  // Input: command
  @override
  bool accept(String command) =>
      command.startsWith(getName(VerbEnum.plookup) + ':');

  // Method to return Instance of verb belongs to this VerbHandler
  @override
  Verb getVerb() {
    return pLookup;
  }

  // Method to process plookup verb
  // This will process given verb and write response to response object
  // Input: response, verbParams, AtConnection
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {
    var atSign = verbParams[AT_SIGN];
    var key = verbParams[AT_KEY];
    var operation = verbParams[OPERATION];
    // Generate query using key, atSign from verbParams
    var query = '${key}@${atSign}';
    if (operation != null) {
      query = '${operation}:${query}';
    }
    logger.finer('query : $query');
    var outBoundClient =
        OutboundClientManager.getInstance().getClient(atSign, atConnection);
    if (!outBoundClient.isConnectionCreated) {
      logger.finer('creating outbound connection ${atSign}');
      await outBoundClient.connect(handshake: false);
    }
    // call lookup with the query
    var result = await outBoundClient.lookUp(query, handshake: false);
    response.data = result;
    var atAccessLog = await AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign);
    await atAccessLog.insert(atSign, pLookup.name(), lookupKey: key);
    return;
  }
}
