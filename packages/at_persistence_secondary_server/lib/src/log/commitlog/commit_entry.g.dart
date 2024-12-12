// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'commit_entry.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CommitEntryAdapter extends TypeAdapter<CommitEntry> {
  @override
  final int typeId = 2;

  @override
  CommitEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CommitEntry(
      fields[0] as String?,
      fields[1] as CommitOp?,
      fields[2] as DateTime?,
    )..commitId = (fields[3] as num?)?.toInt();
  }

  @override
  void write(BinaryWriter writer, CommitEntry obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.atKey)
      ..writeByte(1)
      ..write(obj.operation)
      ..writeByte(2)
      ..write(obj.opTime)
      ..writeByte(3)
      ..write(obj.commitId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommitEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class CommitOpAdapter extends TypeAdapter<CommitOp> {
  @override
  final int typeId = 3;

  @override
  CommitOp read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return CommitOp.UPDATE;
      case 1:
        return CommitOp.DELETE;
      case 2:
        return CommitOp.UPDATE_META;
      case 3:
        return CommitOp.UPDATE_ALL;
      default:
        return CommitOp.UPDATE;
    }
  }

  @override
  void write(BinaryWriter writer, CommitOp obj) {
    switch (obj) {
      case CommitOp.UPDATE:
        return writer.writeByte(0);
      case CommitOp.DELETE:
        return writer.writeByte(1);
      case CommitOp.UPDATE_META:
        return writer.writeByte(2);
      case CommitOp.UPDATE_ALL:
        return writer.writeByte(3);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommitOpAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
