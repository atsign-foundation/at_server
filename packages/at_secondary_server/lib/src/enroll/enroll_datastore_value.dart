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
  String? encryptedAPKAMSymmetricKey;
  Duration apkamKeysExpiryDuration = Duration(milliseconds: 0);

  /// Opaque per-APKAM metadata stored by the client (WP-SS).
  /// The server treats this as an opaque JSON map and returns it verbatim in
  /// enroll:listfornamespace responses. Key packages live under
  /// metadata['keyPackages'] by convention.
  Map<String, dynamic>? metadata;

  EnrollDataStoreValue(
      this.sessionId, this.appName, this.deviceName, this.apkamPublicKey);

  factory EnrollDataStoreValue.fromJson(Map<String, dynamic> json) =>
      _$EnrollDataStoreValueFromJson(json);

  Map<String, dynamic> toJson() => _$EnrollDataStoreValueToJson(this);

  Map<String, dynamic> toJsonExtended() {
    final m = toJson();
    m['status'] = approval?.state;
    m['namespace'] = m['namespaces'];
    return m;
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

enum EnrollRequestType { newEnrollment, changeEnrollment }
