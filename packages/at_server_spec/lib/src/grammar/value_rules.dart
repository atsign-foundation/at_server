import 'scanner.dart';

/// A [ValueRule] reads a field's value from the cursor, returning the captured
/// string on success or null on failure (leaving the cursor unchanged on
/// null). Rules mirror the character classes used in the legacy verb regexes.
typedef ValueRule = String? Function(Scanner c);

/// `[^:@\s]+`
String? tokenNoColonAtSpace(Scanner c) => c.takeWhile(notColonAtSpace);

/// `[^:@]+` (one or more)
String? tokenNoColonAt(Scanner c) => c.takeWhile(notColonAt);

/// `[^:]+`
String? tokenNoColon(Scanner c) => c.takeWhile(notColon);

/// `[^@\s]+`
String? tokenNoAtSpace(Scanner c) => c.takeWhile(notAtSpace);

/// `\S+`
String? tokenNoSpace(Scanner c) => c.takeWhile(notSpace);

/// `-?\d+`
String? intRule(Scanner c) {
  final start = c.save();
  final buf = StringBuffer();
  if (c.matchChar(0x2D)) buf.write('-'); // optional leading '-'
  final digits = c.takeWhile(isDigit);
  if (digits == null) {
    c.restore(start);
    return null;
  }
  buf.write(digits);
  return buf.toString();
}

/// `\d+`
String? uintRule(Scanner c) => c.takeWhile(isDigit);

/// `true|false`, matched case-insensitively but captured with original case
/// (mirrors `caseSensitive: false` over a `true|false` alternation).
String? boolRule(Scanner c) {
  final start = c.save();
  if (c.matchLiteralCI('true')) return c.src.substring(start, c.pos);
  if (c.matchLiteralCI('false')) return c.src.substring(start, c.pos);
  return null;
}

/// `\{.+\}` — a brace-delimited JSON blob (greedy, to end of input like `.+`).
String? braceJsonRule(Scanner c) {
  if (c.current != 0x7B) return null; // must start with '{'
  final start = c.save();
  final rest = c.takeRest();
  if (!rest.endsWith('}') || rest.length < 2) {
    c.restore(start);
    return null;
  }
  return rest;
}

/// `.+` — everything from the cursor to end of input (min 1 char).
String? restRule(Scanner c) {
  if (c.atEnd) return null;
  return c.takeRest();
}

/// `\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z` — an ISO-8601 UTC timestamp.
String? iso8601Rule(Scanner c) {
  final start = c.save();
  String? fixed(int n) {
    final s = c.save();
    final v = c.takeWhile(isDigit, min: n);
    if (v == null || v.length != n) {
      c.restore(s);
      return null;
    }
    return v;
  }

  bool fail() {
    c.restore(start);
    return false;
  }

  if (fixed(4) == null) return _null(fail);
  if (!c.matchChar(0x2D)) return _null(fail); // -
  if (fixed(2) == null) return _null(fail);
  if (!c.matchChar(0x2D)) return _null(fail);
  if (fixed(2) == null) return _null(fail);
  if (!c.matchChar(0x54)) return _null(fail); // T
  if (fixed(2) == null) return _null(fail);
  if (!c.matchChar(0x3A)) return _null(fail); // :
  if (fixed(2) == null) return _null(fail);
  if (!c.matchChar(0x3A)) return _null(fail);
  if (fixed(2) == null) return _null(fail);
  if (c.current == 0x2E) {
    // optional (?:\.\d+)
    c.matchChar(0x2E);
    if (c.takeWhile(isDigit) == null) return _null(fail);
  }
  if (!c.matchChar(0x5A)) return _null(fail); // Z
  return c.src.substring(start, c.pos);
}

String? _null(bool Function() f) {
  f();
  return null;
}

/// A rule that matches one literal from [values] case-insensitively, returning
/// the original-case capture. Longest option is tried first so that e.g.
/// `listns` wins over `list`.
ValueRule enumRule(List<String> values) {
  final ordered = [...values]..sort((a, b) => b.length.compareTo(a.length));
  return (Scanner c) {
    final start = c.save();
    for (final v in ordered) {
      if (c.matchLiteralCI(v)) return c.src.substring(start, c.pos);
    }
    return null;
  };
}

/// A rule reading a run of characters satisfying [pred] (min 1).
ValueRule charClass(bool Function(int) pred) => (Scanner c) => c.takeWhile(pred);

