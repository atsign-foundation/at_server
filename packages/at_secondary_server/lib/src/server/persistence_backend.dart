import 'dart:convert';
import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/dual.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_utils/at_logger.dart';
import 'package:path/path.dart' as p;

/// Thrown when a backend migration (or its post-migration verify) fails.
/// Propagating out of `start()` aborts server startup, leaving the source
/// data and the marker untouched — a restart on the old config comes
/// straight back up.
class PersistenceMigrationException implements Exception {
  final String message;
  PersistenceMigrationException(this.message);
  @override
  String toString() => 'PersistenceMigrationException: $message';
}

/// The on-disk record of which backend currently holds an atServer's live
/// data, written to a well-known path in the storage root so both the
/// bootstrap (which backend to open) and an out-of-band cleanup sweep
/// (whether a retained source is old enough to delete) can read it.
class PersistenceBackendMarker {
  final String activeBackend;
  final String? previousBackend;
  final List<String> previousPaths;
  final DateTime? migratedAt;

  PersistenceBackendMarker({
    required this.activeBackend,
    this.previousBackend,
    this.previousPaths = const [],
    this.migratedAt,
  });

  Map<String, dynamic> toJson() => {
        'activeBackend': activeBackend,
        'previousBackend': previousBackend,
        'previousPaths': previousPaths,
        'migratedAt': migratedAt?.toUtc().toIso8601String(),
      };

  static PersistenceBackendMarker fromJson(Map<String, dynamic> json) =>
      PersistenceBackendMarker(
        activeBackend: json['activeBackend'] as String,
        previousBackend: json['previousBackend'] as String?,
        previousPaths:
            (json['previousPaths'] as List?)?.cast<String>() ?? const [],
        migratedAt: json['migratedAt'] == null
            ? null
            : DateTime.parse(json['migratedAt'] as String),
      );

  /// Reads the marker at [path], or `null` if it does not exist.
  static PersistenceBackendMarker? read(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    return fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
  }

  /// Writes the marker to [path] (creating parent dirs).
  static void write(String path, PersistenceBackendMarker marker) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(marker.toJson()));
  }
}

/// Selects the persistence backend from [AtSecondaryConfig] and, when the
/// on-disk marker disagrees with the configured backend, performs a
/// migrate → verify → flip-marker (retaining the source data) before the
/// bootstrap opens the target. Abort-on-failure: any error propagates.
class PersistenceBackendManager {
  static const String hive = 'hive';
  static const String sqlite = 'sqlite';

  /// Validation harness backend: serves reads from Hive while mirroring every
  /// write into SQLite. Run the functional pack against it, then compare the
  /// two DB sets under <storageRoot> with bin/compare_persistence.dart. Not a
  /// persistent backend — no marker, no migration.
  static const String dual = 'dual';

  static final _logger = AtSignLogger('PersistenceBackendManager');

  static String get markerPath =>
      p.join(AtSecondaryConfig.storageRoot, '.persistence_backend');

  /// The configured target backend (normalised / validated).
  static String get configuredBackend {
    final b = AtSecondaryConfig.persistenceBackend.toLowerCase().trim();
    if (b != hive && b != sqlite && b != dual) {
      throw PersistenceMigrationException(
          "Unknown persistenceBackend '$b' (expected 'hive', 'sqlite' or 'dual')");
    }
    return b;
  }

  static HivePersistenceConfig _hiveConfig() =>
      HivePersistenceConfig.serverDefaults(
        storagePath: AtSecondaryConfig.storagePath,
        commitLogPath: AtSecondaryConfig.commitLogPath,
        accessLogPath: AtSecondaryConfig.accessLogPath,
        notificationStoragePath: AtSecondaryConfig.notificationStoragePath,
      );

  static SqlitePersistenceConfig _sqliteConfig() =>
      SqlitePersistenceConfig.serverDefaults(
          storagePath: p.join(AtSecondaryConfig.storageRoot, 'sqlite'));

  static AtPersistenceConfig configFor(String backend) => switch (backend) {
        sqlite => _sqliteConfig(),
        dual => DualWritePersistenceConfig(
            primary: _hiveConfig(), secondary: _sqliteConfig()),
        _ => _hiveConfig(),
      };

