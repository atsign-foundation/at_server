import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/impl/hive/hive_at_keyvalue_store.dart';
import 'package:at_persistence_secondary_server/src/impl/hive/hive_instances.dart';
import 'package:test/test.dart';

/// Two stores for one atSign, in one process, at different storage paths.
///
/// A Hive box's identity is `(instance registry, box name)`, and box names in
/// this package derive from the atSign alone. Everything here used to run
/// through the package-global `Hive`, so two stores for one atSign were always
/// one box however different the paths they were given: the second attached to
/// the first's, and its own `storagePath` reached nothing but the
/// encryption-secret file beside it.
///
/// The failure that made it visible was not an error. It was a client reading
/// its own stale value after a sibling had written — no exception, no log, and
/// each side internally consistent.
void main() {
  const atSign = '@alice';
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('hive_instances'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String pathFor(String name) =>
      (Directory('${root.path}/$name')..createSync(recursive: true)).path;

  Future<HiveAtKeyValueStore> storeAt(String path) async {
    final store = HiveAtKeyValueStore(atSign);
    await store.init(path);
    return store;
  }

  AtData data(String v) => AtData()..data = v;

  test('two stores for one atSign at different paths do not share a box',
      () async {
    final a = await storeAt(pathFor('a'));
    final b = await storeAt(pathFor('b'));

    await a.put('shared_key@alice', data('written-by-a'));

    // The claim. Before this change b resolved to a's box and read
    // 'written-by-a' — with nothing to indicate the path it asked for had
    // been ignored.
    expect(await b.exists('shared_key@alice'), isFalse,
        reason: 'these stores were given different storage paths, so a write '
            'through one must not be visible through the other. Sharing here '
            'is not a tidiness problem: the two boxes drift silently, each '
            'side internally consistent, and neither can tell');

    // The control, and it is what stops the assertion above passing for the
    // wrong reason: if `b` could see nothing at all — a broken store, a wrong
    // key name — the expectation would hold just as well.
    await b.put('shared_key@alice', data('written-by-b'));
    expect((await b.get('shared_key@alice'))?.data, 'written-by-b',
        reason: 'b must be a working store, or its not-seeing-a proves '
            'nothing');
    expect((await a.get('shared_key@alice'))?.data, 'written-by-a',
        reason: 'and a keeps its own value — the separation holds in both '
            'directions, not just the one the write happened to go');

    await a.close();
    await b.close();
  });

  test('a store re-opened at the SAME path sees what was written there',
      () async {
    // The other half of the rule, and the one that makes this change safe for
    // every existing deployment: same path resolves to the same instance and
    // the same box, exactly as before. Without this the fix would "pass" by
    // isolating everything from everything.
    final path = pathFor('same');
    final first = await storeAt(path);
    await first.put('shared_key@alice', data('written-once'));

    final second = await storeAt(path);
    expect((await second.get('shared_key@alice'))?.data, 'written-once',
        reason: 'callers passing one path must keep one store — that is what '
            'every deployment does today, and nothing about it may move');

    // ⚠️ The assertion above is NOT sufficient on its own, and a mutation
    // proved it: give every store its own instance and this still passes,
    // because a fresh instance reads the same files from disk and picks up
    // anything written before it opened. Only a write made AFTER both are
    // open separates one shared box from two boxes over one directory — and
    // two boxes over one directory is the dangerous state, because they drift
    // in memory with no error on either side.
    await first.put('shared_key@alice', data('written-after-both-open'));
    expect((await second.get('shared_key@alice'))?.data,
        'written-after-both-open',
        reason: 'one path must mean one box, not two boxes over one set of '
            'files. Two would each stay internally consistent while telling '
            'their callers different things, which is the failure this whole '
            'change exists to make impossible');

    await first.close();
  });

  test('one instance per path, and two spellings of a path are one instance',
      () async {
    final path = pathFor('canon');
    final before = HiveInstances.instanceCount;

    final direct = HiveInstances.forPath(path);
    final viaDot = HiveInstances.forPath('$path/.');
    final viaParent = HiveInstances.forPath('$path/sub/..');

    expect(identical(direct, viaDot), isTrue);
    expect(identical(direct, viaParent), isTrue,
        reason: 'a string comparison would make these separate instances over '
            'the same files, reintroducing the divergence this exists to '
            'prevent');
    expect(HiveInstances.instanceCount, before + 1,
        reason: 'three spellings, one instance');
  });
}
