import 'scanner.dart';
import 'value_rules.dart';

/// The output map a grammar builds: named group -> captured value (or null when
/// the group did not participate). Mirrors the server's
/// `regex_util.processMatches` semantics exactly.
typedef Groups = Map<String, String?>;

/// A continuation: parse the remainder of the segment list. Returns true if the
/// rest of the grammar (and the end-of-input anchor) matched.
typedef Cont = bool Function();

/// A grammar building block. [match] attempts to consume from the cursor and
/// then invokes [cont] to parse what follows, giving regex-style backtracking:
/// a segment that can match optionally will, if the continuation fails, undo
/// its writes, restore the cursor, and try the alternative.
///
/// Contract: when [match] returns false it MUST leave [c] and [out] exactly as
/// it found them.
abstract class Segment {
  bool match(Scanner c, Groups out, Cont cont);

  /// Every group name this segment can produce — used to null-pre-seed the map.
  Iterable<String> get fieldNames;
}

/// Run [segs] from index [i], chaining continuations, ending in [cont].
bool matchSequence(List<Segment> segs, int i, Scanner c, Groups out, Cont cont) {
  if (i == segs.length) return cont();
  return segs[i].match(c, out, () => matchSequence(segs, i + 1, c, out, cont));
}

/// A required, uncaptured literal (e.g. a structural `:` or a keyword).
class Lit extends Segment {
  final String literal;
  Lit(this.literal);

  @override
  bool match(Scanner c, Groups out, Cont cont) {
    final mark = c.save();
    if (!c.matchLiteralCI(literal)) return false;
    if (cont()) return true;
    c.restore(mark);
    return false;
  }

  @override
  Iterable<String> get fieldNames => const [];
}

/// A captured value with an optional [leader] literal and optional [trailer].
/// When [optional] is true it corresponds to a regex `(...)?` group.
class Field extends Segment {
  final String name;
  final String leader;
  final String trailer;

  /// When true the [trailer] is consumed only if present (regex `...:?`);
  /// when false a set [trailer] is required.
  final bool optionalTrailer;
  final ValueRule rule;
  final bool optional;

  Field(
    this.name, {
    this.leader = '',
    this.trailer = '',
    this.optionalTrailer = false,
    required this.rule,
    this.optional = false,
  });

  bool _take(Scanner c, Groups out, Cont cont) {
    final mark = c.save();
    if (leader.isNotEmpty && !c.matchLiteralCI(leader)) {
      c.restore(mark);
      return false;
    }
    final v = rule(c);
    if (v == null) {
      c.restore(mark);
      return false;
    }
    if (trailer.isNotEmpty) {
      final matched = c.matchLiteralCI(trailer);
      if (!matched && !optionalTrailer) {
        c.restore(mark);
        return false;
      }
    }
    final prev = out[name];
    out[name] = v;
    if (cont()) return true;
    out[name] = prev;
    c.restore(mark);
    return false;
  }

  @override
  bool match(Scanner c, Groups out, Cont cont) {
    if (_take(c, out, cont)) return true;
    // Optional: fall through to "not matched"; required: reject.
    return optional && cont();
  }

  @override
  Iterable<String> get fieldNames => [name];
}

/// An optional, uncaptured literal — a regex `(:cached)?` with no named group.
class OptLit extends Segment {
  final String literal;
  OptLit(this.literal);

  @override
  bool match(Scanner c, Groups out, Cont cont) {
    final mark = c.save();
    if (c.matchLiteralCI(literal)) {
      if (cont()) return true;
      c.restore(mark);
    }
    return cont();
  }

  @override
  Iterable<String> get fieldNames => const [];
}

/// An optional, uncaptured alternation of literals — a regex `(:(a|b|c))?`
/// with no named group (e.g. info's `(:(brief|mtls|mtlsbrief))?`). Each
/// candidate is tried in order with the continuation, so a shorter option that
/// leaves an unparsable tail gives way to a longer one.
class OptAlt extends Segment {
  final List<String> literals;
  OptAlt(this.literals);

  @override
  bool match(Scanner c, Groups out, Cont cont) {
    for (final lit in literals) {
      final mark = c.save();
      if (c.matchLiteralCI(lit)) {
        if (cont()) return true;
      }
      c.restore(mark);
    }
    return cont();
  }

  @override
  Iterable<String> get fieldNames => const [];
}

/// A greedy captured run `pred+` with regex-style give-back: it consumes the
/// maximal run, then retries the continuation with progressively shorter
/// captures (down to [min]) until one succeeds. Needed for `.+`-with-trailing-
/// structure patterns such as pkam's `(?<enrollmentId>.+):(?<signature>.+$)`.
class GreedyField extends Segment {
  final String name;
  final String leader;
  final String trailer;
  final bool Function(int codeUnit) pred;

  /// Optional constraint on the FIRST character of the run (e.g. lookup's atKey
  /// `(?:[^:]).+`, where only the first char is restricted). Defaults to [pred].
  final bool Function(int codeUnit) firstPred;
  final int min;
  final bool optional;

  GreedyField(
    this.name, {
    this.leader = '',
    this.trailer = '',
    bool Function(int codeUnit)? pred,
    bool Function(int codeUnit)? firstPred,
    this.min = 1,
    this.optional = false,
  })  : pred = pred ?? _anyChar,
        firstPred = firstPred ?? pred ?? _anyChar;

  static bool _anyChar(int c) => c != 0x0A && c != 0x0D; // regex `.`

