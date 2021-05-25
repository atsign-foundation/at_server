import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/src/keystore/secondary_keystore.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/src/connection/inbound_connection.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class SearchVerbHandler extends AbstractVerbHandler {
  static Search search = Search();

  SearchVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) {
    return command.startsWith('search:');
  }

  @override
  Verb getVerb() {
    return search;
  }

  @override
  HashMap<String, String> parse(String command) {
    var verbParams = super.parse(command);
    if (command.startsWith('search:contains:')) {
      verbParams.putIfAbsent('contains', () => null);
    }
    return verbParams;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {

    var keywords = verbParams['keywords'].split(RegExp('[ ,]'));
    if (verbParams.containsKey('contains')) {
      response.data = (await (keyStore as IndexableKeyStore)
          .search(keywords, contains: true))
          .toString();
    } else if (verbParams['fuzzy'] != null) {
      response.data = (await (keyStore as IndexableKeyStore)
          .search(keywords, fuzziness: int.parse(verbParams['fuzzy'])))
          .toString();
    } else {
      response.data = (await (keyStore as IndexableKeyStore)
          .search(keywords))
          .toString();
    }
  }
}