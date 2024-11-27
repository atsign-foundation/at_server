// ignore_for_file: constant_identifier_names

import 'package:hive_ce/hive.dart';
part 'commit_entry.g.dart';

/// Represents a commit entry with a key, [CommitOperation] and a commit id
@HiveType(typeId: 2)
class CommitEntry extends HiveObject {
  @HiveField(0)
  final String? atKey;

  @HiveField(1)
  CommitOp? operation;

  @HiveField(2)
  final DateTime? opTime;

  @HiveField(3)
  int? commitId;

  CommitEntry(this.atKey, this.operation, this.opTime);

  Map toJson() => {
        'atKey': atKey,
        'operation': operation.name,
        'opTime': opTime.toString(),
        'commitId': commitId
      };

  @override
  String toString() {
    return 'CommitEntry{AtKey: $atKey, operation: $operation, commitId:$commitId, opTime: $opTime, internal_seq: $key}';
  }
}

@HiveType(typeId: 3)
enum CommitOp {
  @HiveField(0)
  UPDATE,
  @HiveField(1)
  DELETE,
  @HiveField(2)
  UPDATE_META,
  @HiveField(3)
  UPDATE_ALL
}

extension CommitOpSymbols on CommitOp? {
  String? get name {
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

// class CommitOpAdapter extends TypeAdapter<CommitOp?> {
//   @override
//   final int typeId = typeAdapterMap['CommitOpAdapter'];
//
//   @override
//   CommitOp? read(BinaryReader reader) {
//     var numOfFields = reader.readByte();
//     var fields = <int, dynamic>{
//       for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read()
//     };
//     CommitOp? commitOp;
//     switch (fields[0]) {
//       case '-':
//         commitOp = CommitOp.DELETE;
//         break;
//       case '+':
//         commitOp = CommitOp.UPDATE;
//         break;
//       case '#':
//         commitOp = CommitOp.UPDATE_META;
//         break;
//       case '*':
//         commitOp = CommitOp.UPDATE_ALL;
//         break;
//     }
//     return commitOp;
//   }
//
//   @override
//   void write(BinaryWriter writer, CommitOp? obj) {
//     writer
//       ..writeByte(1)
//       ..writeByte(0)
//       ..write(obj.name);
//   }
// }

/// Represents a CommitEntry with all instances pointing to null/defaults.
///
/// A NullCommitEntry will be returned when none of CommitEntry matches the given criteria
/// (in place where a null has to returned when a matching CommitEntry is not found).
class NullCommitEntry extends CommitEntry {
  NullCommitEntry() : super('', CommitOp.UPDATE, DateTime.now());
}
