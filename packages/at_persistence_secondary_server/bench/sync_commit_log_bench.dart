/// Benchmark: cost of a `sync:from` scan over a large commit log, on the
/// Hive backend vs the SQLite backend.
///
/// Motivating scenario: a commit log whose max commitId is ~1e6, in which
/// all but the last entry are DELETEs, and a client syncing from a low
/// watermark with `skipDeletesUntil` set to the max. Exactly one entry
/// survives the filter, but the server must walk the whole log to find it.
///
/// WHAT THIS MEASURES (and what it does not)
///
/// It drives the real `AtCommitLog.iterate` of each backend, with a
/// faithful copy of the `where` predicate from
/// `sync_progressive_verb_handler.dart` (:63-112) and the same
/// stop-at-page-limit drain loop as `prepareResponse` (:145-175).
///
/// Deliberately NOT included, because neither is on the hot path for this
/// scenario and both would drag in the whole secondary server:
///   - `isAuthorizedSync(...)`: with a null enrollmentId (the unauthenticated
///     -enrollment sync case) it returns true without touching the store.
///   - `keyStore.get(...)` for non-DELETE entries: runs once per RETURNED
///     entry, and this scenario returns one. It is not part of the
///     999,999-entry scan cost under study.
/// The regex filter is included but left null, matching a no-regex sync.
///
/// Usage:
///   dart run bench/sync_commit_log_bench.dart [options]
///
///   --entries N     commit log size / max commitId   (default 1000000)
///   --from N        client watermark; scan starts at N+1 (default 1000)
///   --page N        sync page limit, as prepareResponse (default 25)
///   --repeat N      timed repeats per scenario        (default 3)
///   --backend B     hive | sqlite | both             (default both)
///   --keep          do not delete the seeded stores on exit
///   --dir PATH      scratch dir (default: a temp dir, removed on exit)
library;

import 'dart:async';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
// Not exported from hive.dart; the bench needs the concrete type to call
// init(..., isLazy: false) the way HiveAtPersistenceFactory does.
import 'package:at_persistence_secondary_server/src/impl/hive/hive_commit_log_keystore.dart';
import 'package:at_utils/at_logger.dart';

const String benchAtSign = '@bench';

/// The atKey for commit entry [i]. Shaped like a real shared key so the
/// handler's `AtKey.getKeyType` / `AtKey.fromString` validation does the
/// same work it would in production — that validation runs on EVERY
/// candidate entry, before the skipDeletes check, so it is part of the
/// per-entry cost under study.
String benchKey(int i) => '@alice:k$i.bench$benchAtSign';

void main(List<String> argv) async {
  AtSignLogger.root_level = 'severe';

  final opts = _Options.parse(argv);
  _assertKeyShapeIsValid();

  final dir = opts.dir ??
      Directory.systemTemp.createTempSync('sync_bench_').path;
  Directory(dir).createSync(recursive: true);

  stdout.writeln('=== sync commit-log scan bench ===');
  stdout.writeln('entries=${opts.entries}  from=${opts.from}  '
      'page=${opts.page}  repeat=${opts.repeat}  backend=${opts.backend}');
  stdout.writeln('scratch: $dir');
  stdout.writeln('dart: ${Platform.version}');
  stdout.writeln('');

  final results = <_Result>[];

  try {
    if (opts.backend != 'sqlite') {
      results.addAll(await _runHive(dir, opts));
    }
    if (opts.backend != 'hive') {
      results.addAll(await _runSqlite(dir, opts));
    }
  } finally {
    if (!opts.keep && opts.dir == null) {
      try {
        Directory(dir).deleteSync(recursive: true);
      } on FileSystemException catch (e) {
        stderr.writeln('warn: could not clean $dir: $e');
      }
    }
  }

  _report(results, opts);
}

// ---------------------------------------------------------------------------
// Hive
// ---------------------------------------------------------------------------