/// `[0-9]+|-1` — a commit sequence: digits, or the literal `-1` (sync/syncFrom).
String? commitSeqRule(Scanner c) {
  final d = uintRule(c);
  if (d != null) return d;
  return literal('-1')(c);
}

/// Read exactly [n] digits, or null (cursor unchanged on null).
String? _exactDigits(Scanner c, int n) {
  final start = c.save();
  for (var i = 0; i < n; i++) {
    if (c.atEnd || !isDigit(c.current)) {
      c.restore(start);
      return null;
    }
    c.pos++;
  }
  return c.src.substring(start, c.pos);
}

bool _isWord(int c) =>
    (c >= 0x30 && c <= 0x39) || // 0-9
    (c >= 0x41 && c <= 0x5A) || // A-Z
    (c >= 0x61 && c <= 0x7A) || // a-z
    c == 0x5F; // _

bool _isWordDash(int c) => _isWord(c) || c == 0x2D; // [\w-]

/// `[a-zA-Z0-9_]+`
String? alnumUnderscore(Scanner c) => c.takeWhile(_isWord);

/// `[a-zA-Z0-9_-]+`
String? alnumDashUnderscore(Scanner c) => c.takeWhile(_isWordDash);

/// `[\w-]+`
String? wordDash(Scanner c) => c.takeWhile(_isWordDash);

/// `[\w-]*` (may be empty)
String? wordDashStar(Scanner c) => c.takeWhile(_isWordDash, min: 0) ?? '';

/// `\w{6,}` — six or more word chars (otp value).
String? wordMin6(Scanner c) => c.takeWhile(_isWord, min: 6);

/// `.*` — zero or more of any char to end (keys' keyValue); never null.
String? restStar(Scanner c) => c.takeRest();

/// `:((?!0)\d+)?(,(\d+))*` — the stats statId class (leading colon required).
String? statIdRule(Scanner c) {
  final start = c.save();
  if (!c.matchChar($colon)) return null;
  if (!c.atEnd && isDigit(c.current) && c.current != 0x30) {
    c.takeWhile(isDigit); // (?!0)\d+
  }
  while (true) {
    final m = c.save();
    if (c.matchChar(0x2C) && c.takeWhile(isDigit) != null) continue; // ,(\d+)
    c.restore(m);
    break;
  }
  return c.src.substring(start, c.pos);
}

/// `(@[^:@\s]+)( @[^\s@]+)*` — a space-separated @sign list (config block).
String? configAtSignListRule(Scanner c) {
  final start = c.save();
  if (!c.matchChar($at) || c.takeWhile(notColonAtSpace) == null) {
    c.restore(start);
    return null;
  }
  while (true) {
    final m = c.save();
    if (c.matchChar($space) &&
        c.matchChar($at) &&
        c.takeWhile((ch) => ch != $at && notSpace(ch)) != null) {
      continue;
    }
    c.restore(m);
    break;
  }
  return c.src.substring(start, c.pos);
}

/// `[^:{\n]+` — the enroll listNamespace class.
String? notColonBraceNewline(Scanner c) => c.takeWhile(
    (ch) => ch != $colon && ch != 0x7B && ch != 0x0A && ch != 0x0D);

/// `[^@:\s]+` — the stream receiver class.
String? notAtColonSpace(Scanner c) =>
    c.takeWhile((ch) => ch != $at && ch != $colon && notSpace(ch));

/// `\d{4}-[01]?\d?-[0123]?\d?` — the loose partial-date class in notify:list.
String? notifyDateRule(Scanner c) {
  final start = c.save();
  if (_exactDigits(c, 4) == null) return null;
  if (!c.matchChar(0x2D)) {
    c.restore(start);
    return null;
  }
  if (!c.atEnd && (c.current == 0x30 || c.current == 0x31)) c.pos++; // [01]?
  if (!c.atEnd && isDigit(c.current)) c.pos++; // \d?
  if (!c.matchChar(0x2D)) {
    c.restore(start);
    return null;
  }
  if (!c.atEnd && c.current >= 0x30 && c.current <= 0x33) c.pos++; // [0123]?
  if (!c.atEnd && isDigit(c.current)) c.pos++; // \d?
  return c.src.substring(start, c.pos);
}

