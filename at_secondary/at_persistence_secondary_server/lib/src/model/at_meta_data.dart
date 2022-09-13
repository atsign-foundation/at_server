import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';
import 'package:hive/hive.dart';

@HiveType(typeId: 1)
class AtMetaData extends HiveObject {
  @HiveField(0)
  String? createdBy;

  @HiveField(1)
  String? updatedBy;

  @HiveField(2)
  DateTime? createdAt;

  @HiveField(3)
  DateTime? updatedAt;

  @HiveField(4)
  DateTime? expiresAt;

  @HiveField(5)
  String? status;

  @HiveField(6)
  int? version;

  @HiveField(7)
  DateTime? availableAt;

  @HiveField(8)
  int? ttb;

  @HiveField(9)
  int? ttl;

  @HiveField(10)
  int? ttr;

  @HiveField(11)
  DateTime? refreshAt;

  @HiveField(12)
  bool? isCascade;

  @HiveField(13)
  bool? isBinary;

  @HiveField(14)
  bool? isEncrypted;

  @HiveField(15)
  String? dataSignature;

  @HiveField(16)
  String? sharedKeyEnc;

  @HiveField(17)
  String? pubKeyCS;

  @HiveField(18)
  String? encoding;

  @override
  String toString() {
    return toJson().toString();
  }

  Map toJson() {
    // ignore: omit_local_variable_types
    Map map = {};
    map['createdBy'] = createdBy;
    map['updatedBy'] = updatedBy;
    map['createdAt'] = createdAt?.toUtc().toString();
    map['updatedAt'] = updatedAt?.toUtc().toString();
    map['availableAt'] = availableAt?.toUtc().toString();
    map['expiresAt'] = expiresAt?.toUtc().toString();
    map['refreshAt'] = refreshAt?.toUtc().toString();
    map['status'] = status;
    map['version'] = version;
    map[AT_TTL] = ttl;
    map[AT_TTB] = ttb;
    map[AT_TTR] = ttr;
    map[CCD] = isCascade;
    map[IS_BINARY] = isBinary;
    map[IS_ENCRYPTED] = isEncrypted;
    map[PUBLIC_DATA_SIGNATURE] = dataSignature;
    map[SHARED_KEY_ENCRYPTED] = sharedKeyEnc;
    map[SHARED_WITH_PUBLIC_KEY_CHECK_SUM] = pubKeyCS;
    map[ENCODING] = encoding;
    return map;
  }

  AtMetaData fromJson(Map json) {
    try {
      createdBy = json['createdBy'];
      updatedBy = json['updatedBy'];
      createdAt = DateTime.parse(json['createdAt']);
      updatedAt = DateTime.parse(json['updatedAt']);
      expiresAt = (json['expiresAt'] == null || json['expiresAt'] == 'null')
          ? null
          : DateTime.parse(json['expiresAt']);
      refreshAt = (json['refreshAt'] == null || json['refreshAt'] == 'null')
          ? null
          : DateTime.parse(json['refreshAt']);
      availableAt =
          (json['availableAt'] == null || json['availableAt'] == 'null')
              ? null
              : DateTime.parse(json['availableAt']);
      status = json['status'];
      version = (json['version'] is String)
          ? int.parse(json['version'])
          : (json['version'] == null)
              ? 0
              : json['version'];
      ttl = (json[AT_TTL] is String)
          ? int.parse(json[AT_TTL])
          : (json[AT_TTL] == null)
              ? 0
              : json[AT_TTL];
      ttb = (json[AT_TTB] is String)
          ? int.parse(json[AT_TTB])
          : (json[AT_TTB] == null)
              ? 0
              : json[AT_TTB];
      ttr = (json[AT_TTR] is String)
          ? int.parse(json[AT_TTR])
          : (json[AT_TTR] == null)
              ? 0
              : json[AT_TTR];
      isCascade = json[CCD];
      isBinary = json[IS_BINARY];
      isEncrypted = json[IS_ENCRYPTED];
      dataSignature = json[PUBLIC_DATA_SIGNATURE];
      sharedKeyEnc = json[SHARED_KEY_ENCRYPTED];
      pubKeyCS = json[SHARED_WITH_PUBLIC_KEY_CHECK_SUM];
      encoding = json[ENCODING];
    } catch (error) {
      // ignore: prefer_interpolation_to_compose_strings
      print('AtMetaData.fromJson error: ' + error.toString());
    }
    return this;
  }
}

class AtMetaDataAdapter extends TypeAdapter<AtMetaData> {
  @override
  final int typeId = typeAdapterMap['AtMetaDataAdapter'];

  @override
  AtMetaData read(BinaryReader reader) {
    var numOfFields = reader.readByte();
    var fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AtMetaData()
      ..createdBy = fields[0] as String?
      ..updatedBy = fields[1] as String?
      ..createdAt = fields[2] as DateTime?
      ..updatedAt = fields[3] as DateTime?
      ..expiresAt = fields[4] as DateTime?
      ..status = fields[5] as String?
      ..version = fields[6] as int?
      ..ttb = fields[7] as int?
      ..ttl = fields[8] as int?
      ..ttr = fields[9] as int?
      ..refreshAt = fields[10] as DateTime?
      ..isCascade = fields[11] as bool?
      ..availableAt = fields[12] as DateTime?
      ..isBinary = fields[13] as bool?
      ..isEncrypted = fields[14]
      ..dataSignature = fields[15]
      ..sharedKeyEnc = fields[16]
      ..pubKeyCS = fields[17]
      ..encoding = fields[18];
  }

  @override
  void write(BinaryWriter writer, AtMetaData obj) {
    writer
      ..writeByte(19)
      ..writeByte(0)
      ..write(obj.createdBy)
      ..writeByte(1)
      ..write(obj.updatedBy)
      ..writeByte(2)
      ..write(obj.createdAt)
      ..writeByte(3)
      ..write(obj.updatedAt)
      ..writeByte(4)
      ..write(obj.expiresAt)
      ..writeByte(5)
      ..write(obj.status)
      ..writeByte(6)
      ..write(obj.version)
      ..writeByte(7)
      ..write(obj.ttb)
      ..writeByte(8)
      ..write(obj.ttl)
      ..writeByte(9)
      ..write(obj.ttr)
      ..writeByte(10)
      ..write(obj.refreshAt)
      ..writeByte(11)
      ..write(obj.isCascade)
      ..writeByte(12)
      ..write(obj.availableAt)
      ..writeByte(13)
      ..write(obj.isBinary)
      ..writeByte(14)
      ..write(obj.isEncrypted)
      ..writeByte(15)
      ..write(obj.dataSignature)
      ..writeByte(16)
      ..write(obj.sharedKeyEnc)
      ..writeByte(17)
      ..write(obj.pubKeyCS)
      ..writeByte(18)
      ..write(obj.encoding);
  }
}
