import 'package:hive/hive.dart';
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

  static final Map<String, HiveInterface> _byPath = <String, HiveInterface>{};

  /// The instance owning [storagePath], created on first use.
  static HiveInterface forPath(String storagePath) {
    final key = canonicalPathFor(storagePath);
    return _byPath.putIfAbsent(key, () => HiveImpl()..init(key));
  }

  /// How two spellings of one directory are recognised as one.
  ///
  /// Without this, `foo/bar` and `foo/./bar` would take separate instances
  /// over the same files and diverge — the exact failure this class exists to
  /// prevent, reintroduced by a string comparison.
  static String canonicalPathFor(String storagePath) =>
      p.canonicalize(storagePath);

  /// Instances built so far, for tests that assert the sharing rule.
  static int get instanceCount => _byPath.length;
}
