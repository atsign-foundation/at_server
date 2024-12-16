// ignore_for_file: constant_identifier_names

import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';
import 'package:hive_ce/hive.dart';

/// Represents a commit entry with a key, [CommitOperation] and a commit id
class CommitEntry extends HiveObject {
  final String? atKey;

  CommitOp? operation;

  final DateTime? opTime;

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

enum CommitOp {  UPDATE,  DELETE, UPDATE_META, UPDATE_ALL }

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

/// Represents a CommitEntry with all instances pointing to null/defaults.
///
/// A NullCommitEntry will be returned when none of CommitEntry matches the given criteria
/// (in place where a null has to returned when a matching CommitEntry is not found).
class NullCommitEntry extends CommitEntry {
  NullCommitEntry() : super('', CommitOp.UPDATE, DateTime.now());
}
