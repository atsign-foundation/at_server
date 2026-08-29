import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/dual.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:test/test.dart';

/// One atSign, one factory, two storage locations.
///
/// A factory keeps one bundle per atSign — [AtPersistenceFactory.bundleFor]
/// and [AtPersistenceFactory.closeFor] key on the atSign alone, so there is
/// nowhere for a second to live. It used to hand back the bundle it held
/// without ever reading the config's paths, so the second caller was answered
/// with the first's store. Measured before the fix, with one factory and two
/// directories: the Hive bundle returned `from-a` for the second path, and the
/// SQLite one did too while never creating the second directory at all — the
/// `storagePath` reached nothing whatsoever.
///
/// The remedy is a refusal rather than a second bundle: the interface cannot
/// express two, and a caller reading another store's records has no way to
/// notice.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('factory_paths'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String dir(String name) =>
      (Directory('${root.path}/$name')..createSync(recursive: true)).path;

  HivePersistenceConfig hiveAt(String d) => HivePersistenceConfig(
      storagePath: d,
      commitLogPath: d,
      accessLogPath: d,
      notificationStoragePath: d);

  SqlitePersistenceConfig sqliteAt(String d) =>
      SqlitePersistenceConfig(storagePath: d);

  group('a factory refuses a second storage location for one atSign', () {
    test('hive', () async {
      final factory = HiveAtPersistenceFactory();
      await factory.initialize('@alice', hiveAt(dir('a')));
      await expectLater(() => factory.initialize('@alice', hiveAt(dir('b'))),
          throwsA(isA<StateError>()),
          reason: 'returning the bundle rooted at a/ would answer a caller '
              'that asked for b/ with another store\'s records, and nothing '
              'in the bundle tells them which directory they got');
      await factory.close();
    });

    test('sqlite', () async {
      final factory = SqliteAtPersistenceFactory();
      await factory.initialize('@alice', sqliteAt(dir('a')));
      await expectLater(() => factory.initialize('@alice', sqliteAt(dir('b'))),
          throwsA(isA<StateError>()),
          reason: 'the sqlite factory did not merely answer from the wrong '
              'directory, it never created the second one — the storagePath '
              'reached nothing at all');
      await factory.close();
    });

    test('dual, when only the SECONDARY arm moves', () async {
      // The arm that would slip through a wrapper comparison.
      // DualWritePersistenceConfig delegates every path getter to `primary`,
      // so comparing the wrapper agrees here while the secondary — the arm the
      // whole dual-write comparison exists to populate — has been pointed
      // somewhere else.
      final factory = DualWriteAtPersistenceFactory(
          HiveAtPersistenceFactory(), SqliteAtPersistenceFactory());
      final primary = hiveAt(dir('p'));
      await factory.initialize(
          '@alice',
          DualWritePersistenceConfig(
              primary: primary, secondary: sqliteAt(dir('s1'))));
      await expectLater(
          () => factory.initialize(
              '@alice',
              DualWritePersistenceConfig(
                  primary: primary, secondary: sqliteAt(dir('s2')))),
          throwsA(isA<StateError>()),
          reason: 'the primary is unchanged, so every path getter on the '
              'wrapper agrees; only comparing the arms separately catches a '
              'moved secondary');
      await factory.close();
    });
  });

  group('and does not refuse a caller doing nothing wrong', () {
    test('the identical config returns the same bundle', () async {
      // The control. Without it the refusal above could be a factory that
      // rejects every second call, which would break every existing caller.
      final factory = HiveAtPersistenceFactory();
      final path = dir('same');
      final first = await factory.initialize('@alice', hiveAt(path));
      final second = await factory.initialize('@alice', hiveAt(path));
      expect(identical(first, second), isTrue,
          reason: 'one bundle per atSign is the contract, and two calls with '
              'the same locations must keep getting it');
      await factory.close();
    });

    test('a lexically different spelling of one directory is not a conflict',
        () async {
      final factory = HiveAtPersistenceFactory();
      final path = dir('lexical');
      final first = await factory.initialize('@alice', hiveAt(path));
      final second = await factory.initialize('@alice', hiveAt('$path/./'));
      expect(identical(first, second), isTrue,
          reason: 'foo/bar and foo/./bar are one directory; refusing here '
              'would fail a caller who has done nothing wrong');
      await factory.close();
    });

    test('a symlinked spelling of one directory is not a conflict', () async {
      // Lexical canonicalisation alone calls these two different. macOS hands
      // this case to anyone using Directory.systemTemp, whose real path is
      // under /private/var.
      final factory = HiveAtPersistenceFactory();
      final target = dir('link_target');
      final alias = '${root.path}/link_alias';
      Link(alias).createSync(target);

      final first = await factory.initialize('@alice', hiveAt(target));
      final second = await factory.initialize('@alice', hiveAt(alias));
      expect(identical(first, second), isTrue,
          reason: 'a link and its target are one directory on disk, so this '
              'is the same store reached by another name');
      await factory.close();
    });

    test('after closeFor, a different location is allowed', () async {
      final factory = SqliteAtPersistenceFactory();
      await factory.initialize('@alice', sqliteAt(dir('first')));
      await factory.closeFor('@alice');
      final moved = await factory.initialize('@alice', sqliteAt(dir('second')));
      expect(moved.isClosed, isFalse,
          reason: 'the refusal is about an OPEN bundle; once it is closed the '
              'atSign is free to be built somewhere else');
      await factory.close();
    });

    test('a different atSign at a different location is unaffected', () async {
      final factory = SqliteAtPersistenceFactory();
      final a = await factory.initialize('@alice', sqliteAt(dir('alice')));
      final b = await factory.initialize('@bob', sqliteAt(dir('bob')));
      expect(identical(a, b), isFalse);
      await factory.close();
    });
  });
}
