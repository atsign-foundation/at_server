import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

import 'abstract_verb_handler.dart';

class InfoVerbHandler extends AbstractVerbHandler {
  static Info infoVerb = Info();
  static int? approximateStartTimeMillis;

  InfoVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore) {
    approximateStartTimeMillis ??= DateTime.now().millisecondsSinceEpoch;
  }

  @override
  bool accept(String command) => command == 'info';

  @override
  Verb getVerb() => infoVerb;

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    Map infoMap =
        {}; // structure of what is returned is documented in the [Info] verb in at_server_spec

    infoMap['version'] = AtSecondaryConfig.secondaryServerVersion;
    Duration uptime = Duration(
        milliseconds: DateTime.now().millisecondsSinceEpoch -
            approximateStartTimeMillis!);
    int uDays = uptime.inDays;
    int uHours = uptime.inHours.remainder(24);
    int uMins = uptime.inMinutes.remainder(60);
    int uSeconds = uptime.inSeconds.remainder(60);
    infoMap['uptime'] = (uDays > 0 ? "$uDays days " : "") +
        ((uDays > 0 || uHours > 0) ? "$uHours hours " : "") +
        ((uDays > 0 || uHours > 0 || uMins > 0) ? "$uMins minutes " : "") +
        "$uSeconds seconds";
    infoMap['features'] = {
      'No-Op verb': {
        'status': 'Beta',
        'description':
            '''NoOp simply does nothing for the requested number of milliseconds.
               The requested number of milliseconds may not be greater than 5000.
               Upon completion, the noop verb sends 'ok' as a response to the client.'''
      },
      notifyWithId: {
        'status': 'Beta',
        'description': 'Notify with notification Id'
      }
    };
    response.data = json.encode(infoMap);
  }
}
