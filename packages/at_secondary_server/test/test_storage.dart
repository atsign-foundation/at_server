import 'dart:io';

String testStoragePath(String relativePath) {
  final String? root = Platform.environment['AT_UNIT_TEST_STORAGE_DIR'];
  if (root == null || root.isEmpty) {
    return '${Directory.current.path}/$relativePath';
  }
  return '$root/$relativePath';
}
