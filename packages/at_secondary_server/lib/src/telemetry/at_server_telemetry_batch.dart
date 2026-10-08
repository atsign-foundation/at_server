import 'dart:async';

import 'package:at_telemetry/at_telemetry.dart';

/// One closed batch in the in-memory buffer: its OTLP/JSON body, the sequence
/// number it took when it entered the buffer, which it keeps across retries,
/// and the outcome of every record in it.
final class AtServerTelemetryBatch {
  final AtTelemetrySequence sequence;
  final List<int> body;
  final List<Completer<bool>> _deliveries;

  AtServerTelemetryBatch({
    required this.sequence,
    required this.body,
    required List<Completer<bool>> deliveries,
  }) : _deliveries = deliveries;

  int get sizeInBytes => body.length;

  /// Reports [delivered] for every record in the batch. Only the first
  /// outcome counts.
  void complete(bool delivered) {
    for (final Completer<bool> delivery in _deliveries) {
      if (!delivery.isCompleted) {
        delivery.complete(delivered);
      }
    }
  }
}
