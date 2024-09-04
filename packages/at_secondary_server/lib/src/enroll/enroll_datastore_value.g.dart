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
      ..apkamKeysExpiryDuration = (json['apkamExpiryInMillis'] == null)
          ? null
          : Duration(milliseconds: json['apkamExpiryInMillis']);

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
      'apkamExpiryInMillis': instance.apkamKeysExpiryDuration?.inMilliseconds,
    };

const _$EnrollRequestTypeEnumMap = {
  EnrollRequestType.newEnrollment: 'newEnrollment',
  EnrollRequestType.changeEnrollment: 'changeEnrollment',
};