Future<List<_Result>> _runHive(String scratch, _Options opts) async {
  final path = '$scratch/hive';
  Directory(path).createSync(recursive: true);

  // --- seed ---
  final seedStore = HiveCommitLogKeyStore(benchAtSign);
  final seedWatch = Stopwatch()..start();
  await seedStore.init(path, isLazy: false);
  const batch = 20000;
  var pending = <int, CommitEntry>{};
  for (var id = 1; id <= opts.entries; id++) {
    pending[id] = CommitEntry(benchKey(id), _opFor(id, opts.entries),
        DateTime.now().toUtc())
      ..commitId = id;
    if (pending.length >= batch) {
      await seedStore.getBox().putAll(pending);
      pending = <int, CommitEntry>{};
    }
  }
  if (pending.isNotEmpty) await seedStore.getBox().putAll(pending);
  seedWatch.stop();
  await seedStore.close();
  stdout.writeln('hive   | seeded ${opts.entries} entries in '
      '${seedWatch.elapsedMilliseconds}ms');

  // --- open (this is the real server startup cost for a log this size:
  //     repairCommitLogAndCreateCachedMap walks every entry) ---
  final rssBeforeOpen = ProcessInfo.currentRss;
  final store = HiveCommitLogKeyStore(benchAtSign);
  final openWatch = Stopwatch()..start();
  await store.init(path, isLazy: false);
  openWatch.stop();
  final rssAfterOpen = ProcessInfo.currentRss;
  final log = HiveAtCommitLog(store);

  _assertSeeded(
      'hive', store.entriesCount(), log.lastCommittedSequenceNumber(), opts);

  stdout.writeln('hive   | open+repair: ${openWatch.elapsedMilliseconds}ms  '
      'resident after open: ${_mb(rssAfterOpen)} '
      '(+${_mb(rssAfterOpen - rssBeforeOpen)} for the box)');

  final out = <_Result>[];
  out.add(_Result.startup('hive', openWatch.elapsedMilliseconds,
      rssAfterOpen - rssBeforeOpen));

  for (final probe in [false, true]) {
    out.add(await _timeScenario(
      backend: 'hive',
      scenario: 'skipDeletes',
      probeEventLoop: probe,
      opts: opts,
      scan: () => _drain(
          log.iterate(
              fromCommitId: opts.from + 1,
              where: _whereFilter(
                  skipDeletesUntil: opts.entries,
                  latestCommitId: log.lastCommittedSequenceNumber())),
          opts.page),
    ));
  }
  out.add(await _timeScenario(
    backend: 'hive',
    scenario: 'reordered',
    probeEventLoop: true,
    opts: opts,
    scan: () => _drain(
        log.iterate(
            fromCommitId: opts.from + 1,
            where: _reorderedFilter(
                skipDeletesUntil: opts.entries,
                latestCommitId: log.lastCommittedSequenceNumber())),
        opts.page),
  ));
  // Attribution: same full scan, but the predicate does no AtKey parsing.
  // (skipDeletes - storeOnly) = the cost of the handler's per-entry key
  // validation; storeOnly = the cost the persistence layer actually owns.
  // The shipped path after all fixes: reordered filter AND the pushdown
  // hint, exactly as sync_progressive_verb_handler now calls it.
  out.add(await _timeScenario(
    backend: 'hive',
    scenario: 'shipped',
    probeEventLoop: true,
    opts: opts,
    scan: () => _drain(
        log.iterate(
            fromCommitId: opts.from + 1,
            where: _reorderedFilter(
                skipDeletesUntil: opts.entries,
                latestCommitId: log.lastCommittedSequenceNumber()),
            skipDeletesUntil: opts.entries),
        opts.page),
  ));
  out.add(await _timeScenario(
    backend: 'hive',
    scenario: 'storeOnly',
    probeEventLoop: false,
    opts: opts,
    scan: () => _drain(
        log.iterate(fromCommitId: opts.from + 1, where: _countOnlyFilter),
        opts.page),
  ));
  out.add(await _timeScenario(
    backend: 'hive',
    scenario: 'noSkipDeletes',
    probeEventLoop: false,
    opts: opts,
    scan: () => _drain(
        log.iterate(
            fromCommitId: opts.from + 1,
            where: _whereFilter(
                skipDeletesUntil: null,
                latestCommitId: log.lastCommittedSequenceNumber())),
        opts.page),
  ));

  await store.close();
  return out;
}

