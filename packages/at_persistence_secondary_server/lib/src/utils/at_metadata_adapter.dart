import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

@Deprecated("use AtMetaData.fromCommonsMetadata")
// ignore: non_constant_identifier_names
AtMetaData? AtMetadataAdapter(Metadata metadata) {
  return AtMetaData.fromCommonsMetadata(metadata);
}

@Deprecated('Use AtMetaData.toCommonsMetadata')
Metadata metadataAdapter(AtMetaData atMetaData) {
  return atMetaData.toCommonsMetadata();
}
