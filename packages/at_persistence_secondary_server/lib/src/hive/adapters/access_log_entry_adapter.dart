import 'package:hive/hive.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_entry.dart';
import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';

/// Hive adapter for [AccessEntry]
class AccessLogEntryAdapter extends TypeAdapter<AccessLogEntry> {
  @override
  final int typeId = typeAdapterMap['AccessLogEntryAdapter'];

  @override
  AccessLogEntry read(BinaryReader reader) {
    var numOfFields = reader.readByte();
    var fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read()
    };
    var accessLogEntry = AccessLogEntry(fields[0] as String?,
        fields[1] as DateTime?, fields[2] as String?, fields[3] as String?);
    return accessLogEntry;
  }

  @override
  void write(BinaryWriter writer, AccessLogEntry obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.fromAtSign)
      ..writeByte(1)
      ..write(obj.requestDateTime)
      ..writeByte(2)
      ..write(obj.verbName)
      ..writeByte(3)
      ..write(obj.lookupKey);
  }
}
