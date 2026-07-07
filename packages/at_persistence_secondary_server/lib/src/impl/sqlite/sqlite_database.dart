import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_schema.dart';

/// A single per-atSign SQLite database file. All four stores for an
/// atSign (keystore, commit log, notification keystore, access log) share
/// one instance — one open connection to one `atsign.db` — so a value
/// write and its commit-log row commit atomically in one transaction.
///
/// sqlite3's API is synchronous; the store methods wrap these calls in
/// `Future`-returning signatures to satisfy the async interface. A call
/// blocks the isolate for the duration of the file I/O (the same tradeoff
/// Hive's synchronous box operations make).
class SqliteDatabase {
  /// The atSign this database belongs to.
  final String atSign;

  /// Absolute or relative path to the `.db` file.
  final String path;

  final Database _db;

  /// Nesting depth of [runInTransaction] — only the outermost call
  /// issues `BEGIN`/`COMMIT`, so stores can compose (keystore.put wraps
  /// commitLog.commit) without nested-transaction errors.
  int _txnDepth = 0;

  bool _rollbackPending = false;

  SqliteDatabase._(this.atSign, this.path, this._db);

  static bool _libraryConfigured = false;

  /// On Linux, point `package:sqlite3` at the versioned soname
  /// `libsqlite3.so.0` shipped by the runtime `libsqlite3-0` package — its
  /// default (`libsqlite3.so`) only exists in the `-dev` package. No-op on
  /// macOS/Windows, where the default resolution works. Runs once, before
  /// the first `sqlite3.open`.
  static void _configureLibrary() {
    if (_libraryConfigured) return;
    _libraryConfigured = true;
    if (!Platform.isLinux) return;
    sqlite_open.open
        .overrideFor(sqlite_open.OperatingSystem.linux, () {
      try {
        return DynamicLibrary.open('libsqlite3.so.0');
      } on ArgumentError {
        return DynamicLibrary.open('libsqlite3.so');
      }
    });
  }

  /// Opens (creating parent directories and the file if needed) the
  /// database at [dbPath], applies [SqliteSchema], and returns the
  /// context.
  static SqliteDatabase open(String atSign, String dbPath) {
    _configureLibrary();
    final dir = p.dirname(dbPath);
    if (dir.isNotEmpty) {
      Directory(dir).createSync(recursive: true);
    }
    final db = sqlite3.open(dbPath);
    try {
      SqliteSchema.apply(db);
    } catch (_) {
      db.dispose();
      rethrow;
    }
    return SqliteDatabase._(atSign, dbPath, db);
  }

  /// The underlying sqlite3 handle. Stores use it for `select` / `execute`
  /// / `prepare`. Prefer routing mutations through [runInTransaction].
  Database get raw => _db;

  /// Runs [body] inside a single transaction. Re-entrant: a nested call
  /// joins the outer transaction rather than starting its own, and a
  /// rollback anywhere aborts the whole outermost transaction. On any
  /// thrown error the (outermost) transaction rolls back and the error
  /// propagates.
  T runInTransaction<T>(T Function() body) {
    if (_txnDepth > 0) {
      // Already inside a transaction — join it. A throw here sets the
      // rollback flag so the outermost frame rolls the whole thing back.
      try {
        return body();
      } catch (_) {
        _rollbackPending = true;
        rethrow;
      }
    }
    _db.execute('BEGIN IMMEDIATE;');
    _txnDepth++;
    _rollbackPending = false;
    try {
      final result = body();
      if (_rollbackPending) {
        _db.execute('ROLLBACK;');
      } else {
        _db.execute('COMMIT;');
      }
      return result;
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    } finally {
      _txnDepth--;
      _rollbackPending = false;
    }
  }

  /// `true` while a [runInTransaction] body is executing.
  bool get inTransaction => _txnDepth > 0;

  /// Drops all rows from every table and re-seeds the counter, keeping
  /// the connection open. Backs [AtPersistenceBundle.clear] for cheap
  /// per-test isolation.
  void clear() {
    runInTransaction(() {
      _db.execute('DELETE FROM at_data;');
      _db.execute('DELETE FROM commit_log;');
      _db.execute('DELETE FROM notifications;');
      _db.execute('DELETE FROM access_log;');
      _db.execute("UPDATE counters SET value = 0 WHERE name = 'last_commit_id';");
    });
  }

  /// Closes the connection. Idempotent-safe for the bundle's close path
  /// (callers must not use the context afterwards).
  void close() {
    _db.dispose();
  }
}
