import 'dart:convert';
import 'dart:io';

import 'package:at_telemetry/at_telemetry.dart';

// One closed batch in the outbox: its OTLP/JSON body and the boot id and
// sequence number it took when it entered the outbox, which it keeps across
// restarts
final class AtServerTelemetryBatch {
  final AtTelemetrySequence sequence;
  final DateTime createdAt;
  final List<int> body;
  final File file;
  // What the batch takes on disk
  final int sizeInBytes;

  AtServerTelemetryBatch({
    required this.sequence,
    required this.createdAt,
    required this.body,
    required this.file,
    required this.sizeInBytes,
  });

  factory AtServerTelemetryBatch.decode(File file, String contents) {
    final Object? json = jsonDecode(contents);
    if (json is! Map<String, Object?>) {
      throw const FormatException('Outbox batch is not a JSON object');
    }
    final Object? bootId = json['boot'];
    final Object? number = json['seq'];
    final Object? createdAt = json['createdAt'];
    final Object? body = json['body'];
    if (bootId is! String ||
        number is! int ||
        createdAt is! String ||
        body is! String) {
      throw const FormatException('Outbox batch is missing a field');
    }
    try {
      return AtServerTelemetryBatch(
        sequence: AtTelemetrySequence(bootId: bootId, number: number),
        createdAt: DateTime.parse(createdAt).toUtc(),
        body: utf8.encode(body),
        file: file,
        sizeInBytes: utf8.encode(contents).length,
      );
    } on ArgumentError {
      throw const FormatException('Outbox batch has an invalid sequence');
    }
  }

  // Sorts oldest first by name alone
  static String fileNameFor(AtTelemetrySequence sequence, DateTime createdAt) {
    final String time =
        createdAt.toUtc().microsecondsSinceEpoch.toString().padLeft(20, '0');
    final String number = sequence.number.toString().padLeft(16, '0');
    return '$time-${sequence.bootId}-$number.json';
  }

  static String contentsFor(
    AtTelemetrySequence sequence,
    DateTime createdAt,
    String body,
  ) {
    return jsonEncode(<String, Object?>{
      'boot': sequence.bootId,
      'seq': sequence.number,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'body': body,
    });
  }
}
