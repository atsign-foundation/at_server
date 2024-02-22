import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() async {
  group('A group of metadata builder tests', () {
    test('test existing metadata has few fields set and new metadata is null',
        () async {
      var existingMetadata = AtMetaData()
        ..isEncrypted = true
        ..encAlgo = 'rsa'
        ..encKeyName = 'rsa2048'
        ..ttl = 10000
        ..ttb = 5000
        ..ttr = 65000;
      var atMetaData = AtMetadataBuilder(
              atSign: '@alice', existingMetaData: existingMetadata)
          .build();
      expect(atMetaData, isNotNull);
      expect(atMetaData.isEncrypted, true);
      expect(atMetaData.encAlgo, 'rsa');
      expect(atMetaData.encKeyName, 'rsa2048');
      expect(atMetaData.ttl, 10000);
      expect(atMetaData.ttb, 5000);
      expect(atMetaData.ttr, 65000);
    });
  });
}
