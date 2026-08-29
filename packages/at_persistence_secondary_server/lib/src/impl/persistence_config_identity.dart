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
/// [AtPersistenceConfig.backendMarkerPath] is deliberately NOT among them.
/// Both config classes derive it from [AtPersistenceConfig.storagePath] when it
/// is not given, and nothing in the server ever gives it, so it carries no
/// information `storagePath` has not already supplied. It is also a FILE, and
/// one that does not exist until a backend has been chosen — so including it
/// could only ever manufacture a refusal between two configs that name the same
/// directories, which is what it did when it was first written in.
List<String> storageLocationsOf(AtPersistenceConfig config) => [
      config.storagePath,
      config.commitLogPath,
      config.accessLogPath,
      config.notificationStoragePath,
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
  final resolvedA = _resolved(a);
  final resolvedB = _resolved(b);
  // Both must resolve, and this must not be written as
  // `_resolved(a) == _resolved(b)`: that reads correctly and FAILS OPEN,
  // because two paths that are merely absent both resolve to null and null
  // equals null. Two locations that have already disagreed lexically are the
  // same place only if the filesystem says so, and it cannot say anything
  // about a path that is not there.
  if (resolvedA == null || resolvedB == null) {
    return false;
  }
  return resolvedA == resolvedB;
}

/// The real location of [path], or null when it cannot be resolved.
///
/// Null means "the filesystem cannot answer", and every caller must treat that
/// as *not equal* rather than letting two nulls meet.
///
/// Typed by existence rather than as a [Directory], so that a location which
/// is not a directory still resolves rather than silently reporting itself
/// unresolvable — `Directory(aFile).existsSync()` is false for a file that is
/// plainly there.
String? _resolved(String path) {
  try {
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
      return null;
    }
    return p.canonicalize(File(path).resolveSymbolicLinksSync());
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
    StateError('$factory already holds an open bundle for $atSign at'
        ' ${_describeDifference(held, requested)}.'
        ' A factory keeps one bundle per atSign —'
        ' bundleFor() and closeFor() have no way to name a second — so it'
        ' cannot serve both. Returning the bundle it holds would answer with'
        ' another store\'s records. Call closeFor("$atSign") first, or use a'
        ' separate factory instance for the second location.');

/// Names the locations that actually differ, rather than `storagePath`.
///
/// Reporting `storagePath` alone produces a refusal that reads "rooted at X,
/// and was asked for one at X" whenever the difference is in one of the other
/// four paths — and always for the dual-write config, whose every path getter
/// delegates to its primary. A message that appears to contradict itself sends
/// the reader after the check rather than after the difference.
String _describeDifference(
    AtPersistenceConfig held, AtPersistenceConfig requested) {
  const labels = [
    'storagePath',
    'commitLogPath',
    'accessLogPath',
    'notificationStoragePath',
  ];
  final left = storageLocationsOf(held);
  final right = storageLocationsOf(requested);
  final differences = <String>[];
  for (var i = 0; i < left.length; i++) {
    if (!_sameLocation(left[i], right[i])) {
      differences.add('${labels[i]} "${left[i]}" vs "${right[i]}"');
    }
  }
  if (differences.isEmpty) {
    return '"${held.storagePath}", and was asked for one at'
        ' "${requested.storagePath}"';
  }
  return 'a different ${differences.join('; ')}';
}
