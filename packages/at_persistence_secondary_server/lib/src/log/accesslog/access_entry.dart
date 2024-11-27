import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';
import 'package:hive_ce/hive.dart';
part 'access_entry.g.dart';

/// Represents an access entry with fromAtSign, requestDateTime, verbName and key lookup(if any).
@HiveType(typeId: 4)
class AccessLogEntry extends HiveObject {
  @HiveField(0)
  final String? fromAtSign;

  @HiveField(1)
  final DateTime? requestDateTime;

  @HiveField(2)
  final String? verbName;

  @HiveField(3)
  final String? lookupKey;

  AccessLogEntry(
      this.fromAtSign, this.requestDateTime, this.verbName, this.lookupKey);

  Map toJson() => {
        'fromAtSign': fromAtSign,
        'requestDateTime': requestDateTime,
        'verbName': verbName,
        'lookupKey': lookupKey
      };

  @override
  String toString() {
    return 'AccessLogEntry{fromAtSign: $fromAtSign, requestDateTime: $requestDateTime, verbName:$verbName, lookupKey:$lookupKey}';
  }
}
