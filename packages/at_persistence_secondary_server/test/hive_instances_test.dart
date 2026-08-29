import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
// Deliberately the public barrel, not `src/impl/hive/hive_instances.dart`.
// A consumer outside this package can only reach `HiveInstances` through an
// export, and at_client needs it: importing it here the way they do is what
// keeps the export from being dropped by a tidy-up.
import 'package:at_persistence_secondary_server/hive.dart';
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
    expect(
        (await second.get('shared_key@alice'))?.data, 'written-after-both-open',
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

  test('a symlinked spelling of a path is the same instance as its target',
      () async {
    // `p.canonicalize` is pure string work — it does not follow symlinks, so
    // on its own a link and its target are two instances over one directory:
    // two boxes, drifting in memory, which is exactly the state this class
    // exists to prevent. Not exotic either — `/data -> /mnt/data` is an
    // ordinary deployment, and on macOS `Directory.systemTemp` is
    // `/var/folders/...` whose real path is `/private/var/folders/...`.
    final target = pathFor('link_target');
    final link = '${root.path}/link_alias';
    Link(link).createSync(target);

    final before = HiveInstances.instanceCount;
    final viaTarget = HiveInstances.forPath(target);
    final viaLink = HiveInstances.forPath(link);

    expect(identical(viaTarget, viaLink), isTrue,
        reason: 'a link and its target are one directory, so they must be one '
            'instance — a lexical canonicalisation calls them different and '
            'reopens the hole');
    expect(HiveInstances.instanceCount, before + 1,
        reason: 'two spellings, one instance');
  });

  test('a path is resolved the same way before and after it exists', () async {
    // The reason the directory is created rather than left to appear on its
    // own: an unresolvable path can only be keyed lexically, so a caller
    // arriving before the directory existed and one arriving after would key
    // on two different strings for one directory.
    final target = pathFor('late_target');
    final link = '${root.path}/late_alias';
    Link(link).createSync(target);
    final notYet = '$link/child';

    final before = HiveInstances.instanceCount;
    final first = HiveInstances.forPath(notYet); // creates it
    final second = HiveInstances.forPath('$target/child'); // already there

    expect(Directory(notYet).existsSync(), isTrue,
        reason: 'forPath must create the directory, or it cannot resolve it');
    expect(identical(first, second), isTrue,
        reason: 'the same directory reached before and after it existed, and '
            'by two spellings, is one instance');
    expect(HiveInstances.instanceCount, before + 1);
  });

  test('an instance mid-close is refused rather than handed out or replaced',
      () async {
    // Neither alternative is safe. Handing back the closing instance lets a
    // caller open a box that is about to be closed underneath them; building
    // a fresh one puts two live instances over one directory, which is the
    // silent divergence. Refusing is the only loud option.
    final path = pathFor('closing');
    final store = await storeAt(path);
    await store.put('shared_key@alice', data('v'));

    final closing = HiveInstances.closeFor(path);
    expect(() => HiveInstances.forPath(path), throwsA(isA<StateError>()),
        reason: 'a caller arriving during the close has an ordering bug and '
            'must hear about it, not silently get a second instance over the '
            'same files');

    await closing;
    // The control: once the close has completed the path is usable again, so
    // the refusal above is about the window and not about the path being
    // permanently poisoned.
    expect(HiveInstances.forPath(path), isNotNull);
    await HiveInstances.closeFor(path);
  });

  test('closeAll drops the instances it closed', () async {
    final a = await storeAt(pathFor('close_a'));
    final b = await storeAt(pathFor('close_b'));
    await a.put('shared_key@alice', data('a'));
    await b.put('shared_key@alice', data('b'));

    expect(HiveInstances.instanceCount, greaterThanOrEqualTo(2));
    await HiveInstances.closeAll();
    expect(HiveInstances.instanceCount, 0,
        reason: 'an entry left behind points at a closed instance, and the '
            'next caller for that path would get it back');
  });
}
