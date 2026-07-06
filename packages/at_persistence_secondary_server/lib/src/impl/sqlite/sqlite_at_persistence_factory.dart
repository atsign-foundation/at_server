import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';

import 'sqlite_at_access_log.dart';
import 'sqlite_at_commit_log.dart';
import 'sqlite_at_keyvalue_store.dart';
import 'sqlite_at_notification_keystore.dart';
import 'sqlite_database.dart';
import 'sqlite_persistence_config.dart';

/// SQLite-backed [AtPersistenceFactory]. Produces one
/// [SqliteAtPersistenceBundle] per atSign, each wrapping a single shared
/// [SqliteDatabase] (`<storagePath>/<atSign>/atsign.db`) — so every store
/// for an atSign transacts against the same connection.
class SqliteAtPersistenceFactory implements AtPersistenceFactory {
  final _logger = AtSignLogger('SqliteAtPersistenceFactory');

  final Map<String, SqliteAtPersistenceBundle> _bundles = {};

  @override
  AtPersistenceBackendId get backendId => AtPersistenceBackendId.sqlite;

  @override
  Future<AtPersistenceBundle> initialize(
      String atSign, AtPersistenceConfig config) async {
    if (config is! SqlitePersistenceConfig) {
      throw ArgumentError(
          'SqliteAtPersistenceFactory expects SqlitePersistenceConfig, '
          'got ${config.runtimeType}');
    }

    final existing = _bundles[atSign];
    if (existing != null) {
      if (!existing.isClosed) return existing;
      _bundles.remove(atSign);
    }

    _logger.info('Initialising SQLite persistence for $atSign');

    final db = SqliteDatabase.open(atSign, config.dbPathFor(atSign));

    final commitLog = config.enableCommitLog ? SqliteAtCommitLog(db) : null;
    final accessLog = config.enableAccessLog ? SqliteAtAccessLog(db) : null;
    final notificationKeystore =
        config.enableNotificationKeystore ? SqliteAtNotificationKeystore(db) : null;

    final keyValueStore = SqliteAtKeyValueStore(db, atSign)
      ..commitLog = commitLog;
    await keyValueStore.initialize();

    final bundle = SqliteAtPersistenceBundle._(
      atSign: atSign,
      db: db,
      keyValueStore: keyValueStore,
      accessLog: accessLog,
      notificationKeystore: notificationKeystore,
    );
    _bundles[atSign] = bundle;
    return bundle;
  }

  @override
  AtPersistenceBundle? bundleFor(String atSign) {
    final bundle = _bundles[atSign];
    if (bundle == null) return null;
    if (bundle.isClosed) {
      _bundles.remove(atSign);
      return null;
    }
    return bundle;
  }

  @override
  Future<void> closeFor(String atSign) async {
    final bundle = _bundles.remove(atSign);
    if (bundle == null) return;
    try {
      await bundle.close();
    } catch (e, st) {
      _logger.warning('Error closing bundle for $atSign: $e\n$st');
    }
  }

  @override
  Future<void> close() async {
    final bundles = _bundles.values.toList();
    _bundles.clear();
    for (final b in bundles) {
      try {
        await b.close();
      } catch (e, st) {
        _logger.warning('Error closing bundle for ${b.atSign}: $e\n$st');
      }
    }
  }
}

/// SQLite-backed [AtPersistenceBundle]. All stores share the one
/// [SqliteDatabase]; the bundle owns its lifecycle.
class SqliteAtPersistenceBundle implements AtPersistenceBundle {
  @override
  final String atSign;

  final SqliteDatabase _db;

  @override
  final SqliteAtKeyValueStore keyValueStore;

  @override
  final SqliteAtAccessLog? accessLog;

  @override
  final SqliteAtNotificationKeystore? notificationKeystore;

  bool _closed = false;

  @override
  bool get isClosed => _closed;

  SqliteAtPersistenceBundle._({
    required this.atSign,
    required SqliteDatabase db,
    required this.keyValueStore,
    required this.accessLog,
    required this.notificationKeystore,
  }) : _db = db;

  @override
  AtPersistenceBackendId get backendId => AtPersistenceBackendId.sqlite;

  @override
  Future<void> clear() async {
    if (_closed) {
      throw StateError(
          'Cannot clear a closed SqliteAtPersistenceBundle for $atSign');
    }
    _db.clear();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _db.close();
  }
}
