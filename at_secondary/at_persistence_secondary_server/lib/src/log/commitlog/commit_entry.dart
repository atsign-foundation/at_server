import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';
import 'package:hive/hive.dart';

/// Represents a commit entry with a key, [CommitOperation] and a commit id
@HiveType()
class CommitEntry extends HiveObject {
  @HiveField(0)
  final String _atKey;

  @HiveField(1)
  CommitOp operation;

  @HiveField(2)
  final DateTime _opTime;

  @HiveField(3)
  int commitId;

  CommitEntry(this._atKey, this.operation, this._opTime);

  String get atKey => _atKey;

  DateTime get opTime => _opTime;

  Map toJson() => {
        'atKey': _atKey,
        'operation': operation.name,
        'opTime': _opTime.toString(),
        'commitId': commitId
      };

  @override
  String toString() {
    return 'CommitEntry{AtKey: $_atKey, operation: $operation, commitId:$commitId, opTime: $_opTime, internal_seq: $key}';
  }
}

enum CommitOp { UPDATE, DELETE, UPDATE_META, UPDATE_ALL }

extension CommitOpSymbols on CommitOp {
  String get name {
    switch (this) {
      case CommitOp.UPDATE:
        return '+';
      case CommitOp.UPDATE_META:
        return '#';
      case CommitOp.UPDATE_ALL:
        return '*';
      case CommitOp.DELETE:
        return '-';
      default:
        return null;
    }
  }
}

/// Hive type adapter for [CommitEntry]
class CommitEntryAdapter extends TypeAdapter<CommitEntry> {
  @override
  final typeId = typeAdapterMap['CommitEntryAdapter'];

  @override
  CommitEntry read(BinaryReader reader) {
    var numOfFields = reader.readByte();
    var fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read()
    };
    var commitEntry = CommitEntry(
        fields[0] as String, fields[1] as CommitOp, fields[2] as DateTime);
    commitEntry.commitId = fields[3] as int;
    return commitEntry;
  }

  @override
  void write(BinaryWriter writer, CommitEntry entry) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(entry.atKey)
      ..writeByte(1)
      ..write(entry.operation)
      ..writeByte(2)
      ..write(entry.opTime)
      ..writeByte(3)
      ..write(entry.commitId);
  }
}

class CommitOpAdapter extends TypeAdapter<CommitOp> {
  @override
  final typeId = typeAdapterMap['CommitOpAdapter'];

  @override
  CommitOp read(BinaryReader reader) {
    var numOfFields = reader.readByte();
    var fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read()
    };
    var commitOp;
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
  void write(BinaryWriter writer, CommitOp commitOp) {
    writer
      ..writeByte(1)
      ..writeByte(0)
      ..write(commitOp.name);
  }
}
