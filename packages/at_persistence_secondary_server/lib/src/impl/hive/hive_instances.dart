import 'dart:io';

import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';
// `HiveImpl` is not exported from `package:hive/hive.dart` — the library
// declares `final HiveInterface Hive = HiveImpl();` and exposes only that one
// instance — so there is no supported way to construct a second one. If a
// future hive moves or renames the class this import is what breaks, loudly
// and at compile time.
// ignore: implementation_imports
import 'package:hive/src/hive_impl.dart';
import 'package:path/path.dart' as p;

/// One Hive instance per storage path.
///
/// **Why this exists.** A Hive box's identity is `(instance registry, box
/// name)`. Both the registry and the home path are *instance* fields of
/// `HiveImpl` — `package:hive` merely exposes one global instance
/// (`final HiveInterface Hive = HiveImpl();`), and everything in this package
/// used to run through it. So the path a store was given reached
/// `Hive.init(...)`, a process-wide setting that the next store overwrote, and
/// the box itself was opened by name alone.
///
/// Box names here derive from the atSign, so two stores for one atSign in one
/// process always collided however different the paths they were handed: the
/// second silently attached to the first's box, and its own `storagePath`
/// reached nothing but the encryption-secret file beside it.
///
/// **Why the instance is shared per path rather than created per store.** Two
/// instances over one directory do not throw and do not lock each other out.
/// They open two independent boxes over the same files, whose in-memory views
/// then diverge silently — measured: after writing through the second, the
/// first still read its own older value. Sharing by path is what keeps
/// same-path callers on exactly one box, which is what they have always had.
///
/// **What this changes for an existing deployment: nothing.** A process whose
/// stores all use one path resolves to one instance and opens the same box
/// files under the same names. No box is renamed and no data moves. Only a
/// caller that asks for a *different* path sees a difference — it now gets the
/// separate store it asked for.
class HiveInstances {
  HiveInstances._();

  static final AtSignLogger _logger = AtSignLogger('HiveInstances');

  static final Map<String, HiveInterface> _byPath = <String, HiveInterface>{};

  /// Paths whose instance is being closed right now, and the close in flight.
  ///
  /// A close is not instantaneous — it awaits every open box — and for that
  /// window the instance is neither usable nor gone. Handing it out would let
  /// a caller open a box that is about to be closed underneath them; building
  /// a replacement instead would put two instances over one directory, which
  /// is the silent divergence this whole class exists to prevent. [forPath]
  /// refuses instead, and says what to await.
  static final Map<String, Future<void>> _closing = <String, Future<void>>{};

  /// The instance owning [storagePath], created on first use.
  ///
  /// Throws a [StateError] if that path's instance is mid-close — see
  /// [_closing]. Closing storage is a quiescent-point operation, so a caller
  /// reaching this has a genuine ordering bug and wants to hear about it.
  static HiveInterface forPath(String storagePath) {
    final key = canonicalPathFor(storagePath);
    if (_closing.containsKey(key)) {
      throw StateError('The Hive instance for "$key" is being closed. Await'
          ' the closeAll()/closeFor() future before opening storage there'
          ' again.');
    }
    return _byPath.putIfAbsent(key, () => HiveImpl()..init(key));
  }

  /// How two spellings of one directory are recognised as one.
  ///
  /// Without this, `foo/bar` and `foo/./bar` would take separate instances
  /// over the same files and diverge — the exact failure this class exists to
  /// prevent, reintroduced by a string comparison.
  ///
  /// Lexical canonicalisation alone is NOT enough, and believing it was would
  /// leave the same hole open under a different spelling. `p.canonicalize` is
  /// pure string work: it does not follow symlinks, so a link and its target
  /// canonicalise to two different strings and would take two instances over
  /// one directory. That is not exotic — `/data -> /mnt/data` is an ordinary
  /// deployment, and on macOS `Directory.systemTemp` is `/var/folders/...`
  /// while its real path is `/private/var/folders/...`.
  ///
  /// So the directory is resolved on the filesystem, which needs it to exist:
  /// it is created first (idempotent, and Hive would create it moments later
  /// at box open anyway). Were it left to come into existence on its own, a
  /// caller arriving before it did would key on the unresolved spelling and a
  /// caller arriving after would key on the resolved one — two instances again.
  ///
  /// Falls back to the lexical form only if the filesystem refuses (a
  /// permission error, a path that cannot be a directory). That fallback
  /// restores the symlink hole for that path, so it logs rather than passing
  /// silently.
  static String canonicalPathFor(String storagePath) {
    try {
      final dir = Directory(storagePath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return p.canonicalize(dir.resolveSymbolicLinksSync());
    } on FileSystemException catch (e) {
      _logger.warning('Could not resolve "$storagePath" on the filesystem'
          ' ($e); falling back to a lexical path. Two spellings of this'
          ' directory that differ by a symlink would now take separate Hive'
          ' instances over the same files.');
      return p.canonicalize(storagePath);
    }
  }

  /// Closes every box this registry has opened, and forgets the instances.
  ///
  /// **Why a consumer needs this.** A teardown that calls the package-global
  /// `Hive.close()` closes the boxes in the GLOBAL registry, and the boxes
  /// opened here are not in it. They stay open over a directory the teardown
  /// then deletes, and the next open returns the cached box with its stale
  /// in-memory contents — a write appears to succeed and the read that follows
  /// returns the previous test's value. Nothing throws.
  ///
  /// Call this instead of, or alongside, `Hive.close()` wherever storage is
  /// torn down and reopened in one process.
  /// ⚠️ Every store built from these instances holds its own reference to
  /// one, and this cannot reach them: after a close their `hive` field points
  /// at a closed instance, and the next box access throws. Storage is torn
  /// down as a unit — close the stores too, and build new ones on the way
  /// back up.
  static Future<void> closeAll() =>
      Future.wait(_byPath.keys.toList().map(_closeKey));

  /// Closes and forgets the instance owning [storagePath], if there is one.
  ///
  /// Note this keys on a storage PATH, unlike the same-named
  /// `AtPersistenceFactory.closeFor`, which keys on an atSign.
  static Future<void> closeFor(String storagePath) =>
      _closeKey(canonicalPathFor(storagePath));

  /// Closes one already-canonical path's instance, marking it closing for the
  /// duration.
  ///
  /// The entry is dropped only once the close has completed. Dropping it up
  /// front — the obvious way to write this — is what lets a caller arriving
  /// during the await build a second instance over a directory the first is
  /// still closing.
  static Future<void> _closeKey(String key) async {
    final inFlight = _closing[key];
    if (inFlight != null) {
      return inFlight;
    }
    final hive = _byPath[key];
    if (hive == null) {
      return;
    }
    final close = hive.close();
    _closing[key] = close;
    try {
      await close;
    } finally {
      _closing.remove(key);
      _byPath.remove(key);
    }
  }

  /// Instances built so far, for tests that assert the sharing rule.
  static int get instanceCount => _byPath.length;
}
