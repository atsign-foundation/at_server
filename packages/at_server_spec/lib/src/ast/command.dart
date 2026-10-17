import 'package:at_server_spec/src/ast/enums.dart';
import 'package:at_server_spec/src/ast/key_scope.dart';
import 'package:at_server_spec/src/ast/metadata_fragment.dart';

part 'commands/auth_commands.dart';
part 'commands/apkam_commands.dart';
part 'commands/delete_command.dart';
part 'commands/lookup_commands.dart';
part 'commands/notify_commands.dart';
part 'commands/scan_command.dart';
part 'commands/server_commands.dart';
part 'commands/sync_commands.dart';
part 'commands/update_command.dart';
part 'commands/update_meta_command.dart';

/// Root of the typed atProtocol command AST: one immutable node per verb,
/// shaped from `doc/protocol_interpreter/00-protocol-spec.md`.
///
/// Sealed so consumers can `switch` exhaustively over the verb set; every
/// subtype is declared as a `part` of this library.
///
/// Nodes are self-contained: they do not reuse at_commons types (see
/// `04-decisions.md` D1).
///
/// Conventions shared by every node:
/// - AtSigns are stored without their leading `@`, even where the legacy
///   regex captures one (`from`, `scan`, `config:block`).
/// - A bare flag (`:nc`, `:force`, `:cached`, ...) is a `bool` defaulting to
///   `false`. A tag carrying an explicit value (`:bypassCache:true`,
///   `:showhidden:false`, ...) is nullable, so an absent tag stays distinct
///   from an explicit `false`.
/// - Free text the grammar doesn't structure (JSON payloads, regexes,
///   values) is kept as the raw wire string; interpreting it is left to
///   validation.
sealed class Command {
  const Command();

  /// The node's fields in wire order, keyed by name. Drives [==],
  /// [hashCode], and [toString], so subtypes only declare their fields.
  Map<String, Object?> get _fields;

  @override
  bool operator ==(Object other) =>
      other is Command &&
      other.runtimeType == runtimeType &&
      _valuesEqual(_fields.values.toList(), other._fields.values.toList());

  @override
  int get hashCode =>
      Object.hash(runtimeType, Object.hashAll(_fields.values.map(_hashOf)));

  @override
  String toString() => '$runtimeType('
      '${_fields.entries.map((e) => '${e.key}: ${e.value}').join(', ')})';
}

/// Element-wise equality, comparing nested lists by content.
bool _valuesEqual(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    if (x is List && y is List) {
      if (!_valuesEqual(x, y)) return false;
    } else if (x != y) {
      return false;
    }
  }
  return true;
}

int _hashOf(Object? value) =>
    value is List ? Object.hashAll(value.map(_hashOf)) : value.hashCode;
