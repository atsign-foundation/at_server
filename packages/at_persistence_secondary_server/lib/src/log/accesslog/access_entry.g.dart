// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'access_entry.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AccessLogEntryAdapter extends TypeAdapter<AccessLogEntry> {
  @override
  final int typeId = 4;

  @override
  AccessLogEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AccessLogEntry(
      fields[0] as String?,
      fields[1] as DateTime?,
      fields[2] as String?,
      fields[3] as String?,
    );
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

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccessLogEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
