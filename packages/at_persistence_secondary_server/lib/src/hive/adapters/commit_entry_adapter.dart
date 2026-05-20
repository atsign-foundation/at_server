import 'package:hive/hive.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';

/// Hive type adapter for [CommitEntry]
class CommitEntryAdapter extends TypeAdapter<CommitEntry> {
  @override
  final int typeId = typeAdapterMap['CommitEntryAdapter'];

  @override
  CommitEntry read(BinaryReader reader) {
    var numOfFields = reader.readByte();
    var fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read()
    };
    var commitEntry = CommitEntry(
        fields[0] as String?, fields[1] as CommitOp?, fields[2] as DateTime?);
    commitEntry.commitId = fields[3] as int?;
    return commitEntry;
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
}

class CommitOpAdapter extends TypeAdapter<CommitOp?> {
  @override
  final int typeId = typeAdapterMap['CommitOpAdapter'];

  @override
  CommitOp? read(BinaryReader reader) {
    var numOfFields = reader.readByte();
    var fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read()
    };
    CommitOp? commitOp;
    switch (fields[0]) {
      case '-':
        commitOp = CommitOp.DELETE;
        break;
      case '+':
        commitOp = CommitOp.UPDATE;
        break;
      case '#':
        commitOp = CommitOp.UPDATE_META;
        break;
      case '*':
        commitOp = CommitOp.UPDATE_ALL;
        break;
    }
    return commitOp;
  }

  @override
  void write(BinaryWriter writer, CommitOp? obj) {
    writer
      ..writeByte(1)
      ..writeByte(0)
      ..write(obj.name);
  }
}
