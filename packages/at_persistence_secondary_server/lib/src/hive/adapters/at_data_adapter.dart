import 'package:hive/hive.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';

class AtDataAdapter extends TypeAdapter<AtData> {
  @override
  final int typeId = typeAdapterMap['AtDataAdapter'];

  @override
  AtData read(BinaryReader reader) {
    var numOfFields = reader.readByte();
    var fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AtData()
      ..data = fields[0] as String?
      ..metaData = fields[1] as AtMetaData?;
  }

  @override
  void write(BinaryWriter writer, AtData obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.data)
      ..writeByte(1)
      ..write(obj.metaData);
  }
}
