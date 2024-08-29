/// Represents an access entry with fromAtSign, requestDateTime, verbName and key lookup(if any).
class AccessLogEntry {
  final String? _fromAtSign;

  final DateTime? _requestDateTime;

  final String? _verbName;

  final String? _lookupKey;

  late int
      key; // hive new version doesn't have method to get auto increment key.

  AccessLogEntry(
      this._fromAtSign, this._requestDateTime, this._verbName, this._lookupKey);

  String? get fromAtSign => _fromAtSign;

  DateTime? get requestDateTime => _requestDateTime;

  String? get verbName => _verbName;

  String? get lookupKey => _lookupKey;

  Map toJson() => {
        'fromAtSign': _fromAtSign,
        'requestDateTime': _requestDateTime.toString(),
        'verbName': _verbName,
        'lookupKey': _lookupKey
      };
  factory AccessLogEntry.fromJson(dynamic json) {
    return AccessLogEntry(
        json['fromAtSign'],
        DateTime.parse(json['requestDateTime']),
        json['verbName'],
        json['lookupKey']);
  }

  @override
  String toString() {
    return 'AccessLogEntry{fromAtSign: $_fromAtSign, requestDateTime: $_requestDateTime, verbName:$_verbName, lookupKey:$_lookupKey}';
  }
}
