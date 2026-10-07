import 'dart:convert';
import 'dart:io';

import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_utils/at_logger.dart';

import 'at_server_telemetry_batch.dart';
import 'at_server_telemetry_constants.dart';

// Closed batches waiting to be sent, one file each in a directory of their
// own beside the notification store, outside the atSign's keystore, so
// nothing syncs them and no verb can read them. Over its size or age limit
// the oldest batches go first, with a warning naming them.
final class AtServerTelemetryOutbox {
  static const int defaultMaxBytes = 64 * 1024 * 1024;
  static const Duration defaultMaxAge = Duration(days: 7);
  static final AtSignLogger _logger = AtSignLogger('AtServerTelemetryOutbox');

  final Directory directory;
  final String bootId;
  final int maxBytes;
  final Duration maxAge;
  final DateTime Function() _now;
  final List<AtServerTelemetryBatch> _batches;
  int _nextNumber = 0;
  int _bytes = 0;
  int _dropped = 0;

  AtServerTelemetryOutbox._({
    required this.directory,
    required this.bootId,
    required this.maxBytes,
    required this.maxAge,
    required DateTime Function() now,
    required List<AtServerTelemetryBatch> batches,
  })  : _now = now,
        _batches = batches {
    for (final AtServerTelemetryBatch batch in batches) {
      _bytes += batch.sizeInBytes;
    }
  }

  // Batches left by earlier boots keep their own boot ids and numbers
  static Future<AtServerTelemetryOutbox> open({
    required Directory directory,
    required String bootId,
    int maxBytes = defaultMaxBytes,
    Duration maxAge = defaultMaxAge,
    DateTime Function()? now,
  }) async {
    await directory.create(recursive: true);
    final List<AtServerTelemetryBatch> batches = <AtServerTelemetryBatch>[];
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File) {
        continue;
      }
      final String name = entity.uri.pathSegments.last;
      if (name.endsWith('.tmp')) {
        await _deleteQuietly(entity);
        continue;
      }
      if (!name.endsWith('.json')) {
        continue;
      }
      try {
        batches.add(
          AtServerTelemetryBatch.decode(entity, await entity.readAsString()),
        );
      } on Object catch (error) {
        _logger.warning('Removing unreadable telemetry batch $name: $error');
        await _deleteQuietly(entity);
      }
    }
    batches.sort(_oldestFirst);

    final AtServerTelemetryOutbox outbox = AtServerTelemetryOutbox._(
      directory: directory,
      bootId: bootId,
      maxBytes: maxBytes,
      maxAge: maxAge,
      now: now ?? DateTime.now,
      batches: batches,
    );
    await outbox.enforceLimits();
    return outbox;
  }

  int get batchCount => _batches.length;

  int get bytes => _bytes;

  int get droppedSinceBoot => _dropped;

  AtServerTelemetryBatch? get oldest =>
      _batches.isEmpty ? null : _batches.first;

  Map<String, Object?> get health => <String, Object?>{
        atServerOutboxBatchesAttribute: batchCount,
        atServerOutboxBytesAttribute: bytes,
        atServerOutboxDroppedAttribute: droppedSinceBoot,
      };

  // Takes the next sequence number for this boot and persists the batch
  // before returning it
  Future<AtServerTelemetryBatch> add(String body) async {
    final AtTelemetrySequence sequence =
        AtTelemetrySequence(bootId: bootId, number: _nextNumber++);
    final DateTime createdAt = _now().toUtc();
    final List<int> contents = utf8.encode(
      AtServerTelemetryBatch.contentsFor(sequence, createdAt, body),
    );
    final File file = File(
      '${directory.path}/'
      '${AtServerTelemetryBatch.fileNameFor(sequence, createdAt)}',
    );
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(contents, flush: true);
    await temporary.rename(file.path);

    final AtServerTelemetryBatch batch = AtServerTelemetryBatch(
      sequence: sequence,
      createdAt: createdAt,
      body: utf8.encode(body),
      file: file,
      sizeInBytes: contents.length,
    );
    _batches.add(batch);
    _bytes += batch.sizeInBytes;
    await enforceLimits();
    return batch;
  }

  Future<void> remove(AtServerTelemetryBatch batch) async {
    if (!_batches.remove(batch)) {
      return;
    }
    _bytes -= batch.sizeInBytes;
    await _deleteQuietly(batch.file);
  }

  Future<void> enforceLimits() async {
    final DateTime oldestAllowed = _now().toUtc().subtract(maxAge);
    final List<AtServerTelemetryBatch> dropped = <AtServerTelemetryBatch>[];
    while (_batches.isNotEmpty &&
        (_bytes > maxBytes ||
            _batches.first.createdAt.isBefore(oldestAllowed))) {
      final AtServerTelemetryBatch batch = _batches.removeAt(0);
      _bytes -= batch.sizeInBytes;
      dropped.add(batch);
      await _deleteQuietly(batch.file);
    }
    if (dropped.isEmpty) {
      return;
    }
    _dropped += dropped.length;
    _logger.warning('Telemetry outbox is over its limits; dropped '
        '${dropped.length} batches: '
        '${dropped.map((AtServerTelemetryBatch batch) => batch.sequence).join(', ')}');
  }

  static int _oldestFirst(
    AtServerTelemetryBatch left,
    AtServerTelemetryBatch right,
  ) {
    final int byTime = left.createdAt.compareTo(right.createdAt);
    if (byTime != 0) {
      return byTime;
    }
    final int byBoot = left.sequence.bootId.compareTo(right.sequence.bootId);
    if (byBoot != 0) {
      return byBoot;
    }
    return left.sequence.number.compareTo(right.sequence.number);
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone
    }
  }
}
