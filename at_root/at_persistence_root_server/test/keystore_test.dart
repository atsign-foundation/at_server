import 'dart:collection';
import 'package:test/test.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';

void main() {
  var keyStore = MapKeyStore();
  group('Keystore-1', () {
    setUp(() => keyStore.init());
    tearDown(() => keyStore.clear());
    test('test simple keystore get', () async {
      var value = await keyStore.get('aaa');
      expect(value, 1);
      print('end of simple keystore get test');
    });
  });
}

class MapKeyStore implements Keystore<String, int> {
  final Map<String, int> test = HashMap<String, int>();
  void init() {
    print('init');
    test['aaa'] = 1;
    test['bbb'] = 2;
    test['ccc'] = 3;
  }

  void clear() {
    print('clear');
    test.clear();
  }

  @override
  Future<int> get(String key) {
    return Future.delayed(Duration(seconds: 2), () => test[key]);
  }
}
