import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';
import 'package:hive/hive.dart';
import 'package:at_utf7/at_utf7.dart';

@HiveType(typeId: 0)
class AtData extends HiveObject {
  @HiveField(0)
  String? data;

  @HiveField(1)
  AtMetaData? metaData;

  @override
  String toString() {
    return 'AtData{data: $data, metaData: ${metaData.toString()}';
  }

  Map toJson() {
    // ignore: omit_local_variable_types
    Map map = {};
    map['key'] = Utf7.decode(key);
    map['data'] = data;
    map['metaData'] = metaData!.toJson();
    return map;
  }

  AtData fromJson(Map json) {
    data = json['data'];
    metaData = AtMetaData().fromJson(json['metaData']);
    return this;
  }
}

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
