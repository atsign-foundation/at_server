import 'package:json_annotation/json_annotation.dart';
part 'enroll_datastore_value.g.dart';

@JsonSerializable()

/// Represents attributes for APKAM enrollment data
class EnrollDataStoreValue {
  late String sessionId;
  late String appName;
  late String deviceName;
  List<EnrollNamespace> namespaces = [];
  late String apkamPublicKey;
  EnrollRequestType? requestType;
  EnrollApproval? approval;
  EnrollDataStoreValue(
      this.sessionId, this.appName, this.deviceName, this.apkamPublicKey);

  factory EnrollDataStoreValue.fromJson(Map<String, dynamic> json) =>
      _$EnrollDataStoreValueFromJson(json);

  Map<String, dynamic> toJson() => _$EnrollDataStoreValueToJson(this);
}

class EnrollNamespace {
  String name;
  String access;
  EnrollNamespace(this.name, this.access);
  EnrollNamespace.fromJson(Map<String, dynamic> json)
      : name = json['name'],
        access = json['access'];
  Map<String, dynamic> toJson() => {
        'name': name,
        'access': access,
      };

  @override
  String toString() {
    return '{name: $name, access: $access}';
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

enum EnrollStatus { pending, approved, denied }

enum EnrollRequestType { newEnrollment, changeEnrollment }
