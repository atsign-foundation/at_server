/// One exchange counted against a quarantined atSign: when it was accepted,
/// and the bytes of its notification, or 0 for a lookup.
class CountedExchange {
  final DateTime at;
  final int bytes;

  const CountedExchange(this.at, this.bytes);
}

/// A quarantined atSign's standing in one open namespace: when it was first
/// counted there, and the exchanges counted in the current window.
class QuarantineEntry {
  final DateTime firstContact;
  final List<CountedExchange> counted;

  QuarantineEntry(this.firstContact, [List<CountedExchange>? counted])
      : counted = counted ?? [];

  /// This entry with only the exchanges counted after [start], or null when
  /// none were, so that the atSign drops back to none.
  QuarantineEntry? since(DateTime start) {
    final List<CountedExchange> kept =
        counted.where((exchange) => exchange.at.isAfter(start)).toList();
    return kept.isEmpty ? null : QuarantineEntry(firstContact, kept);
  }

  /// The bytes of the notifications counted.
  int get bytes => counted.fold(0, (sum, exchange) => sum + exchange.bytes);

  /// This entry with [exchange] counted too.
  QuarantineEntry plus(CountedExchange exchange) =>
      QuarantineEntry(firstContact, [...counted, exchange]);
}
