import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:path/path.dart' as p;

/// Where an [AtPersistenceConfig] puts its data, as a comparable value.
///
/// [AtPersistenceFactory] caches one bundle per atSign — that is the
/// interface's stated contract, and [AtPersistenceFactory.bundleFor] and
/// [AtPersistenceFactory.closeFor] both key on the atSign alone, so there is
/// nowhere for a second bundle to live. A factory therefore cannot honour two
/// different storage locations for one atSign, and must say so rather than
/// return the bundle it happens to hold: a caller handed a bundle rooted
/// somewhere other than the path it asked for has no way to notice, and reads
/// another store's records as its own.
///
/// Hive spreads an atSign across four directories and SQLite keeps one file
/// under a storage root, so the comparison is over every path the interface
/// exposes rather than over `storagePath` alone.
List<String> storageLocationsOf(AtPersistenceConfig config) => [
      config.storagePath,
      config.commitLogPath,
      config.accessLogPath,
      config.notificationStoragePath,
      config.backendMarkerPath,
    ];

/// Whether two configurations name the same storage locations.
///
/// Compared lexically first (`foo/bar` and `foo/./bar` are one location, and
/// calling them two would refuse a caller who is doing nothing wrong). Only
/// when that disagrees is the filesystem consulted, which is where a symlink
/// and its target are recognised as one directory — an ordinary deployment
/// shape (`/data -> /mnt/data`), and not worth a spurious refusal.
///
/// A path that does not exist cannot be resolved, so it stands on its lexical
/// form: two paths that differ lexically and are not both present are
/// different.
bool sameStorageLocations(AtPersistenceConfig a, AtPersistenceConfig b) {
  final left = storageLocationsOf(a);
  final right = storageLocationsOf(b);
  for (var i = 0; i < left.length; i++) {
    if (!_sameLocation(left[i], right[i])) {
      return false;
    }
  }
  return true;
}

bool _sameLocation(String a, String b) {
  if (p.canonicalize(a) == p.canonicalize(b)) {
    return true;
  }
  return _resolved(a) == _resolved(b);
}

/// The real location of [path], or null when it cannot be resolved.
///
/// Returns null rather than falling back to the lexical form, so that two
/// unresolvable paths are never reported equal by both being null — they have
/// already failed the lexical comparison above.
String? _resolved(String path) {
  try {
    final entity = Directory(path);
    if (!entity.existsSync()) {
      return null;
    }
    return p.canonicalize(entity.resolveSymbolicLinksSync());
  } on FileSystemException {
    return null;
  }
}

/// The refusal an [AtPersistenceFactory] raises when it is asked to build a
/// bundle for an atSign it already holds one for, somewhere else.
StateError conflictingStorageError({
  required String factory,
  required String atSign,
  required AtPersistenceConfig held,
  required AtPersistenceConfig requested,
}) =>
    StateError('$factory already holds an open bundle for $atSign rooted at'
        ' "${held.storagePath}", and was asked for one at'
        ' "${requested.storagePath}". A factory keeps one bundle per atSign —'
        ' bundleFor() and closeFor() have no way to name a second — so it'
        ' cannot serve both. Returning the bundle it holds would answer with'
        ' another store\'s records. Call closeFor("$atSign") first, or use a'
        ' separate factory instance for the second location.');
