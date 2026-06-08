// ignore_for_file: constant_identifier_names

/// Represents a commit entry with a key, [CommitOperation] and a commit id
class CommitEntry {
  final String? _atKey;

  CommitOp? operation;

  final DateTime? _opTime;

  int? commitId;

  /// The commit-log box key this entry was read under (its local
  /// sequence number), or `null` for an entry not loaded from
  /// storage. Transient — the keystore sets it on read; it is not
  /// part of the serialized form.
  int? key;

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
