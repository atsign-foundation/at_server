import 'package:at_telemetry/at_telemetry.dart';

final class RecordingGaugeExporter
    implements AtTelemetryLogRecordExporter, AtTelemetryMetricExporter {
  final List<AtTelemetryGauge> gauges = <AtTelemetryGauge>[];
  final List<AtTelemetryLogRecord> events = <AtTelemetryLogRecord>[];

  @override
  Future<void> exportMetrics(Iterable<AtTelemetryMetric> values) async {
    gauges.addAll(values.cast<AtTelemetryGauge>());
  }

  @override
  Future<void> export(AtTelemetryLogRecord event) async {
    events.add(event);
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}
}
