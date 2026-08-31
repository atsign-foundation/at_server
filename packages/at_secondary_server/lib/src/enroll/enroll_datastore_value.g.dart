// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'enroll_datastore_value.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

EnrollDataStoreValue _$EnrollDataStoreValueFromJson(
        Map<String, dynamic> json) =>
    EnrollDataStoreValue(
      json['sessionId'] as String,
      json['appName'] as String,
      json['deviceName'] as String,
      json['apkamPublicKey'] as String,
    )
      ..namespaces = Map<String, String>.from(json['namespaces'] as Map)
      ..requestType =
          $enumDecodeNullable(_$EnrollRequestTypeEnumMap, json['requestType'])
      ..approval = json['approval'] == null
          ? null
          : EnrollApproval.fromJson(json['approval'] as Map<String, dynamic>)
      ..encryptedAPKAMSymmetricKey =
          json['encryptedAPKAMSymmetricKey'] as String?
      ..apkamKeysExpiryDuration =
          Duration(milliseconds: json['apkamKeysExpiryInMillis'] ?? 0)
      ..metadata = (json['metadata'] as Map<String, dynamic>?)
      ..signingAlgo = json['signingAlgo'] as String?
      ..apsk = (json['apsk'] as Map<String, dynamic>?)
      ..apskLegacy = json['apskLegacy'] as String?
      ..parentEnrollmentId = json['parentEnrollmentId'] as String?
      ..predecessorCapArmedAt = json['predecessorCapArmedAt'] == null
          ? null
          : DateTime.parse(json['predecessorCapArmedAt'] as String);

Map<String, dynamic> _$EnrollDataStoreValueToJson(
        EnrollDataStoreValue instance) =>
    <String, dynamic>{
      'sessionId': instance.sessionId,
      'appName': instance.appName,
      'deviceName': instance.deviceName,
      'namespaces': instance.namespaces,
      'apkamPublicKey': instance.apkamPublicKey,
      'requestType': _$EnrollRequestTypeEnumMap[instance.requestType],
      'approval': instance.approval,
      'encryptedAPKAMSymmetricKey': instance.encryptedAPKAMSymmetricKey,
      'apkamKeysExpiryInMillis':
          instance.apkamKeysExpiryDuration.inMilliseconds,
      if (instance.metadata != null) 'metadata': instance.metadata,
      if (instance.signingAlgo != null) 'signingAlgo': instance.signingAlgo,
      if (instance.apsk != null) 'apsk': instance.apsk,
      if (instance.apskLegacy != null) 'apskLegacy': instance.apskLegacy,
      if (instance.parentEnrollmentId != null)
        'parentEnrollmentId': instance.parentEnrollmentId,
      if (instance.predecessorCapArmedAt != null)
        'predecessorCapArmedAt': instance.predecessorCapArmedAt!.toIso8601String(),
    };

const _$EnrollRequestTypeEnumMap = {
  EnrollRequestType.newEnrollment: 'newEnrollment',
  EnrollRequestType.changeEnrollment: 'changeEnrollment',
};
