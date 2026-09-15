/// A scannerless cursor over a raw atProtocol command string.
///
/// The atProtocol is colon/`@`/space delimited, but the trailing `value`
/// segment legally contains `:`, `@` and spaces — so a naive tokenizer that
/// splits on `:` would corrupt it. Instead the grammar drives this [Scanner]
/// on demand, deciding for itself where structural delimiters end and free
/// values begin.
///
/// Case handling mirrors the legacy `RegExp(pattern, caseSensitive: false)`:
/// only literal labels/flags/enum tokens are matched case-insensitively (via
/// [matchLiteralCI]); captured free values are returned verbatim so their
/// original bytes are preserved.
class Scanner {
  final String src;
  int pos = 0;

  Scanner(this.src);

  bool get atEnd => pos >= src.length;

  int get remaining => src.length - pos;

  /// The code unit at the cursor, or -1 at end.
  int get current => atEnd ? -1 : src.codeUnitAt(pos);

  /// Save the current position for later backtracking.
  int save() => pos;

  /// Restore a position captured by [save].
  void restore(int mark) => pos = mark;

  /// Case-insensitive literal match. Advances and returns true on success,
  /// leaves the cursor untouched and returns false otherwise.
  bool matchLiteralCI(String literal) {
    final end = pos + literal.length;
    if (end > src.length) return false;
    if (src.substring(pos, end).toLowerCase() != literal.toLowerCase()) {
      return false;
    }
    pos = end;
    return true;
  }

  /// Match a single code unit exactly. Advances on success.
  bool matchChar(int codeUnit) {
    if (current != codeUnit) return false;
    pos++;
    return true;
  }

  /// Consume the maximal run of characters satisfying [pred]. Returns the run,
  /// or null if fewer than [min] characters matched (cursor unchanged on null).
  String? takeWhile(bool Function(int codeUnit) pred, {int min = 1}) {
    final start = pos;
    while (!atEnd && pred(src.codeUnitAt(pos))) {
      pos++;
    }
    if (pos - start < min) {
      pos = start;
      return null;
    }
    return src.substring(start, pos);
  }

  /// Consume everything from the cursor to the end of input.
  String takeRest() {
    final rest = src.substring(pos);
    pos = src.length;
    return rest;
  }
}

// Common character predicates, shared by value rules and segments.

const int $colon = 0x3A; // :
const int $at = 0x40; // @
const int $space = 0x20; // (space)

bool isColon(int c) => c == $colon;
bool isAt(int c) => c == $at;
bool isSpace(int c) => c == $space;

/// `[^:@\s]` — the most common atProtocol value class (no colon, at, or space).
bool notColonAtSpace(int c) =>
    c != $colon && c != $at && c != $space && !_isWhitespace(c);

/// `[^:@]` — no colon or at.
bool notColonAt(int c) => c != $colon && c != $at;

/// `[^:]` — no colon.
bool notColon(int c) => c != $colon;

/// `[^@]` — no at.
bool notAt(int c) => c != $at;

/// `[^@\s]` — no at or space.
bool notAtSpace(int c) => c != $at && !_isWhitespace(c);

/// `[^\s]` — any non-whitespace.
bool notSpace(int c) => !_isWhitespace(c);

/// `\d`
bool isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isWhitespace(int c) =>
    c == $space ||
    c == 0x09 || // tab
    c == 0x0A || // newline
    c == 0x0B ||
    c == 0x0C ||
    c == 0x0D; // carriage return
