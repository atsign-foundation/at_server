// GENERATED CODE - DO NOT MODIFY BY HAND
// dart run build_runner build - to generate this file

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
      ..namespaces = (json['namespaces'] as List<dynamic>)
          .map((e) => EnrollNamespace.fromJson(e as Map<String, dynamic>))
          .toList()
      ..requestType =
          $enumDecodeNullable(_$EnrollRequestTypeEnumMap, json['requestType'])
      ..approval = json['approval'] == null
          ? null
          : EnrollApproval.fromJson(json['approval'] as Map<String, dynamic>);

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
    };

const _$EnrollRequestTypeEnumMap = {
  EnrollRequestType.newEnrollment: 'newEnrollment',
  EnrollRequestType.changeEnrollment: 'changeEnrollment',
};
