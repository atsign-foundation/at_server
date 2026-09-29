import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:at_utils/at_logger.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

// For interfacing with the telemetry queue that exists on disk (SQLite database)
// This class does not send any HTTP requests. See AtServerTelemetryExporter. AtServerTelemetryExporter uses AtServerTelemetryDiskQueue to manage and find out what telemetry to push
final class AtServerTelemetryDiskQueue {
  static bool _libraryConfigured = false;

  final Database _database;
  final int maxRecords;
  final int maxBytes;
  final AtSignLogger _logger = AtSignLogger('AtServerTelemetryDiskQueue');
  int droppedRecords = 0;

  AtServerTelemetryDiskQueue._(this._database, this.maxRecords, this.maxBytes);

  static AtServerTelemetryDiskQueue open({
    required String serverId,
    required String storagePath,
    required int maxRecords,
    required int maxBytes,
  }) {
    if (maxRecords < 1 || maxBytes < 1) {
      throw ArgumentError('Telemetry queue limits must be positive');
    }
    if (!_libraryConfigured) {
      _libraryConfigured = true;
      if (Platform.isLinux) {
        sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.linux, () {
          try {
            return DynamicLibrary.open('libsqlite3.so.0');
          } on ArgumentError {
            return DynamicLibrary.open('libsqlite3.so');
          }
        });
      }
    }

    Directory(storagePath).createSync(recursive: true);
    final String filename =
        '${sha256.convert(utf8.encode(serverId)).toString()}.sqlite';
    final Database database = sqlite3.open(p.join(storagePath, filename));
    try {
      database.execute('PRAGMA journal_mode = DELETE');
      database.execute('PRAGMA synchronous = FULL');
      database.execute('PRAGMA busy_timeout = 250');
      database.execute('CREATE TABLE IF NOT EXISTS telemetry_queue ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB NOT NULL)');
      final AtServerTelemetryDiskQueue queue =
          AtServerTelemetryDiskQueue._(database, maxRecords, maxBytes);
      queue._trimExisting();
      return queue;
    } catch (_) {
      database.dispose();
      rethrow;
    }
  }

  // saves payload in a transaction
  // if record or byte limit would be exceeded,
  // drop the oldest record.
  bool write(List<int> payload) {
    if (payload.length > maxBytes) {
      _reportDropped(1, 'oversized');
      return false;
    }

    final int removed = _transaction(() {
      final int evicted =
          _evictOldest(incomingSize: payload.length, addingRecord: true);
      _database.execute(
        'INSERT INTO telemetry_queue (payload) VALUES (?)',
        <Object?>[payload],
      );
      return evicted;
    });
    if (removed > 0) {
      _reportDropped(removed, 'oldest');
    }
    return true;
  }

  // peek returns a tuple (int id, List<int> payload)
  // returns oldest stored payload without removing it
  // acknowledge() deletes the oldest payload
  (int id, List<int> payload)? peek() {
    final List<Row> rows = _database.select(
      'SELECT id, payload FROM telemetry_queue ORDER BY id LIMIT 1',
    );
    if (rows.isEmpty) {
      return null;
    }
    final Row row = rows.single;
    return (row['id'] as int, row['payload'] as List<int>);
  }

  bool get isNotEmpty =>
      _database.select('SELECT 1 FROM telemetry_queue LIMIT 1').isNotEmpty;

  void acknowledge(int id) {
    _database.execute(
      'DELETE FROM telemetry_queue WHERE id = ?',
      <Object?>[id],
    );
  }

  void close() => _database.dispose();

  void _trimExisting() {
    final int removed = _transaction(() => _evictOldest());
    if (removed > 0) {
      _reportDropped(removed, 'oldest');
    }
  }

  int _evictOldest({int incomingSize = 0, bool addingRecord = false}) {
    final List<Row> rows = _database.select(
      'SELECT id, length(payload) AS bytes FROM telemetry_queue ORDER BY id',
    );
    int count = rows.length + (addingRecord ? 1 : 0);
    int bytes = incomingSize;
    for (final Row row in rows) {
      bytes += row['bytes'] as int;
    }
    int removed = 0;
    for (final Row row in rows) {
      if (count <= maxRecords && bytes <= maxBytes) {
        break;
      }
      _database.execute(
        'DELETE FROM telemetry_queue WHERE id = ?',
        <Object?>[row['id']],
      );
      count--;
      bytes -= row['bytes'] as int;
      removed++;
    }
    return removed;
  }

  T _transaction<T>(T Function() work) {
    _database.execute('BEGIN IMMEDIATE');
    try {
      final T result = work();
      _database.execute('COMMIT');
      return result;
    } catch (_) {
      try {
        _database.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }

  void _reportDropped(int count, String reason) {
    droppedRecords += count;
    _logger.warning('Telemetry queue full, dropped $count $reason record(s)');
  }
}
