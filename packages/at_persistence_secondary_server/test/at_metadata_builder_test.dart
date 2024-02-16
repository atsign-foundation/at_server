import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:hive/hive.dart';
import 'package:test/test.dart';

void main() async {
  group('A group of metadata builder tests', () {
    test('test existing metadata has few fields set and new metadata is null',
        () async {
      var existingMetadata = AtMetaData()
        ..isEncrypted = true
        ..encAlgo = 'rsa'
        ..encKeyName = 'rsa2048';
      var atMetaData = AtMetadataBuilder(
              atSign: '@alice', existingMetaData: existingMetadata)
          .build();
      expect(atMetaData, isNotNull);
      expect(atMetaData.isEncrypted, true);
      expect(atMetaData.encAlgo, 'rsa');
      expect(atMetaData.encKeyName, 'rsa2048');
    });
    test('test existing metadata is null and new metadata has few fields set',
        () async {
      var newMetadata = AtMetaData()
        ..isEncrypted = true
        ..encAlgo = 'rsa'
        ..encKeyName = 'rsa2048';
      var atMetaData =
          AtMetadataBuilder(atSign: '@alice', newMetaData: newMetadata).build();
      expect(atMetaData, isNotNull);
      expect(atMetaData.isEncrypted, true);
      expect(atMetaData.encAlgo, 'rsa');
      expect(atMetaData.encKeyName, 'rsa2048');
    });
    test('test existing metadata and new metadata have distinct fields set ',
        () async {
      var existingMetadata = AtMetaData()
        ..isEncrypted = true
        ..encAlgo = 'rsa'
        ..encKeyName = 'rsa2048';
      var newMetadata = AtMetaData()
        ..dataSignature = 'test_signature'
        ..isCascade = true
        ..ivNonce = 'test_nonce';
      var atMetadata = AtMetadataBuilder(
              atSign: '@alice',
              newMetaData: newMetadata,
              existingMetaData: existingMetadata)
          .build();
      //resulting metadata should have all fields set from newMetadata and existingMetadata
      expect(atMetadata, isNotNull);
      expect(atMetadata.isEncrypted, true);
      expect(atMetadata.encAlgo, 'rsa');
      expect(atMetadata.encKeyName, 'rsa2048');
      expect(atMetadata.dataSignature, 'test_signature');
      expect(atMetadata.isCascade, true);
      expect(atMetadata.ivNonce, 'test_nonce');
    });
    test('test existing metadata and new metadata have some common fields set ',
        () async {
      var existingMetadata = AtMetaData()
        ..isCascade = false
        ..isEncrypted = true
        ..encAlgo = 'rsa'
        ..encKeyName = 'rsa1024';
      var newMetadata = AtMetaData()
        ..isCascade = true
        ..isEncrypted = true
        ..encAlgo = 'rsa'
        ..encKeyName = 'rsa2048';
      var atMetadata = AtMetadataBuilder(
              atSign: '@alice',
              newMetaData: newMetadata,
              existingMetaData: existingMetadata)
          .build();
      //resulting metadata should have values set from newMetadata
      expect(atMetadata, isNotNull);
      expect(atMetadata.isCascade, true);
      expect(atMetadata.isEncrypted, true);
      expect(atMetadata.encAlgo, 'rsa');
      expect(atMetadata.encKeyName, 'rsa2048');
    });
  });
}
