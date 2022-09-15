import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

AtMetaData? atMetadataAdapter(Metadata metadata) {
  var atMetadata = AtMetaData();
  atMetadata
    ..ttl = metadata.ttl
    ..ttb = metadata.ttb
    ..ttr = metadata.ttr
    ..isCascade = metadata.ccd
    ..isBinary = metadata.isBinary
    ..isEncrypted = metadata.isEncrypted
    ..dataSignature = metadata.dataSignature
    ..sharedKeyEnc = metadata.sharedKeyEnc
    ..pubKeyCS = metadata.pubKeyCS
    ..encoding = metadata.encoding;

  return AtMetadataBuilder(newAtMetaData: atMetadata).build();
}

Metadata metadataAdapter(AtMetaData atMetaData) {
  var metadata = Metadata()
    ..ttl = atMetaData.ttl
    ..ttb = atMetaData.ttb
    ..ttr = atMetaData.ttr
    ..ccd = atMetaData.isCascade
    ..isBinary = atMetaData.isBinary
    ..isEncrypted = atMetaData.isEncrypted
    ..dataSignature = atMetaData.dataSignature
    ..sharedKeyEnc = atMetaData.sharedKeyEnc
    ..pubKeyCS = atMetaData.pubKeyCS
    ..encoding = atMetaData.encoding;
  return metadata;
}
