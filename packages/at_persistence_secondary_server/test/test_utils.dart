import 'dart:math';

class TestUtils {
  static String getIsarLibPath() {
    //#TODO read from env var
    return '/Users/murali/Downloads/libisar_macos.dylib';
  }

  static String generateRandomString(int length) {
    const charset =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)])
        .join();
  }
}
