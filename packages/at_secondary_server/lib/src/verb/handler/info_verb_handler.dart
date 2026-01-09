import 'dart:collection';
import 'dart:convert';
import 'dart:io';

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
  bool accept(String command) =>
      command == 'info' || command.startsWith('info:');

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
            .getEnrollmentById(atConnectionMetadata.enrollmentId!);
      }
    } else {
      String subCommand = verbParams[paramFullCommandAsReceived]!.split(':')[1];
      switch (subCommand) {
        case 'brief':
          infoMap['uptimeAsMillis'] = uptime.inMilliseconds;
          break;
        case 'mtls':
          final File f = File(AtSecondaryConfig.certificateChainLocationMtls);
          if (f.existsSync()) {
            infoMap['mtls_fullchain'] = f.readAsStringSync();
          }
          break;
        case 'mtlsbrief':
          final File cert =
              File(AtSecondaryConfig.certificateChainLocationMtls);
          if (cert.existsSync()) {
            infoMap['mtls_fullchain_last_modified'] =
                cert.lastModifiedSync().toUtc().toIso8601String();
          }
          final File key = File(AtSecondaryConfig.privateKeyLocationMtls);
          if (key.existsSync()) {
            infoMap['mtls_privkey_last_modified'] =
                key.lastModifiedSync().toUtc().toIso8601String();
          }
          break;
        default:
          throw InvalidSyntaxException(
              'Invalid command $paramFullCommandAsReceived');
      }
    }
    response.data = json.encode(infoMap);
  }

  String durationToWords(Duration uptime) {
    int uDays = uptime.inDays;
    int uHours = uptime.inHours.remainder(24);
    int uMins = uptime.inMinutes.remainder(60);
    int uSeconds = uptime.inSeconds.remainder(60);
    String uptimeAsWords = '${uDays > 0 ? '$uDays days ' : ''}'
        '${(uDays > 0 || uHours > 0) ? '$uHours hours ' : ''}'
        '${(uDays > 0 || uHours > 0 || uMins > 0) ? '$uMins minutes ' : ''}'
        '$uSeconds seconds';
    return uptimeAsWords;
  }
}
