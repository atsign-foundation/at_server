/// Represents an access entry with fromAtSign, requestDateTime, verbName and key lookup(if any).
class AccessLogEntry {
  final String? _fromAtSign;

  final DateTime? _requestDateTime;

  final String? _verbName;

  final String? _lookupKey;

  AccessLogEntry(
      this._fromAtSign, this._requestDateTime, this._verbName, this._lookupKey);

  String? get fromAtSign => _fromAtSign;

  DateTime? get requestDateTime => _requestDateTime;

  String? get verbName => _verbName;

  String? get lookupKey => _lookupKey;

  Map toJson() => {
        'fromAtSign': _fromAtSign,
        'requestDateTime': _requestDateTime,
        'verbName': _verbName,
        'lookupKey': _lookupKey
      };

  @override
  String toString() {
    return 'AccessLogEntry{fromAtSign: $_fromAtSign, requestDateTime: $_requestDateTime, verbName:$_verbName, lookupKey:$_lookupKey}';
  }
}
