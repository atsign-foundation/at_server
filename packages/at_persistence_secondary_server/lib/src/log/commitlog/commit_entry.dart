// ignore_for_file: constant_identifier_names

import 'package:hive/hive.dart';

/// Represents a commit entry with a key, [CommitOperation] and a commit id
class CommitEntry extends HiveObject {
  final String? _atKey;

  CommitOp? operation;

  final DateTime? _opTime;

  int? commitId;

  CommitEntry(this._atKey, this.operation, this._opTime);

  String? get atKey => _atKey;

  DateTime? get opTime => _opTime;

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
  // Singleton — callers only read fields off the result and check
  // `is NullCommitEntry` to detect the no-match case, so there is no need to
  // allocate (and re-stamp DateTime.now() on) a fresh instance per miss.
  static final NullCommitEntry _instance = NullCommitEntry._();
  factory NullCommitEntry() => _instance;
  NullCommitEntry._()
      : super('', CommitOp.UPDATE,
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
}
