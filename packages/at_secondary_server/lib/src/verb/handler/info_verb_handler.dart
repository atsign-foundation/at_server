import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

import 'abstract_verb_handler.dart';

/// Handler for the 'info' verb. Usage of info verb is documented in at_server_spec/lib/src/verb/info.dart
class InfoVerbHandler extends AbstractVerbHandler {
  static Info infoVerb = Info();
  static int? approximateStartTimeMillis;

  InfoVerbHandler(super.keyStore) {
    approximateStartTimeMillis ??= DateTime.now().millisecondsSinceEpoch;
  }

  @override
  bool accept(String command) => command == 'info' || command == 'info:brief';

  @override
  Verb getVerb() => infoVerb;

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    Map infoMap = {};
    InboundConnectionMetadata atConnectionMetadata = atConnection.metaData
        as InboundConnectionMetadata; // structure of what is returned is documented in the [Info] verb in at_server_spec

    infoMap['version'] = AtSecondaryConfig.secondaryServerVersion;
    Duration uptime = Duration(
        milliseconds: DateTime.now().millisecondsSinceEpoch -
            approximateStartTimeMillis!);
    if (verbParams[paramFullCommandAsReceived] == 'info') {
      String uptimeAsWords = durationToWords(uptime);
      infoMap['uptimeAsWords'] = uptimeAsWords;
      if (atConnectionMetadata.isAuthenticated &&
          atConnectionMetadata.enrollmentId != null) {
        infoMap['apkam_metadata'] = await AtSecondaryServerImpl.getInstance()
            .enrollmentManager
            .get(atConnectionMetadata.enrollmentId!);
      }
    } else {
      infoMap['uptimeAsMillis'] = uptime.inMilliseconds;
    }
    response.data = json.encode(infoMap);
  }

  String durationToWords(Duration uptime) {
    int uDays = uptime.inDays;
    int uHours = uptime.inHours.remainder(24);
    int uMins = uptime.inMinutes.remainder(60);
    int uSeconds = uptime.inSeconds.remainder(60);
    // ignore: prefer_interpolation_to_compose_strings
    String uptimeAsWords = (uDays > 0 ? "$uDays days " : "") +
        ((uDays > 0 || uHours > 0) ? "$uHours hours " : "") +
        ((uDays > 0 || uHours > 0 || uMins > 0) ? "$uMins minutes " : "") +
        "$uSeconds seconds";
    return uptimeAsWords;
  }
}
