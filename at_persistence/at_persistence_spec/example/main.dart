import 'package:at_persistence_spec/at_persistence_spec.dart';

class MyKeyStore implements Keystore {
  @override
  Future get(key) {
    return null;
  }

  @override
  Stream watch({dynamic key}) {
    // TODO: implement watch
    throw UnimplementedError();
  }
}