// ---------------------------------------------------------------------------
// SQLite
// ---------------------------------------------------------------------------

Future<List<_Result>> _runSqlite(String scratch, _Options opts) async {
  final dbPath = '$scratch/sqlite/atsign.db';
  final rssBeforeOpen = ProcessInfo.currentRss;
  final db = SqliteDatabase.open(benchAtSign, dbPath);

  // --- seed: one transaction, one prepared statement. Produces rows byte-
  //     identical to commitSync()'s, without 1e6 separate transactions. ---
  final seedWatch = Stopwatch()..start();
  db.raw.execute('BEGIN;');
  final stmt = db.raw.prepare(
      'INSERT INTO commit_log (atkey, commit_id, operation, op_time) '
      'VALUES (?, ?, ?, ?);');
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  for (var id = 1; id <= opts.entries; id++) {
    stmt.execute([benchKey(id), id, _opFor(id, opts.entries).name, now]);
  }
  stmt.dispose();
  db.raw.execute('COMMIT;');
  db.raw.execute(
      "UPDATE counters SET value = ? WHERE name = 'last_commit_id';",
      [opts.entries]);
  seedWatch.stop();

  final log = SqliteAtCommitLog(db);
  final rssAfterOpen = ProcessInfo.currentRss;
  _assertSeeded(
      'sqlite', log.entriesCount(), log.lastCommittedSequenceNumber(), opts);

  // NB: not log.getSize() — SqliteAtCommitLog.getSize() returns bytes while
  // the spec (and HiveBase.getSize) returns KB, so it over-reports 1024x.
  stdout.writeln('sqlite | seeded ${opts.entries} entries in '
      '${seedWatch.elapsedMilliseconds}ms  '
      '(db file ${_mb(_dbBytes(dbPath))}, resident ${_mb(rssAfterOpen)})');

  final out = <_Result>[];
  out.add(_Result.startup('sqlite', 0, rssAfterOpen - rssBeforeOpen));

  for (final probe in [false, true]) {
    out.add(await _timeScenario(
      backend: 'sqlite',
      scenario: 'skipDeletes',
      probeEventLoop: probe,
      opts: opts,
      scan: () => _drain(
          log.iterate(
              fromCommitId: opts.from + 1,
              where: _whereFilter(
                  skipDeletesUntil: opts.entries,
                  latestCommitId: log.lastCommittedSequenceNumber())),
          opts.page),
    ));
  }
  out.add(await _timeScenario(
    backend: 'sqlite',
    scenario: 'reordered',
    probeEventLoop: true,
    opts: opts,
    scan: () => _drain(
        log.iterate(
            fromCommitId: opts.from + 1,
            where: _reorderedFilter(
                skipDeletesUntil: opts.entries,
                latestCommitId: log.lastCommittedSequenceNumber())),
        opts.page),
  ));
  // Trunk's strategy: push skip-deletes into the query as a
  // `NOT (operation = '-' ...)` filter over an EAGER select. Correct, and it
  // stops the deletes being materialised into Dart -- but the plan is
  // `SEARCH ... commit_log_commit_id (commit_id>?)`, a full walk of the log
  // in SQLite's C layer, and select() still materialises the surviving rows.
  // This replicates SqliteAtCommitLog.iterate as it stands on trunk.
  out.add(await _timeScenario(
    backend: 'sqlite:trunk',
    scenario: 'skipDeletes',
    probeEventLoop: true,
    opts: opts,
    scan: () async {
      final latest = log.lastCommittedSequenceNumber();
      final rows = db.raw.select(
          'SELECT atkey, commit_id, operation, op_time FROM commit_log '
          'WHERE commit_id >= ? AND NOT (operation = ? AND commit_id IS NOT NULL '
          'AND commit_id <= ? AND commit_id <> ?) ORDER BY commit_id;',
          [opts.from + 1, '-', opts.entries, latest ?? -1]);
      final filter = _reorderedFilter(
          skipDeletesUntil: opts.entries, latestCommitId: latest);
      var visited = 0, returned = 0;
      for (final row in rows) {
        visited++;
        final op = (row['operation'] as String) == '-'
            ? CommitOp.DELETE
            : CommitOp.UPDATE;
        final entry = CommitEntry(row['atkey'] as String, op, null)
          ..commitId = row['commit_id'] as int?;
        if (filter(entry)) {
          returned++;
          if (returned >= opts.page) break;
        }
      }
      return _ScanOutcome(visited, returned);
    },
  ));
  // This branch's strategy: the same policy via iterate(skipDeletesUntil:),
  // which now seeks the partial index instead of walking the log.
  out.add(await _timeScenario(
    backend: 'sqlite:partial-idx',
    scenario: 'skipDeletes',
    probeEventLoop: true,
    opts: opts,
    scan: () => _drain(
        log.iterate(
            fromCommitId: opts.from + 1,
            where: _reorderedFilter(
                skipDeletesUntil: opts.entries,
                latestCommitId: log.lastCommittedSequenceNumber()),
            skipDeletesUntil: opts.entries,
            latestCommitId: log.lastCommittedSequenceNumber()),
        opts.page),
  ));
  out.add(await _timeScenario(
    backend: 'sqlite',
    scenario: 'storeOnly',
    probeEventLoop: false,
    opts: opts,
    scan: () => _drain(
        log.iterate(fromCommitId: opts.from + 1, where: _countOnlyFilter),
        opts.page),
  ));
  out.add(await _timeScenario(
    backend: 'sqlite',
    scenario: 'noSkipDeletes',
    probeEventLoop: false,
    opts: opts,
    scan: () => _drain(
        log.iterate(
            fromCommitId: opts.from + 1,
            where: _whereFilter(
                skipDeletesUntil: null,
                latestCommitId: log.lastCommittedSequenceNumber())),
        opts.page),
  ));

  // --- the proposed ceiling: push skipDeletes + LIMIT into SQL, backed by
  //     a partial index over non-DELETE rows. Measures what the backend
  //     COULD do if AtCommitLog.iterate carried the hints. Not a proposal
  //     to hand-roll SQL in the handler. ---
  // commit_log_live is now created by SqliteSchema.apply on every open, so
  // there is nothing to build here -- just confirm it is present.
  final indexes = db.raw
      .select("SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND tbl_name = 'commit_log';")
      .map((r) => r['name'] as String)
      .toSet();
  if (!indexes.contains('commit_log_live')) {
    throw StateError('schema did not create commit_log_live; found $indexes');
  }

  // Instrument integrity: a "pushdown" that silently falls back to a full
  // index scan would report a plausible-looking number that means nothing.
  // Assert the planner actually uses the partial index before timing it.
  final plan = db.raw
      .select('EXPLAIN QUERY PLAN '
          'SELECT atkey, commit_id, operation, op_time FROM commit_log '
          "WHERE commit_id >= ? AND operation <> '-' "
          'ORDER BY commit_id LIMIT ?;', [opts.from + 1, opts.page])
      .map((r) => r['detail'] as String)
      .join(' | ');
  if (!plan.contains('commit_log_live')) {
    throw StateError('pushdown query does not use commit_log_live; '
        'plan was: $plan');
  }
  stdout.writeln('sqlite | pushdown plan: $plan');

  out.add(await _timeScenario(
    backend: 'sqlite+pushdown',
    scenario: 'skipDeletes',
    probeEventLoop: false,
    opts: opts,
    scan: () async {
      // Two index seeks, not one scan. An earlier version expressed the
      // "always include the latest entry" exception as an OR inside this
      // query -- which defeats the partial index entirely (the planner
      // falls back to commit_log_commit_id and walks all 999k rows, which
      // is what made this row read 238ms while reporting visited=1).
      // EXPLAIN QUERY PLAN is asserted below so that cannot recur silently.
      final rows = db.raw.select(
          'SELECT atkey, commit_id, operation, op_time FROM commit_log '
          "WHERE commit_id >= ? AND operation <> '-' "
          'ORDER BY commit_id LIMIT ?;',
          [opts.from + 1, opts.page]);
      // The latest entry is included even when it is a DELETE, so the
      // client can advance its watermark. A point lookup on the unique
      // commit_id index, not a scan.
      db.raw.select(
          'SELECT atkey, commit_id, operation, op_time FROM commit_log '
          'WHERE commit_id = ?;',
          [opts.entries]);
      var visited = 0, returned = 0;
      for (final row in rows) {
        visited++;
        // The Dart-side filter still runs (key validation, regex, authz);
        // it just no longer sees the rejected deletes.
        final entry = CommitEntry(row['atkey'] as String, CommitOp.DELETE, null)
          ..commitId = row['commit_id'] as int?;
        if (_whereFilter(skipDeletesUntil: null, latestCommitId: null)(entry)) {
          returned++;
        }
      }
      return _ScanOutcome(visited, returned);
    },
  ));

  db.close();
  return out;
}

