// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'at_meta_data.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AtMetaDataAdapter extends TypeAdapter<AtMetaData> {
  @override
  final int typeId = 1;

  @override
  AtMetaData read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AtMetaData()
      ..createdBy = fields[0] as String?
      ..updatedBy = fields[1] as String?
      ..createdAt = fields[2] as DateTime?
      ..updatedAt = fields[3] as DateTime?
      ..expiresAt = fields[4] as DateTime?
      ..status = fields[5] as String?
      ..version = (fields[6] as num?)?.toInt()
      ..ttb = (fields[7] as num?)?.toInt()
      ..ttl = (fields[8] as num?)?.toInt()
      ..ttr = (fields[9] as num?)?.toInt()
      ..refreshAt = fields[10] as DateTime?
      ..isCascade = fields[11] as bool?
      ..availableAt = fields[12] as DateTime?
      ..isBinary = fields[13] as bool?
      ..isEncrypted = fields[14] as bool?
      ..dataSignature = fields[15] as String?
      ..sharedKeyEnc = fields[16] as String?
      ..pubKeyCS = fields[17] as String?
      ..encoding = fields[18] as String?
      ..encKeyName = fields[19] as String?
      ..encAlgo = fields[20] as String?
      ..ivNonce = fields[21] as String?
      ..skeEncKeyName = fields[22] as String?
      ..skeEncAlgo = fields[23] as String?;
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
      ..write(obj.availableAt)
      ..writeByte(8)
      ..write(obj.ttb)
      ..writeByte(9)
      ..write(obj.ttl)
      ..writeByte(10)
      ..write(obj.ttr)
      ..writeByte(11)
      ..write(obj.refreshAt)
      ..writeByte(12)
      ..write(obj.isCascade)
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

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AtMetaDataAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
