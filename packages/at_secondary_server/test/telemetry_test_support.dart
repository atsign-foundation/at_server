import 'dart:async';

import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_telemetry/at_telemetry.dart';

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
void enableRecording(AtServerTelemetry telemetry, RecordingExporter exporter) {
  telemetry.enable(exporter: exporter, serverId: '@alice', bootId: 'boot');
  exporter.records.clear();
}

/// The names of the events in [records] whose names start with [prefix].
List<String?> eventNames(Iterable<AtTelemetryLogRecord> records,
        {String prefix = ''}) =>
    <String?>[
      for (final AtTelemetryLogRecord record in records)
        if (record.eventName?.startsWith(prefix) ?? false) record.eventName,
    ];
