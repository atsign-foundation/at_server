import 'package:json_annotation/json_annotation.dart';

part 'enroll_datastore_value.g.dart';

/// Represents attributes for APKAM enrollment data
@JsonSerializable()
class EnrollDataStoreValue {
  late String sessionId;
  late String appName;
  late String deviceName;

  // map for representing namespace access. key will be the namespace, value will be the access
  // e.g {'wavi':'r', 'buzz':'rw'}
  Map<String, String> namespaces = {};
  late String apkamPublicKey;
  EnrollRequestType? requestType;
  EnrollApproval? approval;
  DateTime? expiresAt;

  EnrollDataStoreValue(
      this.sessionId, this.appName, this.deviceName, this.apkamPublicKey);

  factory EnrollDataStoreValue.fromJson(Map<String, dynamic> json) =>
      _$EnrollDataStoreValueFromJson(json);

  Map<String, dynamic> toJson() => _$EnrollDataStoreValueToJson(this);

  bool isExpired() {
    if (expiresAt != null && DateTime.now().toUtc().isAfter(expiresAt!)) {
      return true;
    }
    return false;
  }
}

class EnrollApproval {
  String state;

  EnrollApproval(this.state);

  EnrollApproval.fromJson(Map<String, dynamic> json) : state = json['state'];

  Map<String, dynamic> toJson() => {
        'state': state,
      };

  @override
  String toString() {
    return '{state: $state}';
  }
}

enum EnrollStatus { pending, approved, denied, revoked, expired }

enum EnrollRequestType { newEnrollment, changeEnrollment }