/// Shared engine for the `<first>((?!:{2})[^@])+` atKey classes: a first char
/// satisfying [firstOk], then one-or-more chars that are not `@` and do not
/// begin a `::`.
String? _atKeyNoDoubleColonNoAt(Scanner c, bool Function(int) firstOk) {
  final start = c.save();
  if (c.atEnd || !firstOk(c.current)) return null;
  c.pos++;
  var extra = 0;
  while (!c.atEnd) {
    final ch = c.current;
    if (ch == $at) break; // [^@]
    if (ch == $colon &&
        c.pos + 1 < c.src.length &&
        c.src.codeUnitAt(c.pos + 1) == $colon) {
      break; // (?!:{2})
    }
    c.pos++;
    extra++;
  }
  if (extra < 1) {
    c.restore(start);
    return null;
  }
  return c.src.substring(start, c.pos);
}

/// `[^:]((?!:{2})[^@])+` — llookup's atKey (first char non-colon).
String? keyNoDoubleColonNoAt(Scanner c) =>
    _atKeyNoDoubleColonNoAt(c, (ch) => ch != $colon);

/// `[^:@]((?!:{2})[^@])+` — notify's atKey (first char non-colon, non-at).
String? keyFirstNoColonAt(Scanner c) =>
    _atKeyNoDoubleColonNoAt(c, (ch) => ch != $colon && ch != $at);

/// `[\w\d\-\_]+` — the notify id class (word chars, digits, dash, underscore).
String? idRule(Scanner c) => c.takeWhile((ch) =>
    (ch >= 0x30 && ch <= 0x39) || // 0-9
    (ch >= 0x41 && ch <= 0x5A) || // A-Z
    (ch >= 0x61 && ch <= 0x7A) || // a-z
    ch == 0x5F || // _
    ch == 0x2D); // -

/// `[^\s:]+` — the notify notifier class (no whitespace, no colon).
String? notifierRule(Scanner c) =>
    c.takeWhile((ch) => ch != $colon && notSpace(ch));

/// `[^:@]((?!:{2})[^:@])+` — the update:meta atKey class (the `::` guard is
/// redundant here since `[^:@]` already excludes `:`, but kept faithful).
String? keyNoDoubleColonNoColonAt(Scanner c) {
  final start = c.save();
  if (c.atEnd || c.current == $colon || c.current == $at) return null;
  c.pos++; // [^:@]
  var extra = 0;
  while (!c.atEnd) {
    final ch = c.current;
    if (ch == $colon || ch == $at) break;
    c.pos++;
    extra++;
  }
  if (extra < 1) {
    c.restore(start);
    return null;
  }
  return c.src.substring(start, c.pos);
}

/// A case-insensitive literal, returning the original-case capture (for the
/// `privatekey:at_pkam_publickey` / `privatekey:at_secret` atKey alternatives).
ValueRule literal(String s) => (Scanner c) {
      final start = c.save();
      if (c.matchLiteralCI(s)) return c.src.substring(start, c.pos);
      return null;
    };

/// `@[^:@\s]+` — an atSign with a required leading `@` (scan's forAtSign).
String? atSignRequiredPrefix(Scanner c) {
  final start = c.save();
  if (!c.matchChar($at) || c.takeWhile(notColonAtSpace) == null) {
    c.restore(start);
    return null;
  }
  return c.src.substring(start, c.pos);
}

/// `(([^:\s])+)?(,([^:\s]+))*` — notify:all's forAtSign list (may be empty).
String? forAtSignListRule(Scanner c) {
  final start = c.save();
  bool notColonSpace(int ch) => ch != $colon && notSpace(ch);
  c.takeWhile(notColonSpace, min: 0);
  while (true) {
    final m = c.save();
    if (c.matchChar(0x2C) && c.takeWhile(notColonSpace) != null) continue;
    c.restore(m);
    break;
  }
  return c.src.substring(start, c.pos);
}

/// `true|false+` — notify:all's ccd class (`false+` = `fals` then one+ `e`;
/// faithfully reproduces the quirky source regex).
String? ccdPlusRule(Scanner c) {
  final start = c.save();
  if (c.matchLiteralCI('true')) return c.src.substring(start, c.pos);
  if (c.matchLiteralCI('fals') &&
      c.takeWhile((ch) => ch == 0x65 || ch == 0x45) != null) {
    return c.src.substring(start, c.pos);
  }
  c.restore(start);
  return null;
}

/// `@?[^:@\s]+` — an atSign with an optional leading `@` (used by `from`).
String? atSignOptionalPrefix(Scanner c) {
  final start = c.save();
  c.matchChar($at); // optional '@'
  final t = c.takeWhile(notColonAtSpace);
  if (t == null) {
    c.restore(start);
    return null;
  }
  return c.src.substring(start, c.pos);
}