  @override
  bool match(Scanner c, Groups out, Cont cont) {
    final mark = c.save();
    if (leader.isNotEmpty && !c.matchLiteralCI(leader)) {
      c.restore(mark);
      return optional && cont();
    }
    final runStart = c.pos;
    if (runStart >= c.src.length || !firstPred(c.src.codeUnitAt(runStart))) {
      c.restore(mark);
      return optional && cont();
    }
    var runEnd = c.pos + 1;
    while (runEnd < c.src.length && pred(c.src.codeUnitAt(runEnd))) {
      runEnd++;
    }
    for (var end = runEnd; end - runStart >= min; end--) {
      c.pos = end;
      if (trailer.isNotEmpty && !c.matchLiteralCI(trailer)) continue;
      final prev = out[name];
      out[name] = c.src.substring(runStart, end);
      if (cont()) return true;
      out[name] = prev;
    }
    c.restore(mark);
    return optional && cont();
  }

  @override
  Iterable<String> get fieldNames => [name];
}

/// A captured field that is only attempted when [gate] holds for the map built
/// so far — models a regex lookbehind that depends on an earlier group (e.g.
/// otp's `(?<=put:)` value, stats' `(?<=:3:|:15:)` regex). Always optional.
class GatedField extends Segment {
  final String name;
  final String leader;
  final ValueRule rule;
  final bool Function(Groups out) gate;

  GatedField(this.name,
      {this.leader = '', required this.rule, required this.gate});

  @override
  bool match(Scanner c, Groups out, Cont cont) {
    if (gate(out)) {
      final mark = c.save();
      if (leader.isEmpty || c.matchLiteralCI(leader)) {
        final v = rule(c);
        if (v != null) {
          final prev = out[name];
          out[name] = v;
          if (cont()) return true;
          out[name] = prev;
        }
      }
      c.restore(mark);
    }
    return cont();
  }

  @override
  Iterable<String> get fieldNames => [name];
}

/// Optional single whitespace char (regex `\s?`), uncaptured.
class OptWs extends Segment {
  @override
  bool match(Scanner c, Groups out, Cont cont) {
    final mark = c.save();
    if (!c.atEnd && _isWs(c.current)) {
      c.pos++;
      if (cont()) return true;
      c.restore(mark);
    }
    return cont();
  }

  static bool _isWs(int c) =>
      c == 0x20 || c == 0x09 || c == 0x0B || c == 0x0C || c == 0x0D;

  @override
  Iterable<String> get fieldNames => const [];
}

/// An optional empty-capture flag: `(:nc(?<noCommit>))?`-style. When the wire
/// token is present the group is set to '' (empty string), else stays null.
class Flag extends Segment {
  final String name;
  final String wire;
  Flag(this.name, this.wire);

  @override
  bool match(Scanner c, Groups out, Cont cont) {
    final mark = c.save();
    if (c.matchLiteralCI(wire)) {
      final prev = out[name];
      out[name] = '';
      if (cont()) return true;
      out[name] = prev;
      c.restore(mark);
    }
    return cont();
  }

  @override
  Iterable<String> get fieldNames => [name];
}

/// The reused `(:((?<publicScope>public)|(@(?<forAtSign>[^:@\s]+))))?`
/// alternation: an optional `:public` OR `:@someAtSign`, always followed by the
/// key's own `:` (which the next segment consumes). The trailing-`:` lookahead
/// lets an atKey that merely starts with "public" fall through correctly.
class PublicOrForAtSign extends Segment {
  final String publicName;
  final String forName;

  /// When true this is a required group (notify's `:(public|@x)` with no `?`);
  /// when false it is optional (`(:(public|@x))?`).
  final bool required;
  PublicOrForAtSign(this.publicName, this.forName, {this.required = false});

  @override
  bool match(Scanner c, Groups out, Cont cont) {
    final mark = c.save();
    if (c.matchChar($colon)) {
      // :public
      final afterColon = c.save();
      if (c.matchLiteralCI('public') && c.current == $colon) {
        final prev = out[publicName];
        out[publicName] = c.src.substring(afterColon, c.pos);
        if (cont()) return true;
        out[publicName] = prev;
      }
      c.restore(afterColon);
      // :@forAtSign
      if (c.matchChar($at)) {
        final v = tokenNoColonAtSpace(c);
        if (v != null && c.current == $colon) {
          final prev = out[forName];
          out[forName] = v;
          if (cont()) return true;
          out[forName] = prev;
        }
      }
    }
    c.restore(mark);
    // Optional: fall through to "not present"; required: reject.
    return required ? false : cont();
  }

  @override
  Iterable<String> get fieldNames => [publicName, forName];
}

/// A terminal alternation of sub-sequences (e.g. update's `:json:` branch vs
/// the metadata+key+value branch). Each branch is tried in order; the first
/// whose sequence — followed by [cont] — matches wins. Branches must be
/// self-delimiting: the continuation still runs after the chosen branch.
class Alt extends Segment {
  final List<List<Segment>> branches;
  Alt(this.branches);

  @override
  bool match(Scanner c, Groups out, Cont cont) {
    for (final branch in branches) {
      final mark = c.save();
      if (matchSequence(branch, 0, c, out, cont)) return true;
      c.restore(mark);
    }
    return false;
  }

  @override
  Iterable<String> get fieldNames =>
      [for (final b in branches) ...b.expand((s) => s.fieldNames)];
}
