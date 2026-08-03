import 'package:sqlite3/sqlite3.dart';

/// The per-atSign SQLite schema — a stable interchange contract. One
/// database per atSign; every store (keystore, commit log, notifications,
/// access log) lives in the same `atsign.db` file so a value write and its
/// commit entry can share one transaction.
///
/// The DDL, PRAGMAs, and [contractVersion] here are the canonical
/// definition of that contract.
class SqliteSchema {
  SqliteSchema._();

  /// `PRAGMA user_version`. A reader hard-fails on a database whose
  /// stored version is HIGHER than this (it cannot know the newer shape)
  /// and migrates-forward from a lower one.
  static const int contractVersion = 1;

  /// One row per live atKey. Deletes remove the row (sync-visible
  /// deletion state lives in [commitLog], not here as a tombstone).
  /// `metadata` is the canonical `AtMetaData` JSON (the wire `llookup:all`
  /// form); `expires_at`/`available_at`/`refresh_at` are indexed extracts
  /// of the same-named derived metadata fields (epoch millis, UTC).
  static const String atData = '''
CREATE TABLE IF NOT EXISTS at_data (
  atkey        TEXT PRIMARY KEY NOT NULL,
  value        TEXT,
  metadata     TEXT NOT NULL,
  expires_at   INTEGER,
  available_at INTEGER,
  refresh_at   INTEGER
) WITHOUT ROWID;
''';

  static const List<String> atDataIndexes = [
    'CREATE INDEX IF NOT EXISTS at_data_expires_at ON at_data (expires_at) WHERE expires_at IS NOT NULL;',
    'CREATE INDEX IF NOT EXISTS at_data_available_at ON at_data (available_at) WHERE available_at IS NOT NULL;',
    'CREATE INDEX IF NOT EXISTS at_data_refresh_at ON at_data (refresh_at) WHERE refresh_at IS NOT NULL;',
  ];

  /// One row per atKey, newest-wins: a new commit for an atKey replaces
  /// that atKey's row (the canonical `CommitLogKeyStore` collapse — the
  /// log answers "each key's latest commit", not the history).
  static const String commitLog = '''
CREATE TABLE IF NOT EXISTS commit_log (
  atkey     TEXT PRIMARY KEY NOT NULL,
  commit_id INTEGER NOT NULL,
  operation TEXT NOT NULL CHECK (operation IN ('+', '#', '*', '-')),
  op_time   INTEGER
) WITHOUT ROWID;
''';

  static const List<String> commitLogIndexes = [
    'CREATE UNIQUE INDEX IF NOT EXISTS commit_log_commit_id ON commit_log (commit_id);',
    // Partial index over live (non-DELETE) entries, backing sync's
    // skip-deletes range scan (see SqliteAtCommitLog._iterateSkippingDeletes).
    // On a delete-dominated log this turns "walk every entry looking for the
    // few live ones" into a seek over just the live ones; it costs little on
    // a log with few deletes (it then largely mirrors commit_log_commit_id).
    //
    // No contract-version bump: an index is derived data, recreated here by
    // IF NOT EXISTS on every open, so an existing database acquires it on the
    // next start with no reshaping. Bumping would be actively harmful --
    // apply() hard-fails on a database newer than the running server, so a
    // bump would block rolling back to a server that reads this file fine.
    "CREATE INDEX IF NOT EXISTS commit_log_live ON commit_log (commit_id) WHERE operation <> '-';",
  ];

  /// Monotonic allocators. `last_commit_id` is bumped in the same
  /// transaction as each synced write, giving a dense, gapless commit id
  /// per database. (A `MAX(commit_log.commit_id)` allocator is unsafe:
  /// expiry purges a key's commit row and could reissue the max id.)
  static const String counters = '''
CREATE TABLE IF NOT EXISTS counters (
  name  TEXT PRIMARY KEY NOT NULL,
  value INTEGER NOT NULL
) WITHOUT ROWID;
''';

  static const String seedCounters =
      "INSERT OR IGNORE INTO counters (name, value) VALUES ('last_commit_id', 0);";

  /// Durable notification delivery queue + inbox. `payload` is the
  /// canonical `AtNotification` JSON; the other columns are indexed
  /// extracts for the three query shapes (since-time monitor scans,
  /// startup re-enqueue of `queued`, expiry sweep).
  static const String notifications = '''
CREATE TABLE IF NOT EXISTS notifications (
  id                    TEXT PRIMARY KEY NOT NULL,
  payload               TEXT NOT NULL,
  notification_datetime INTEGER NOT NULL,
  type                  TEXT NOT NULL,
  status                TEXT NOT NULL,
  expires_at            INTEGER
) WITHOUT ROWID;
''';

  static const List<String> notificationIndexes = [
    'CREATE INDEX IF NOT EXISTS notifications_datetime ON notifications (notification_datetime);',
    'CREATE INDEX IF NOT EXISTS notifications_status ON notifications (status);',
    'CREATE INDEX IF NOT EXISTS notifications_expires_at ON notifications (expires_at) WHERE expires_at IS NOT NULL;',
  ];

  /// Insert-only connection/verb audit feeding the `stats` verbs. `seq`
  /// is the implicit rowid alias (insertion order == id order).
  static const String accessLog = '''
CREATE TABLE IF NOT EXISTS access_log (
  seq         INTEGER PRIMARY KEY,
  from_atsign TEXT,
  request_at  INTEGER NOT NULL,
  verb_name   TEXT,
  lookup_key  TEXT
);
''';

  static const List<String> accessLogIndexes = [
    'CREATE INDEX IF NOT EXISTS access_log_request_at ON access_log (request_at);',
  ];

  /// Open-time PRAGMAs. TRUNCATE + synchronous=NORMAL survives process kill
  /// and is strictly required to enforce POSIX fcntl distributed locking
  /// across Docker Swarm nodes on NFSv4 (WAL bypasses POSIX locking via mmap).
  static const List<String> pragmas = [
    'PRAGMA journal_mode = TRUNCATE;',
    'PRAGMA synchronous = NORMAL;',
    'PRAGMA busy_timeout = 5000;',
  ];

  /// Applies PRAGMAs, creates every table/index (idempotent), seeds the
  /// counters, and reconciles `user_version`. Safe to call on an existing
  /// database (nothing is dropped).
  ///
  /// Throws [StateError] if the database's stored `user_version` is newer
  /// than [contractVersion] — this reader cannot safely touch a
  /// forward-versioned file.
  static void apply(Database db) {
    for (final p in pragmas) {
      db.execute(p);
    }

    final storedVersion = _userVersion(db);
    if (storedVersion > contractVersion) {
      throw StateError(
          'SQLite database is at contract version $storedVersion, newer than '
          'this server understands ($contractVersion). Refusing to open.');
    }

    db.execute(atData);
    for (final ix in atDataIndexes) {
      db.execute(ix);
    }
    db.execute(commitLog);
    for (final ix in commitLogIndexes) {
      db.execute(ix);
    }
    db.execute(counters);
    db.execute(seedCounters);
    db.execute(notifications);
    for (final ix in notificationIndexes) {
      db.execute(ix);
    }
    db.execute(accessLog);
    for (final ix in accessLogIndexes) {
      db.execute(ix);
    }

    if (storedVersion < contractVersion) {
      // Forward-migrate marker. (v1 is the initial contract, so there is
      // no data reshaping to do; future bumps add migration steps here.)
      db.execute('PRAGMA user_version = $contractVersion;');
    }
  }

  static int _userVersion(Database db) {
    final rs = db.select('PRAGMA user_version;');
    return rs.isEmpty ? 0 : (rs.first.values.first as int);
  }
}
