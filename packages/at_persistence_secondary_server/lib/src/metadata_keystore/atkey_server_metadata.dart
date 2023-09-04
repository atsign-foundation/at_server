import 'package:at_persistence_secondary_server/src/metadata_keystore/at_key_metadata.dart';
import 'package:hive/hive.dart';

class AtKeyServerMetadata extends AtKeyMetadata {
  @HiveField(0)
  late int commitId;
}