// ---------------------------------------------------------------------------
// The filter and drain loop under study
// ---------------------------------------------------------------------------

/// Faithful copy of `whereFilter` from sync_progressive_verb_handler.dart
/// :63-112, minus the enrollment check (see the file-level note). Counts
/// every entry it inspects so the bench can report scan depth.
int _entriesInspected = 0;

/// The same predicate as [_whereFilter], with the cheap skipDeletes test
/// hoisted ABOVE the expensive `AtKey.getKeyType` / `AtKey.fromString`
/// validation.
///
/// Semantically identical for this decision: an entry rejected by
/// skipDeletes and an entry rejected by key validation both return false.
/// The only observable difference is that a skipped DELETE no longer emits
/// the "invalid key in the commit log" warning — a logging change, not a
/// behavioural one. Measured here so the reorder is a benchmarked
/// proposal rather than an asserted one.
bool Function(CommitEntry) _reorderedFilter({
  required int? skipDeletesUntil,
  required int? latestCommitId,
  String? regex,
}) {
  return (CommitEntry entry) {
    _entriesInspected++;
    final atKey = entry.atKey;
    if (atKey == null) return false;

    if (skipDeletesUntil != null &&
        entry.operation == CommitOp.DELETE &&
        entry.commitId != null &&
        entry.commitId! <= skipDeletesUntil &&
        entry.commitId != latestCommitId) {
      return false;
    }

    if (AtKey.getKeyType(atKey, enforceNameSpace: false) ==
        KeyType.invalidKey) {
      return false;
    }
    try {
      AtKey.fromString(atKey);
    } on InvalidSyntaxException catch (_) {
      return false;
    }

    if (regex != null && regex.isNotEmpty && !RegExp(regex).hasMatch(atKey)) {
      return false;
    }

    return true;
  };
}

