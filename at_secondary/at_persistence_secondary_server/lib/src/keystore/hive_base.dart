import 'package:hive/hive.dart';

mixin HiveBase {
  bool isLazy = false;
  BoxBase getBox(String boxName) {
    if (isLazy) {
      return Hive.lazyBox(boxName);
    }
    return Hive.box(boxName);
  }

  Future<void> openBox(String boxName) async {
    if (isLazy) {
      await Hive.openBox(boxName);
    } else {
      await Hive.openLazyBox(boxName);
    }
  }

  Future<void> init(String storagePath, {bool isLazy = false});
}
