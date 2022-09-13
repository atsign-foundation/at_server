import 'dart:io';

import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';

mixin HiveBase<E> {
  bool _isLazy = true;
  late String _boxName;
  late String storagePath;
  final _logger = AtSignLogger('HiveBase');
  Future<void> init(String storagePath, {bool isLazy = true}) async {
    _isLazy = isLazy;
    this.storagePath = storagePath;
    Hive.init(storagePath);
    await initialize();
  }

  Future<void> initialize();

  Future<void> openBox(String boxName, {List<int>? hiveSecret}) async {
    _boxName = boxName;
    if (_isLazy) {
      if (hiveSecret != null) {
        await Hive.openLazyBox(_boxName,
            encryptionCipher: HiveAesCipher(hiveSecret));
      } else {
        await Hive.openLazyBox(boxName);
      }
    } else {
      if (hiveSecret != null) {
        await Hive.openBox(_boxName,
            encryptionCipher: HiveAesCipher(hiveSecret));
      } else {
        await Hive.openBox(boxName);
      }
    }
    if (getBox().isOpen) {
      _logger.info('$boxName initialized successfully');
    }
  }

  BoxBase getBox() {
    if (_isLazy) {
      return Hive.lazyBox(_boxName);
    }
    return Hive.box(_boxName);
  }

  Future<E?> getValue(dynamic key) async {
    return _isLazy
        ? await (getBox() as LazyBox).get(key)
        : await (getBox() as Box).get(key);
  }

  int getSize() {
    var logSize = 0;
    // ignore: unnecessary_this
    var logLocation = Directory(this.storagePath);

    //The listSync function returns the list of files in the commit log storage location.
    // The below loop iterates recursively into sub-directories over each file and gets the file size using lengthSync function
    logLocation.listSync().forEach((element) {
      logSize = logSize + File(element.path).lengthSync();
    });
    return logSize ~/ 1024;
  }

  Future<void> close() async {
    if (getBox().isOpen) {
      await getBox().close();
    }
  }
}
