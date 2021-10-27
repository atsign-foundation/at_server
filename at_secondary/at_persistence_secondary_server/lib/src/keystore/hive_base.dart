import 'dart:io';

import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';

mixin HiveBase {
  bool _isLazy = true;
  late String _boxName;
  late String _storagePath;
  final _logger = AtSignLogger('HiveBase');
  Future<void> init(String storagePath, {bool isLazy = true}) async {
    _isLazy = isLazy;
    _storagePath = storagePath;
    Hive.init(storagePath);
    initialize();
  }

  Future<void> initialize();

  Future<void> openBox(String boxName) async {
    _boxName = boxName;
    if (_isLazy) {
      await Hive.openBox(boxName);
    } else {
      await Hive.openLazyBox(boxName);
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

  Future<dynamic> getValue(dynamic key) {
    return _isLazy
        ? (getBox() as LazyBox).get(key)
        : (getBox() as Box).get(key);
  }

  int getSize() {
    var logSize = 0;
    var logLocation = Directory(_storagePath!);

    if (_storagePath != null) {
      //The listSync function returns the list of files in the commit log storage location.
      // The below loop iterates recursively into sub-directories over each file and gets the file size using lengthSync function
      logLocation.listSync().forEach((element) {
        logSize = logSize + File(element.path).lengthSync();
      });
    }
    return logSize ~/ 1024;
  }

  void close() async {
    await getBox().close();
  }
}
