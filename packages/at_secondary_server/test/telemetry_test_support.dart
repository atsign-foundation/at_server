import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops.dart' show MlDsa65PureDartAlgo;
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/telemetry/at_server_heartbeat_scheduler.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// An exporter that keeps every record it is handed and reports each as
/// delivered, or as dropped when [delivers] is false.
final class RecordingExporter implements AtTelemetryLogRecordExporter {
  RecordingExporter({this.delivers = true});

  final bool delivers;

  /// Every record handed to this exporter, in order.
  final List<AtTelemetryLogRecord> records = <AtTelemetryLogRecord>[];

  final List<(String, Completer<AtTelemetryLogRecord>)> _waiting =
      <(String, Completer<AtTelemetryLogRecord>)>[];

  /// Completes with the first record named [name], once one is exported.
  Future<AtTelemetryLogRecord> firstNamed(String name) {
    for (final AtTelemetryLogRecord record in records) {
      if (record.eventName == name) {
        return Future<AtTelemetryLogRecord>.value(record);
      }
    }
    final Completer<AtTelemetryLogRecord> found =
        Completer<AtTelemetryLogRecord>();
    _waiting.add((name, found));
    return found.future;
  }

  @override
  Future<bool> export(
    AtTelemetryLogRecord logRecord,
    AtTelemetryResource resource,
  ) async {
    records.add(logRecord);
    _waiting.removeWhere(((String, Completer<AtTelemetryLogRecord>) w) {
      if (w.$1 != logRecord.eventName) {
        return false;
      }
      w.$2.complete(logRecord);
      return true;
    });
    return delivers;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}
}

/// Turns [telemetry] on with [exporter] and forgets the started event.
void enableRecording(AtServerTelemetry telemetry, RecordingExporter exporter,
    {ConnectedEnrollments? connectedEnrollments}) {
  telemetry.enable(
      exporter: exporter,
      serverId: '@alice',
      bootId: 'boot',
      connectedEnrollments: connectedEnrollments);
  exporter.records.clear();
}

/// Authenticates [connection] with a legacy pkam, as a flat credential.
Future<void> legacyPkam(DummyInboundConnection connection) async {
  final keyPair = await MlDsa65PureDartAlgo().generateKeyPair();
  await keyValueStore.put(AtConstants.atPkamPublicKey,
      AtData()..data = base64Encode(keyPair.publicKey),
      skipCommit: true);
  const String sessionId = 'pkam-session';
  const String challenge = 'a-per-connection-challenge';
  await keyValueStore.put(
      'private:$sessionId$alice', AtData()..data = challenge);
  final signature = await MlDsa65PureDartAlgo().signBytes(
      Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')),
      secretKey: keyPair.secretKey);
  connection.metadata.sessionID = sessionId;
  final Response response = Response();
  await PkamVerbHandler(keyValueStore).processVerb(
      response,
      getVerbParam(VerbSyntax.pkam,
          'pkam:signingAlgo:mldsa65:${base64Encode(signature)}'),
      connection);
  expect(response.data, 'success', reason: 'precondition: legacy pkam');
}

/// Sends an enroll:request on CRAM [connection], approved on the spot, and
/// returns the new enrollment's id.
Future<String> cramEnrollRequest(DummyInboundConnection connection) async {
  final OtpVerbHandler otp = OtpVerbHandler(keyValueStore);
  final String passcode = otp.generateOTP();
  await otp.savePasscode(passcode, ttl: 5000, isSpp: false);
  final Response response = Response();
  await EnrollVerbHandler(keyValueStore, enMgr, notificationManager)
      .processVerb(
          response,
          getVerbParam(
              VerbSyntax.enroll,
              'enroll:request:{"otp":"$passcode","appName":"chat"'
              ',"deviceName":"phone","namespaces":{"wavi":"rw"}'
              ',"apkamPublicKey":"pk-${Uuid().v4()}"'
              ',"encryptedAPKAMSymmetricKey":"sym"}'),
          connection);
  final Map<String, Object?> body =
      jsonDecode(response.data!) as Map<String, Object?>;
  expect(body['status'], 'approved', reason: 'precondition');
  return body['enrollmentId'] as String;
}

/// The names of the events in [records] whose names start with [prefix].
List<String?> eventNames(Iterable<AtTelemetryLogRecord> records,
        {String prefix = ''}) =>
    <String?>[
      for (final AtTelemetryLogRecord record in records)
        if (record.eventName?.startsWith(prefix) ?? false) record.eventName,
    ];
