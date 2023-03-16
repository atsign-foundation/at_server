extension AtDateTimeExtensions on DateTime {
  /// Returns a new DateTime object, in UTC timezone, with microseconds zeroed out.
  /// We currently need to constrain various DateTime values to millisecond
  /// precision because Hive only stores [DateTime]s to millisecond precision.
  /// see https://github.com/hivedb/hive/issues/474 for details.
  DateTime toUtcMillisecondsPrecision() {
    return DateTime.fromMillisecondsSinceEpoch((microsecondsSinceEpoch / 1000).floor(), isUtc: true);
  }
}

void main() {
  DateTime now = DateTime.now().toUtc();
  print (now.microsecondsSinceEpoch);
  print (now.toUtcMillisecondsPrecision().microsecondsSinceEpoch);
}
