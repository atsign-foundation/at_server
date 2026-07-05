import 'dart:convert';
import 'dart:core';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';

/// Persists compaction stats as atKeys in the secondary's keystore.
/// One persistence-key per resource label
/// (`commitLog` / `accessLog` / `notificationKeystore`). A
/// different deployment could push stats to Prometheus, etc
class AtCompactionStatsService {
  final AtKeyValueStore _keyValueStore;
  final _logger = AtSignLogger("AtCompactionStats");

  AtCompactionStatsService(this._keyValueStore);

  /// Resource-label → keystore atKey used to persist that resource's
  /// stats. Exposed for tests.
  @visibleForTesting
  static const Map<String, String> labelToKey = {
    'commitLog': AtConstants.commitLogCompactionKey,
    'accessLog': AtConstants.accessLogCompactionKey,
    'notificationKeystore': AtConstants.notificationCompactionKey,
  };

  Future<void> record({
    required String label,
    required DateTime start,
    required int compactedCount,
    required Duration duration,
  }) async {
    final compactionStatsKey = labelToKey[label];
    if (compactionStatsKey == null) {
      _logger.warning('No persistence key for compaction label "$label"; '
          'stats dropped.');
      return;
    }
    final payload = <String, String>{
      'atCompactionType': label,
      'lastCompactionRun': start.toUtc().toString(),
      'compactionDurationInMills': duration.inMilliseconds.toString(),
      'deletedKeysCount': compactedCount.toString(),
    };
    _logger.finest('Completed compaction of $label: $payload');
    try {
      await _keyValueStore.put(
          compactionStatsKey, AtData()..data = json.encode(payload));
    } on Exception catch (e) {
      _logger.severe(e);
    }
  }
}
