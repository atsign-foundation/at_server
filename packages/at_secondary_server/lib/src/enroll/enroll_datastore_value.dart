//TODO documentation
// there may be a  easier way to implement this class using a dart/3rd party package - TODO explore
class EnrollDataStoreValue {
  late String sessionId;
  late String appName;
  late String deviceName;
  List<EnrollNamespace> namespaces = [];
  late String apkamPublicKey;
  String? requestType;
  EnrollApproval? approval;
  EnrollDataStoreValue(
      this.sessionId, this.appName, this.deviceName, this.apkamPublicKey);
  EnrollDataStoreValue.fromJson(Map<String, dynamic> json) {
    sessionId = json['sessionId'];
    appName = json['appName'];
    deviceName = json['deviceName'];
    apkamPublicKey = json['apkamPublicKey'];
    requestType = json['requestType'];
    approval = EnrollApproval.fromJson(json['approval']);
    json['namespaces'].forEach((e) {
      namespaces.add(EnrollNamespace.fromJson(e));
    });
  }

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'appName': appName,
        'deviceName': deviceName,
        'namespaces': namespaces,
        'apkamPublicKey': apkamPublicKey,
        'requestType': requestType,
        'approval': approval
      };
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
