abstract class AtCompaction {
  Future<List> getKeysToCompact();
  Future<void> deleteKey(String key);
}
