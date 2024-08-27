// ignore_for_file: constant_identifier_names

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// Represents a commit entry with a key, [CommitOperation] and a commit id
class CommitEntry {
  final String? _atKey;

  CommitOp? operation;

  final DateTime? _opTime;

  int? commitId;

  late int key; //same as commit id. for backward compatibility

  CommitEntry(this._atKey, this.operation, this._opTime);

  String? get atKey => _atKey;

  DateTime? get opTime => _opTime;

  Map toJson() => {
        'atKey': _atKey,
        'operation': operation.name,
        'opTime': _opTime.toString(),
        'commitId': commitId,
        'key': key
      };

  factory CommitEntry.fromJson(dynamic json) {
    return CommitEntry(json['atKey'], _getCommitOpFromSymbol(json['operation']),
        json['optime'])
      ..commitId = json['commitId']
      ..key = json['key'];
  }

  @override
  String toString() {
    return 'CommitEntry{AtKey: $_atKey, operation: $operation, commitId:$commitId, key:$key,,opTime: $_opTime}';
  }
}

enum CommitOp { UPDATE, DELETE, UPDATE_META, UPDATE_ALL }

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

CommitOp? _getCommitOpFromSymbol(String symbol) {
  CommitOp? commitOp;
  switch (symbol) {
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

/// Represents a CommitEntry with all instances pointing to null/defaults.
///
/// A NullCommitEntry will be returned when none of CommitEntry matches the given criteria
/// (in place where a null has to returned when a matching CommitEntry is not found).
class NullCommitEntry extends CommitEntry {
  NullCommitEntry() : super('', CommitOp.UPDATE, DateTime.now());
}
