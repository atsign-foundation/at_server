import 'dart:io';

import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';

import 'hive_instances.dart';

mixin HiveBase<E> {
  bool _isLazy = true;
  late String _boxName;
  late String storagePath;
  final _logger = AtSignLogger('HiveBase');

  /// The Hive instance that owns this store's box.
  ///
  /// Per storage path rather than the package-global `Hive` — see
  /// [HiveInstances] for why. Exposed rather than private because a keystore
  /// has to register its type adapters on the SAME instance: `TypeRegistry`
  /// is per-instance too, so an adapter registered on the global `Hive` is
  /// invisible to a box opened here, and the box would fail to decode its own
  /// contents.
  ///
  /// Not `late final`: [init] is idempotent for callers that re-initialise a
  /// store, and a second assignment to a `late final` throws.
  late HiveInterface hive;

  Future<void> init(String storagePath, {bool isLazy = true}) async {
    _isLazy = isLazy;
    this.storagePath = storagePath;
    hive = HiveInstances.forPath(storagePath);
    await initialize();
  }

  Future<void> initialize();

  Future<void> openBox(String boxName, {List<int>? hiveSecret}) async {
    _boxName = boxName;
    if (_isLazy) {
      if (hiveSecret != null) {
        await hive.openLazyBox(_boxName,
            encryptionCipher: HiveAesCipher(hiveSecret));
      } else {
        await hive.openLazyBox(boxName);
      }
    } else {
      if (hiveSecret != null) {
        await hive.openBox(_boxName,
            encryptionCipher: HiveAesCipher(hiveSecret));
      } else {
        await hive.openBox(boxName);
      }
    }
    if (getBox().isOpen) {
      _logger.finer('$boxName initialized successfully');
    } else {
      _logger.shout('$boxName was apparently initialized, but is not open');
    }
  }

  BoxBase getBox() {
    if (_isLazy) {
      return hive.lazyBox(_boxName);
    }
    return hive.box(_boxName);
  }

  Future<E?> getValue(dynamic key) async {
    return _isLazy
        ? await (getBox() as LazyBox).get(key)
        : await (getBox() as Box).get(key);
  }

  /// Size of this store's on-disk footprint, in KB. Sums the lengths
  /// of every file under [storagePath] whose name starts with the
  /// box name (Hive writes `<boxName>.hive` and `<boxName>.lock`).
  /// The previous impl summed the WHOLE [storagePath] directory,
  /// which double-counts whenever multiple boxes share a directory
  /// (which they do on the secondary).
  int getSize() {
    final dir = Directory(storagePath);
    if (!dir.existsSync()) return 0;
    var bytes = 0;
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith('$_boxName.')) continue;
      bytes += entity.lengthSync();
    }
    return bytes ~/ 1024;
  }

  Future<void> close() async {
    try {
      if (getBox().isOpen) {
        await getBox().close();
      }
    } on HiveError {
      // Box is already gone (e.g. deleteBoxFromDisk called by teardown).
      // Idempotent close — nothing to do.
    }
  }
}
