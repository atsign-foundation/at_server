import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
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

  @HiveField(19)
  String? encKeyName;

  @HiveField(20)
  String? encAlgo;

  @HiveField(21)
  String? ivNonce;

  @HiveField(22)
  String? skeEncKeyName;

  @HiveField(23)
  String? skeEncAlgo;

  @override
  String toString() {
    return toJson().toString();
  }

  AtMetaData();

  Metadata toCommonsMetadata() {
    return Metadata()
      ..ttl = ttl
      ..ttb = ttb
      ..ttr = ttr
      ..ccd = isCascade
      ..isBinary = isBinary
      ..isEncrypted = isEncrypted
      ..dataSignature = dataSignature
      ..sharedKeyEnc = sharedKeyEnc
      ..pubKeyCS = pubKeyCS
      ..encoding = encoding
      ..encKeyName = encKeyName
      ..encAlgo = encAlgo
      ..ivNonce = ivNonce
      ..skeEncKeyName = skeEncKeyName
      ..skeEncAlgo = skeEncAlgo;
  }

  factory AtMetaData.fromCommonsMetadata(Metadata metadata) {
    var atMetadata = AtMetaData();
    atMetadata
      ..ttl = metadata.ttl
      ..ttb = metadata.ttb
      ..ttr = metadata.ttr
      ..isCascade = metadata.ccd
      ..isBinary = metadata.isBinary
      ..isEncrypted = metadata.isEncrypted
      ..dataSignature = metadata.dataSignature
      ..sharedKeyEnc = metadata.sharedKeyEnc
      ..pubKeyCS = metadata.pubKeyCS
      ..encoding = metadata.encoding
      ..encKeyName = metadata.encKeyName
      ..encAlgo = metadata.encAlgo
      ..ivNonce = metadata.ivNonce
      ..skeEncKeyName = metadata.skeEncKeyName
      ..skeEncAlgo = metadata.skeEncAlgo;
    return AtMetadataBuilder(newAtMetaData: atMetadata).build();
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
    map[AtConstants.ttl] = ttl;
    map[AtConstants.ttb] = ttb;
    map[AtConstants.ttr] = ttr;
    map[AtConstants.ccd] = isCascade;
    map[AtConstants.isBinary] = isBinary;
    map[AtConstants.isEncrypted] = isEncrypted;
    map[AtConstants.publicDataSignature] = dataSignature;
    map[AtConstants.sharedKeyEncrypted] = sharedKeyEnc;
    map[AtConstants.sharedWithPublicKeyCheckSum] = pubKeyCS;
    map[AtConstants.encoding] = encoding;
    map[AtConstants.encryptingKeyName] = encKeyName;
    map[AtConstants.encryptingAlgo] = encAlgo;
    map[AtConstants.ivOrNonce] = ivNonce;
    map[AtConstants.sharedKeyEncryptedEncryptingKeyName] = skeEncKeyName;
    map[AtConstants.sharedKeyEncryptedEncryptingAlgo] = skeEncAlgo;
    return map;
  }

  factory AtMetaData.fromJson(Map json) {
    return AtMetaData().fromJson(json);
  }

  AtMetaData fromJson(Map json) {
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
    availableAt = (json['availableAt'] == null || json['availableAt'] == 'null')
        ? null
        : DateTime.parse(json['availableAt']);
    status = json['status'];
    version = (json['version'] is String)
        ? int.parse(json['version'])
        : (json['version'] == null)
            ? 0
            : json['version'];
    ttl = (json[AtConstants.ttl] is String)
        ? int.parse(json[AtConstants.ttl])
        : (json[AtConstants.ttl] == null)
            ? null
            : json[AtConstants.ttl];
    ttb = (json[AtConstants.ttb] is String)
        ? int.parse(json[AtConstants.ttb])
        : (json[AtConstants.ttb] == null)
            ? null
            : json[AtConstants.ttb];
    ttr = (json[AtConstants.ttr] is String)
        ? int.parse(json[AtConstants.ttr])
        : (json[AtConstants.ttr] == null)
            ? null
            : json[AtConstants.ttr];
    isCascade = json[AtConstants.ccd];
    isBinary = json[AtConstants.isBinary];
    isEncrypted = json[AtConstants.isEncrypted];
    dataSignature = json[AtConstants.publicDataSignature];
    sharedKeyEnc = json[AtConstants.sharedKeyEncrypted];
    pubKeyCS = json[AtConstants.sharedWithPublicKeyCheckSum];
    encoding = json[AtConstants.encoding];
    encKeyName = json[AtConstants.encryptingKeyName];
    encAlgo = json[AtConstants.encryptingAlgo];
    ivNonce = json[AtConstants.ivOrNonce];
    skeEncKeyName = json[AtConstants.sharedKeyEncryptedEncryptingKeyName];
    skeEncAlgo = json[AtConstants.sharedKeyEncryptedEncryptingAlgo];

    return this;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AtMetaData &&
          runtimeType == other.runtimeType &&
          createdBy == other.createdBy &&
          updatedBy == other.updatedBy &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt &&
          expiresAt == other.expiresAt &&
          status == other.status &&
          version == other.version &&
          availableAt == other.availableAt &&
          ttb == other.ttb &&
          ttl == other.ttl &&
          ttr == other.ttr &&
          refreshAt == other.refreshAt &&
          isCascade == other.isCascade &&
          isBinary == other.isBinary &&
          isEncrypted == other.isEncrypted &&
          dataSignature == other.dataSignature &&
          sharedKeyEnc == other.sharedKeyEnc &&
          pubKeyCS == other.pubKeyCS &&
          encoding == other.encoding &&
          encKeyName == other.encKeyName &&
          encAlgo == other.encAlgo &&
          ivNonce == other.ivNonce &&
          skeEncKeyName == other.skeEncKeyName &&
          skeEncAlgo == other.skeEncAlgo;

  @override
  int get hashCode =>
      createdBy.hashCode ^
      updatedBy.hashCode ^
      createdAt.hashCode ^
      updatedAt.hashCode ^
      expiresAt.hashCode ^
      status.hashCode ^
      version.hashCode ^
      availableAt.hashCode ^
      ttb.hashCode ^
      ttl.hashCode ^
      ttr.hashCode ^
      refreshAt.hashCode ^
      isCascade.hashCode ^
      isBinary.hashCode ^
      isEncrypted.hashCode ^
      dataSignature.hashCode ^
      sharedKeyEnc.hashCode ^
      pubKeyCS.hashCode ^
      encoding.hashCode ^
      encKeyName.hashCode ^
      encAlgo.hashCode ^
      ivNonce.hashCode ^
      skeEncKeyName.hashCode ^
      skeEncAlgo.hashCode;
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
      ..encoding = fields[18]
      ..encKeyName = fields[19]
      ..encAlgo = fields[20]
      ..ivNonce = fields[21]
      ..skeEncKeyName = fields[22]
      ..skeEncAlgo = fields[23];
  }

  @override
  void write(BinaryWriter writer, AtMetaData obj) {
    writer
      ..writeByte(24)
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
      ..write(obj.encoding)
      ..writeByte(19)
      ..write(obj.encKeyName)
      ..writeByte(20)
      ..write(obj.encAlgo)
      ..writeByte(21)
      ..write(obj.ivNonce)
      ..writeByte(22)
      ..write(obj.skeEncKeyName)
      ..writeByte(23)
      ..write(obj.skeEncAlgo);
  }
}
