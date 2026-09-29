import 'package:at_telemetry/at_telemetry.dart';

final class RecordingGaugeExporter
    implements AtTelemetryExporter, AtTelemetryGaugeExporter {
  final List<AtTelemetryGauge> gauges = <AtTelemetryGauge>[];
  final List<AtTelemetryEvent> events = <AtTelemetryEvent>[];

  @override
  Future<void> exportGauges(Iterable<AtTelemetryGauge> values) async {
    gauges.addAll(values);
  }

  @override
  Future<void> export(AtTelemetryEvent event) async {
    events.add(event);
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}
}
