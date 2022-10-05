import 'package:at_commons/at_commons.dart';
abstract class AtCompaction {
  void setCompactionConfig(AtCompactionConfig atCompactionConfig);
  Future<List> getKeysToDeleteOnCompaction();
  Future<void> deleteKeyForCompaction(String key);
}
