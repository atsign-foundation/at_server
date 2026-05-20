import 'dart:collection';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

HashMap<String, String> dummyKeyStore = HashMap();

class MockAtKeyValueStore extends Mock
    implements AtKeyValueStore<String, AtData, AtMetaData?> {
  @override
  List<String> getKeys({String? regex}) {
    return dummyKeyStore.keys.toList();
  }

  @override
  Future<int?> remove(String key, {bool skipCommit = false}) async {
    dummyKeyStore.remove(key);
    return 1;
  }
}

void main() {
  verbTestsSetUpLogging();

  group(
      'A group of test to verify remove the malformed keys on server start-up',
      () {
    setUp(() {
      dummyKeyStore.putIfAbsent(
          'public:cached:public:publickey$alice', () => 'dummy_value');
      dummyKeyStore.putIfAbsent('public:publickey$alice', () => 'dummy_value');
      dummyKeyStore.putIfAbsent('public:publickey', () => 'dummy_value');
      dummyKeyStore.putIfAbsent('$alice:phone@bob', () => 'dummy_value');
    });
    test('A test to verify only malformed keys are removed', () async {
      AtSecondaryServerImpl.getInstance().keyValueStore = MockAtKeyValueStore();
      await AtSecondaryServerImpl.getInstance().removeMalformedKeys();
      expect(dummyKeyStore.length, 2);
      expect(dummyKeyStore.containsKey('public:publickey$alice'), true);
      expect(dummyKeyStore.containsKey('$alice:phone@bob'), true);
      expect(dummyKeyStore.containsKey('public:cached:public:publickey$alice'),
          false);
      expect(dummyKeyStore.containsKey('public:publickey'), false);
    });
  });
}
