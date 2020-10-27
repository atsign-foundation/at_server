
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
Future<void> main(List<String> arguments) async {
  var boxName = _getShaForAtsign('@murali🛠');
  try {
    await Hive.openBox(boxName,path:Directory.current.path);
  } on Exception catch(e) {
    print(e);
  }
}

String _getShaForAtsign(String atsign) {
  var bytes = utf8.encode(atsign);
  return sha256.convert(bytes).toString();
}