/// Rejects everything without parsing the atKey, so the resulting time is
/// the store's own iteration cost (seek + row/entry materialization) with
/// the handler's validation cost removed.
bool _countOnlyFilter(CommitEntry entry) {
  _entriesInspected++;
  return false;
}

bool Function(CommitEntry) _whereFilter({
  required int? skipDeletesUntil,
  required int? latestCommitId,
  String? regex,
}) {
  return (CommitEntry entry) {
    _entriesInspected++;
    final atKey = entry.atKey;
    if (atKey == null) return false;

    if (AtKey.getKeyType(atKey, enforceNameSpace: false) ==
        KeyType.invalidKey) {
      return false;
    }
    try {
      AtKey.fromString(atKey);
    } on InvalidSyntaxException catch (_) {
      return false;
    }

    if (skipDeletesUntil != null &&
        entry.operation == CommitOp.DELETE &&
        entry.commitId != null &&
        entry.commitId! <= skipDeletesUntil &&
        entry.commitId != latestCommitId) {
      return false;
    }

    if (regex != null &&
        regex.isNotEmpty &&
        !RegExp(regex).hasMatch(atKey)) {
      return false;
    }

    return true;
  };
}

/// Mirrors the stop condition of `prepareResponse` (:153): drain the
/// stream, stop once [pageLimit] entries have been accepted. The stream
/// is unbounded by design, so a filter that rejects everything runs it to
/// completion.
Future<_ScanOutcome> _drain(Stream<CommitEntry> stream, int pageLimit) async {
  var returned = 0;
  await for (final _ in stream) {
    if (returned >= pageLimit) break;
    returned++;
  }
  return _ScanOutcome(-1, returned); // visited filled in by the caller
}

