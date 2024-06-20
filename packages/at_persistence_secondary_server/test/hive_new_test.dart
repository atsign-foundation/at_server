
import 'package:hive/hive.dart';
import 'package:isar/isar.dart';
void main() async {
await Isar.(download: true)
  var box = Hive.box(name: "hello", directory: "test/hive");
  box.put("first_key", "test value");
  print(box.get("first_key"));
}