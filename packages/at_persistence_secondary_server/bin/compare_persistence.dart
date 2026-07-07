import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:path/path.dart' as p;

/// Compares two persistence "DB sets" (backend + storage root) for one atSign
/// and reports every inconsistency across all four stores (keystore, commit
/// log, access log, notifications).
///
/// Exit codes:
///   0  the two sets are byte-identical (under the canonical snapshot)
///   1  differences were found (each printed)
///   2  usage / runtime error
///
/// Usage:
///   # hive vs sqlite under the same storage root (e.g. after a dual-write run):
///   dart bin/compare_persistence.dart --atsign @alice --root storage
///
///   # two explicit sets:
///   dart bin/compare_persistence.dart --atsign @alice \
///     --a-backend hive   --a-root /data/before \
///     --b-backend sqlite --b-root /data/after  [--max N]
Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  if (opts == null) {
    _usage();
    exit(2);
  }

  final aFactory = _factoryFor(opts.aBackend);
  final bFactory = _factoryFor(opts.bBackend);
  try {
    final aBundle = await aFactory.initialize(
        opts.atSign, _configFor(opts.aBackend, opts.aRoot));
    final bBundle = await bFactory.initialize(
        opts.atSign, _configFor(opts.bBackend, opts.bRoot));

    final aSnap = await PersistenceSnapshot.capture(aBundle);
    final bSnap = await PersistenceSnapshot.capture(bBundle);

    stdout.writeln('A = ${opts.aBackend}@${opts.aRoot}  counts=${aSnap.counts}');
    stdout.writeln('B = ${opts.bBackend}@${opts.bRoot}  counts=${bSnap.counts}');

    final diffs = aSnap.differencesFrom(bSnap);
    if (diffs.isEmpty) {
      stdout.writeln('IDENTICAL — the two DB sets match for ${opts.atSign}.');
      exit(0);
    }

    stdout.writeln('DIFFERENCES: ${diffs.length} found for ${opts.atSign}');
    final shown = diffs.take(opts.max).toList();
    for (final d in shown) {
      stdout.writeln('  - $d');
    }
    if (diffs.length > shown.length) {
      stdout.writeln('  ... and ${diffs.length - shown.length} more '
          '(raise --max to see them all)');
    }
    exit(1);
  } catch (e, st) {
    stderr.writeln('ERROR: $e\n$st');
    exit(2);
  } finally {
    await aFactory.close();
    await bFactory.close();
  }
}

AtPersistenceFactory _factoryFor(String backend) => backend == 'sqlite'
    ? SqliteAtPersistenceFactory()
    : HiveAtPersistenceFactory();

AtPersistenceConfig _configFor(String backend, String root) =>
    backend == 'sqlite'
        ? SqlitePersistenceConfig.serverDefaults(
            storagePath: p.join(root, 'sqlite'))
        : HivePersistenceConfig.serverDefaults(
            storagePath: p.join(root, 'hive'),
            commitLogPath: p.join(root, 'commitLog'),
            accessLogPath: p.join(root, 'accessLog'),
            notificationStoragePath: p.join(root, 'notificationLog.v1'),
          );

class _Opts {
  final String atSign;
  final String aBackend, aRoot, bBackend, bRoot;
  final int max;
  _Opts(this.atSign, this.aBackend, this.aRoot, this.bBackend, this.bRoot,
      this.max);
}

_Opts? _parseArgs(List<String> args) {
  String? atSign, root, aBackend, aRoot, bBackend, bRoot;
  var max = 100;
  String? next(int i) => i < args.length ? args[i] : null;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--atsign':
        atSign = next(++i);
      case '--root':
        root = next(++i);
      case '--a-backend':
        aBackend = next(++i);
      case '--a-root':
        aRoot = next(++i);
      case '--b-backend':
        bBackend = next(++i);
      case '--b-root':
        bRoot = next(++i);
      case '--max':
        max = int.tryParse(next(++i) ?? '') ?? max;
      case '-h':
      case '--help':
        return null;
    }
  }
  if (atSign == null) return null;
  // Convenience mode: --root compares hive vs sqlite under one root.
  if (root != null) {
    aBackend ??= 'hive';
    aRoot ??= root;
    bBackend ??= 'sqlite';
    bRoot ??= root;
  }
  if (aBackend == null || aRoot == null || bBackend == null || bRoot == null) {
    return null;
  }
  if (!_valid(aBackend) || !_valid(bBackend)) return null;
  return _Opts(atSign, aBackend, aRoot, bBackend, bRoot, max);
}

bool _valid(String b) => b == 'hive' || b == 'sqlite';

void _usage() {
  stderr.writeln('''
Compare two persistence DB sets for one atSign.

Usage:
  compare_persistence.dart --atsign @alice --root <dir>
  compare_persistence.dart --atsign @alice \\
    --a-backend hive --a-root <dir> --b-backend sqlite --b-root <dir> [--max N]

Backends: hive | sqlite
Exit: 0 identical, 1 differences, 2 error''');
}
