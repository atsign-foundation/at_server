import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';
import 'package:hive_ce/hive.dart';

/// Represents an access entry with fromAtSign, requestDateTime, verbName and key lookup(if any).
class AccessLogEntry extends HiveObject {
  final String? fromAtSign;

  final DateTime? requestDateTime;

  final String? verbName;

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