class _ScanOutcome {
  final int visited;
  final int returned;
  _ScanOutcome(this.visited, this.returned);
}

// ---------------------------------------------------------------------------
// Timing + event-loop starvation probe
// ---------------------------------------------------------------------------

Future<_Result> _timeScenario({
  required String backend,
  required String scenario,
  required bool probeEventLoop,
  required _Options opts,
  required Future<_ScanOutcome> Function() scan,
}) async {
  final samples = <int>[];
  var maxStallMicros = 0;
  var visited = 0, returned = 0;
  var peakRss = 0;

  for (var i = 0; i < opts.repeat; i++) {
    _entriesInspected = 0;

    Timer? probe;
    var lastTick = Stopwatch()..start();
    if (probeEventLoop) {
      // If the scan starves the event loop, this 1ms timer cannot fire and
      // the gap we observe is the length of the stall.
      probe = Timer.periodic(const Duration(milliseconds: 1), (_) {
        final gap = lastTick.elapsedMicroseconds;
        if (gap > maxStallMicros) maxStallMicros = gap;
        lastTick = Stopwatch()..start();
      });
      // Let the timer establish a baseline before the scan starts.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      maxStallMicros = 0;
      lastTick = Stopwatch()..start();
    }

    final watch = Stopwatch()..start();
    final outcome = await scan();
    watch.stop();
    if (probe != null) {
      // The probe cannot observe the stall it exists to detect unless the
      // event loop gets a turn before we cancel: a starving scan resumes
      // via a microtask, so an immediate cancel() kills the pending timer
      // event before it is ever delivered. (First version of this bench
      // reported max-stall 0.00ms for an 85ms blocking scan for exactly
      // that reason.) Yield, let it fire once, then cancel.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      probe.cancel();
    }

    final rss = ProcessInfo.currentRss;
    if (rss > peakRss) peakRss = rss;
    samples.add(watch.elapsedMicroseconds);
    visited = outcome.visited >= 0 ? outcome.visited : _entriesInspected;
    returned = outcome.returned;
  }

  samples.sort();
  return _Result(
    backend: backend,
    scenario: scenario,
    probed: probeEventLoop,
    medianMicros: samples[samples.length ~/ 2],
    minMicros: samples.first,
    maxMicros: samples.last,
    visited: visited,
    returned: returned,
    maxStallMicros: probeEventLoop ? maxStallMicros : -1,
    peakRss: peakRss,
  );
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

class _Result {
  final String backend;
  final String scenario;
  final bool probed;
  final int medianMicros, minMicros, maxMicros;
  final int visited, returned, maxStallMicros, peakRss;
  final bool isStartup;
  final int startupRssDelta;

  _Result({
    required this.backend,
    required this.scenario,
    required this.probed,
    required this.medianMicros,
    required this.minMicros,
    required this.maxMicros,
    required this.visited,
    required this.returned,
    required this.maxStallMicros,
    required this.peakRss,
  })  : isStartup = false,
        startupRssDelta = 0;

  _Result.startup(this.backend, int millis, this.startupRssDelta)
      : scenario = 'open+repair',
        probed = false,
        medianMicros = millis * 1000,
        minMicros = millis * 1000,
        maxMicros = millis * 1000,
        visited = 0,
        returned = 0,
        maxStallMicros = -1,
        peakRss = 0,
        isStartup = true;
}

void _report(List<_Result> results, _Options opts) {
  stdout.writeln('');
  stdout.writeln('backend          scenario       probe  median      min         '
      'max         visited    ret  max-stall   peak-rss');
  stdout.writeln('-' * 118);
  for (final r in results) {
    if (r.isStartup) {
      stdout.writeln('${r.backend.padRight(16)} ${r.scenario.padRight(14)} '
          '${'-'.padRight(6)} ${_ms(r.medianMicros).padRight(11)} '
          '${''.padRight(11)} ${''.padRight(11)} ${''.padRight(10)} '
          '${''.padRight(4)} ${''.padRight(11)} '
          '+${_mb(r.startupRssDelta)}');
      continue;
    }
    stdout.writeln('${r.backend.padRight(16)} ${r.scenario.padRight(14)} '
        '${(r.probed ? 'yes' : 'no').padRight(6)} '
        '${_ms(r.medianMicros).padRight(11)} ${_ms(r.minMicros).padRight(11)} '
        '${_ms(r.maxMicros).padRight(11)} '
        '${r.visited.toString().padRight(10)} '
        '${r.returned.toString().padRight(4)} '
        '${(r.maxStallMicros < 0 ? '-' : _ms(r.maxStallMicros)).padRight(11)} '
        '${_mb(r.peakRss)}');
  }
  stdout.writeln('');
  stdout.writeln('probe=yes runs carry a 1ms Timer to detect event-loop '
      'starvation; compare their median against the');
  stdout.writeln('probe=no run of the same row to confirm the instrument is '
      'not distorting the measurement.');
}

/// Size of the db plus its WAL, in bytes.
int _dbBytes(String path) {
  var total = 0;
  for (final suffix in ['', '-wal']) {
    final f = File('$path$suffix');
    if (f.existsSync()) total += f.lengthSync();
  }
  return total;
}

String _ms(int micros) => '${(micros / 1000).toStringAsFixed(2)}ms';
String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';

// ---------------------------------------------------------------------------
// Setup helpers
// ---------------------------------------------------------------------------

/// All entries are DELETE except the last, which is the single entry the
/// skipDeletes scan is hunting for.
CommitOp _opFor(int id, int total) =>
    id == total ? CommitOp.UPDATE : CommitOp.DELETE;

/// Fail loudly if the synthetic key shape would be rejected by the very
/// filter under test — otherwise the bench would "measure" a scan that
/// rejects every entry for the wrong reason.
void _assertKeyShapeIsValid() {
  final sample = benchKey(42);
  if (AtKey.getKeyType(sample, enforceNameSpace: false) ==
      KeyType.invalidKey) {
    throw StateError('bench key shape "$sample" is an invalid atKey');
  }
  AtKey.fromString(sample);
}

void _assertSeeded(String backend, int count, int? latest, _Options opts) {
  if (count != opts.entries) {
    throw StateError(
        '$backend: expected ${opts.entries} entries, store reports $count');
  }
  if (latest != opts.entries) {
    throw StateError(
        '$backend: expected latest commitId ${opts.entries}, got $latest');
  }
}

class _Options {
  final int entries, from, page, repeat;
  final String backend;
  final bool keep;
  final String? dir;

  _Options(this.entries, this.from, this.page, this.repeat, this.backend,
      this.keep, this.dir);

  static _Options parse(List<String> argv) {
    int intArg(String name, int fallback) {
      final i = argv.indexOf('--$name');
      if (i < 0) return fallback;
      if (i + 1 >= argv.length) throw ArgumentError('--$name needs a value');
      return int.parse(argv[i + 1]);
    }

    String? strArg(String name) {
      final i = argv.indexOf('--$name');
      if (i < 0) return null;
      if (i + 1 >= argv.length) throw ArgumentError('--$name needs a value');
      return argv[i + 1];
    }

    final backend = strArg('backend') ?? 'both';
    if (!['hive', 'sqlite', 'both'].contains(backend)) {
      throw ArgumentError('--backend must be hive|sqlite|both');
    }
    return _Options(
      intArg('entries', 1000000),
      intArg('from', 1000),
      intArg('page', 25),
      intArg('repeat', 3),
      backend,
      argv.contains('--keep'),
      strArg('dir'),
    );
  }
}
