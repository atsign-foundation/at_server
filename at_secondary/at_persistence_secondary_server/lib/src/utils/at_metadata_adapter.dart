import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

AtMetaData? AtMetadataAdapter(Metadata metadata) {
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
    ..publicKeyCS = metadata.pubKeyCS;

  return AtMetadataBuilder(newAtMetaData: atMetadata).build();
}
