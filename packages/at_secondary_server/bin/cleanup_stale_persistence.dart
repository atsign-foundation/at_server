import 'dart:io';

import 'package:at_secondary/src/server/persistence_backend.dart';
import 'package:path/path.dart' as p;

/// Reclaims a retained source-backend data tree after a persistence
/// backend migration, once it is old enough to trust.
///
/// After `migrateIfNeeded` flips the marker it RETAINS the old-backend
/// data (for rollback). This sweep deletes that data once the migration
/// is older than the retention window. Intended to run as a cron entry
/// on each atServer host.
///
/// Usage:
///   dart bin/cleanup_stale_persistence.dart \
///     --storage-root storage [--retention-days 7] [--dry-run]
void main(List<String> args) {
  var storageRoot = 'storage';
  var retentionDays = 7;
  var dryRun = false;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--storage-root':
        storageRoot = args[++i];
      case '--retention-days':
        retentionDays = int.parse(args[++i]);
      case '--dry-run':
        dryRun = true;
      case '-h':
      case '--help':
        stdout.writeln('Usage: cleanup_stale_persistence.dart '
            '--storage-root <dir> [--retention-days N] [--dry-run]');
        return;
    }
  }

  final markerPath = p.join(storageRoot, '.persistence_backend');
  final deleted = PersistenceBackendManager.sweepStaleSource(
    markerPath,
    retention: Duration(days: retentionDays),
    dryRun: dryRun,
  );

  if (deleted.isEmpty) {
    stdout.writeln('Nothing to reclaim (no marker, no retained source, or '
        'migration younger than $retentionDays days).');
  } else {
    stdout.writeln('${dryRun ? "Would delete" : "Deleted"} retained source '
        'data:\n  ${deleted.join("\n  ")}');
  }
}
