import 'dart:async';
import 'dart:collection';

import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_utils/at_logger.dart';

import 'at_server_telemetry_batch.dart';

// Closed batches waiting to be sent, held in memory only, so whatever is
// still here when the server stops is lost. Over its size limit the oldest
// batches go first, with a warning naming them.
final class AtServerTelemetryBuffer {
  static const int defaultMaxBytes = 8 * 1024 * 1024;

  final AtSignLogger _logger = AtSignLogger('AtServerTelemetryBuffer');
  final String bootId;
  final int maxBytes;
  final Queue<AtServerTelemetryBatch> _batches =
      Queue<AtServerTelemetryBatch>();
  int _nextNumber = 0;
  int _bytes = 0;

  AtServerTelemetryBuffer({
    required this.bootId,
    this.maxBytes = defaultMaxBytes,
  }) {
    if (maxBytes < 1) {
      throw RangeError.value(maxBytes, 'maxBytes');
    }
  }

  int get batchCount => _batches.length;

  int get bytes => _bytes;

  AtServerTelemetryBatch? get oldest =>
      _batches.isEmpty ? null : _batches.first;

  // Takes the next sequence number for this boot
  AtServerTelemetryBatch add(
    List<int> body,
    List<Completer<bool>> deliveries,
  ) {
    final AtServerTelemetryBatch batch = AtServerTelemetryBatch(
      sequence: AtTelemetrySequence(bootId: bootId, number: _nextNumber++),
      body: body,
      deliveries: deliveries,
    );
    _batches.addLast(batch);
    _bytes += batch.sizeInBytes;
    _enforceLimit();
    return batch;
  }

  void remove(AtServerTelemetryBatch batch) {
    if (_batches.remove(batch)) {
      _bytes -= batch.sizeInBytes;
    }
  }

  // Drops every batch, reporting each record as not delivered
  void abandonAll() {
    if (_batches.isEmpty) {
      return;
    }
    _logger.warning('Abandoning ${_batches.length} unsent telemetry batches');
    for (final AtServerTelemetryBatch batch in _batches) {
      batch.complete(false);
    }
    _batches.clear();
    _bytes = 0;
  }

  void _enforceLimit() {
    final List<AtServerTelemetryBatch> dropped = <AtServerTelemetryBatch>[];
    while (_batches.isNotEmpty && _bytes > maxBytes) {
      final AtServerTelemetryBatch batch = _batches.removeFirst();
      _bytes -= batch.sizeInBytes;
      batch.complete(false);
      dropped.add(batch);
    }
    if (dropped.isEmpty) {
      return;
    }
    _logger.warning('Telemetry buffer is over $maxBytes bytes; dropped '
        '${dropped.length} batches: '
        '${dropped.map((AtServerTelemetryBatch batch) => batch.sequence).join(', ')}');
  }
}
