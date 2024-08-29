import 'dart:io';

import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';
import 'package:isar/isar.dart';

mixin HiveBase<E> {
  late String _boxName;
  late String storagePath;
  late String isarLibPath;
  final _logger = AtSignLogger('HiveBase');
  void init(String storagePath, {String? isarLibPath}) {
    if (!Directory(storagePath).existsSync()) {
      Directory(storagePath).createSync(recursive: true);
    }
    this.storagePath = storagePath;
    Hive.defaultDirectory = storagePath;
    if (isarLibPath != null) {
      Isar.initialize(isarLibPath);
    }
    initialize();
  }

  void initialize();

  void openBox(String boxName, {List<int>? hiveSecret}) {
    print('***open box');
    _boxName = boxName;
    if (hiveSecret != null) {
      Hive.box(
          name: _boxName,
          directory: storagePath,
          encryptionKey: hiveSecret.toString());
    } else {
      Hive.box(name: _boxName, directory: storagePath);
    }
    if (getBox().isOpen) {
      _logger.info('$boxName initialized successfully');
    }
  }

  Box getBox() {
    return Hive.box(name: _boxName);
  }

  E? getValue(dynamic key) {
    return getBox().get(key.toString());
  }

  int getSize() {
    var logSize = 0;
    var logLocation = Directory(storagePath);

    //The listSync function returns the list of files in the commit log storage location.
    // The below loop iterates recursively into sub-directories over each file and gets the file size using lengthSync function
    logLocation.listSync().forEach((element) {
      logSize = logSize + File(element.path).lengthSync();
    });
    return logSize ~/ 1024;
  }

  void close() async {
    if (getBox().isOpen) {
      getBox().close();
    }
  }
}
