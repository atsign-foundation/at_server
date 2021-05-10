import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';
import 'package:hive/hive.dart';

/// Represents an access entry with fromAtSign, requestDateTime, verbName and key lookup(if any).
@HiveType()
class AccessLogEntry extends HiveObject {
  @HiveField(0)
  String _fromAtSign;

  @HiveField(1)
  DateTime _requestDateTime;

  @HiveField(2)
  String _verbName;

  @HiveField(3)
  String _lookupKey;

  AccessLogEntry(
      this._fromAtSign, this._requestDateTime, this._verbName, this._lookupKey);

  String get fromAtSign => _fromAtSign;

  DateTime get requestDateTime => _requestDateTime;

  String get verbName => _verbName;

  String get lookupKey => _lookupKey;

  Map toJson() => {
        'fromAtSign': _fromAtSign,
        'requestDateTime': _requestDateTime.toUtc().toString(),
        'verbName': _verbName,
        'lookupKey': _lookupKey
      };

  @override
  String toString() {
    return 'AccessLogEntry{fromAtSign: $_fromAtSign, requestDateTime: $_requestDateTime, verbName:$_verbName, lookupKey:$_lookupKey}';
  }

  AccessLogEntry.fromJson(Map<String, dynamic> json) {
    _fromAtSign = json['fromAtSign'];
    _requestDateTime = DateTime.parse(json['requestDateTime'] as String);
    _verbName = json['verbName'];
    _lookupKey = json['lookupKey'];
  }

}

/// Hive adapter for [AccessEntry]
class AccessLogEntryAdapter extends TypeAdapter<AccessLogEntry> {
  @override
  final typeId = typeAdapterMap['AccessLogEntryAdapter'];

  @override
  AccessLogEntry read(BinaryReader reader) {
    var numOfFields = reader.readByte();
    var fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read()
    };
    var accessLogEntry = AccessLogEntry(fields[0] as String,
        fields[1] as DateTime, fields[2] as String, fields[3] as String);
    return accessLogEntry;
  }

  @override
  void write(BinaryWriter writer, AccessLogEntry accessLogEntry) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(accessLogEntry.fromAtSign)
      ..writeByte(1)
      ..write(accessLogEntry.requestDateTime)
      ..writeByte(2)
      ..write(accessLogEntry.verbName)
      ..writeByte(3)
      ..write(accessLogEntry.lookupKey);
  }
}
