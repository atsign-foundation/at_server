import 'package:at_persistence_secondary_server/src/metadata_keystore/atkey_server_metadata.dart';
import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';
import 'package:hive/hive.dart';

@HiveType(typeId: 11)
abstract class AtKeyMetadata extends HiveObject {}

abstract class AtKeyMetadataAdapter<T> extends TypeAdapter<T> {
  @override
  int get typeId => typeAdapterMap['AtKeyMetadataAdapter'];
}

class AtKeyServerMetadataAdapter
    extends AtKeyMetadataAdapter<AtKeyServerMetadata> {
  @override
  AtKeyServerMetadata read(BinaryReader reader) {
    var numOfFields = reader.readByte();
    var fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read()
    };
    AtKeyServerMetadata atKeyServerMetadata = AtKeyServerMetadata()
      ..commitId = fields[0] as int;
    return atKeyServerMetadata;
  }

  @override
  void write(BinaryWriter writer, AtKeyServerMetadata obj) {
    writer
      ..writeByte(1)
      ..writeByte(0)
      ..write(obj.commitId);
  }
}