  static AtPersistenceFactory factoryFor(String backend) => switch (backend) {
        sqlite => SqliteAtPersistenceFactory(),
        dual => DualWriteAtPersistenceFactory(
            HiveAtPersistenceFactory(), SqliteAtPersistenceFactory()),
        _ => HiveAtPersistenceFactory(),
      };

  static List<String> dataPathsFor(String backend) => backend == sqlite
      ? [p.join(AtSecondaryConfig.storageRoot, 'sqlite')]
      : [
          AtSecondaryConfig.storagePath,
          AtSecondaryConfig.commitLogPath,
          AtSecondaryConfig.accessLogPath,
          AtSecondaryConfig.notificationStoragePath,
        ];

  /// If the on-disk marker's active backend differs from [targetBackend],
  /// migrates the atSign's data into the target backend, verifies a
  /// byte-identical snapshot, and (only then) flips the marker while
  /// retaining the source data. Absent marker ⇒ the legacy default `hive`.
  static Future<void> migrateIfNeeded(
      String atSign, String targetBackend) async {
    // The dual-write harness is transient (it writes to both Hive and SQLite);
    // it has no marker and never triggers a migration.
    if (targetBackend == dual) return;
    final marker = PersistenceBackendMarker.read(markerPath);
    final currentBackend = marker?.activeBackend ?? hive;
    if (currentBackend == targetBackend) return;

    _logger.warning(
        'Persistence backend change for $atSign: $currentBackend -> '
        '$targetBackend. Migrating (abort-on-failure)...');

    final sourceFactory = factoryFor(currentBackend);
    final targetFactory = factoryFor(targetBackend);
    try {
      final source =
          await sourceFactory.initialize(atSign, configFor(currentBackend));
      final target =
          await targetFactory.initialize(atSign, configFor(targetBackend));

      // Clean slate so a retried migration (after a prior failure) does
      // not stack onto partial target data.
      await target.clear();

      final report = await PersistenceMigrator.migrate(source, target);

      final sourceSnapshot = await PersistenceSnapshot.capture(source);
      final targetSnapshot = await PersistenceSnapshot.capture(target);
      final diff = sourceSnapshot.describeDifferenceFrom(targetSnapshot);
      if (diff != null) {
        throw PersistenceMigrationException(
            'post-migration verify failed for $atSign: $diff');
      }
      _logger.warning('Migration verified for $atSign: $report');
    } finally {
      await sourceFactory.close();
      await targetFactory.close();
    }

    // Success — flip the marker, retaining the source data on disk for
    // rollback / the cleanup sweep to reclaim later.
    PersistenceBackendMarker.write(
      markerPath,
      PersistenceBackendMarker(
        activeBackend: targetBackend,
        previousBackend: currentBackend,
        previousPaths: dataPathsFor(currentBackend),
        migratedAt: DateTime.now(),
      ),
    );
    _logger.warning(
        'Persistence backend for $atSign is now $targetBackend '
        '(previous $currentBackend data retained).');
  }

  /// Reclaims a retained source-backend data tree once a migration is old
  /// enough to trust. Reads the marker at [markerPath]; if it records a
  /// migration completed more than [retention] ago, deletes every path in
  /// `previousPaths` and clears the `previous*` fields from the marker.
  /// Returns the paths deleted (the paths that WOULD be deleted, on
  /// [dryRun]). A no-op when there is no marker, no previous data, or the
  /// migration is too recent.
  static List<String> sweepStaleSource(
    String markerPath, {
    required Duration retention,
    bool dryRun = false,
  }) {
    final marker = PersistenceBackendMarker.read(markerPath);
    if (marker == null ||
        marker.previousBackend == null ||
        marker.previousPaths.isEmpty ||
        marker.migratedAt == null) {
      return const [];
    }
    final age = DateTime.now().difference(marker.migratedAt!);
    if (age < retention) return const [];

    final deleted = <String>[];
    for (final path in marker.previousPaths) {
      final dir = Directory(path);
      final file = File(path);
      if (dir.existsSync()) {
        if (!dryRun) dir.deleteSync(recursive: true);
        deleted.add(path);
      } else if (file.existsSync()) {
        if (!dryRun) file.deleteSync();
        deleted.add(path);
      }
    }
    if (!dryRun && deleted.isNotEmpty) {
      PersistenceBackendMarker.write(
        markerPath,
        PersistenceBackendMarker(activeBackend: marker.activeBackend),
      );
    }
    return deleted;
  }
}
