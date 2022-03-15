import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'abstract_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class InfoVerbHandler extends AbstractVerbHandler {
  static Info infoVerb = Info();
  static final int approximateStartTimeMillis = DateTime.now().millisecondsSinceEpoch;
  InfoVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  @override
  bool accept(String command) => command == 'info';

  @override
  Verb getVerb() => infoVerb;

  @override
  Future<void> processVerb(Response response, HashMap<String, String?> verbParams, InboundConnection atConnection) async {
    Map infoMap = {}; // structure of what is returned is documented in the [Info] verb in at_server_spec
    /// The "info" verb returns a JSON object as follows:
    /// ```json
    /// {
    ///   "version" : "the version being run",
    ///   "uptime" : "uptime as string: D days, H hours, M minutes, S seconds",
    ///   "features" : [
    ///     {
    ///       "name" : "name of feature 1",
    ///       "status" : "One of Preview, Beta, GA",
    ///       "description" : "optional description of feature"
    ///     },
    ///     {
    ///       "name" : "name of feature 2",
    ///       "status" : "One of Preview, Beta, GA",
    ///       "description" : "optional description of feature"
    ///     },
    ///     ...
    ///   ]
    /// }
    /// ```
    ///
    infoMap['version'] = AtSecondaryConfig.secondaryServerVersion;
    Duration uptime = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - approximateStartTimeMillis);
    infoMap['uptime'] = "${uptime.inDays}"
        " ${uptime.inHours.remainder(24)}"
        " ${uptime.inMinutes.remainder(60)}"
        " ${uptime.inSeconds.remainder(60)}";
    infoMap['features'] = [
      {
        "name": "No-Op verb",
        "status": "Beta",
        "description": "NoOp simply does nothing for the requested number of milliseconds. "
            "The requested number of milliseconds may not be greater than 5000. "
            "Upon completion, the noop verb sends 'ok' as a response to the client."
      }
    ];
    response.data = json.encode(infoMap);
  }
}