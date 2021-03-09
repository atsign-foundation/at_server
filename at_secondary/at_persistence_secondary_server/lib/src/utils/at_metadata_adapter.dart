import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

AtMetaData AtMetadataAdapter(Metadata metadata) {
  if (metadata == null) {
    return AtMetaData();
  }
  var atMetadata = AtMetaData()
    ..ttl = metadata.ttl
    ..ttb = metadata.ttb
    ..ttr = metadata.ttr
    ..isCascade = metadata.ccd
    ..availableAt = metadata.availableAt
    ..expiresAt = metadata.expiresAt
    ..refreshAt = metadata.refreshAt
    ..createdAt = metadata.createdAt
    ..updatedAt = metadata.updatedAt
    ..dataSignature = metadata.dataSignature
    ..isBinary = metadata.isBinary
    ..isEncrypted = metadata.isEncrypted
    ..dataSignature = metadata.dataSignature
    ..sharedKeyStatus = metadata.sharedKeyStatus;

  return atMetadata;
}

Metadata MetadataAdapter(AtMetaData atMetaData) {
  if (atMetaData == null) {
    return Metadata();
  }
  var metadata = Metadata()
    ..ttl = atMetaData.ttl
    ..ttb = atMetaData.ttb
    ..ttr = atMetaData.ttr
    ..ccd = atMetaData.isCascade
    ..availableAt = atMetaData.availableAt
    ..expiresAt = atMetaData.expiresAt
    ..refreshAt = atMetaData.refreshAt
    ..createdAt = atMetaData.createdAt
    ..updatedAt = atMetaData.updatedAt
    ..dataSignature = atMetaData.dataSignature
    ..isBinary = atMetaData.isBinary
    ..isEncrypted = atMetaData.isEncrypted
    ..sharedKeyStatus = atMetaData.sharedKeyStatus;

  return metadata;
}
