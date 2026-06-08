import 'package:at_commons/at_commons.dart';
import 'package:hive/hive.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/impl/hive/adapters/type_adapter_util.dart';

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
      ..skeEncAlgo = fields[23]
      ..pubKeyHash = fields[24]
      ..immutable = fields[25];
  }

  @override
  void write(BinaryWriter writer, AtMetaData obj) {
    writer
      ..writeByte(26)
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
      ..write(obj.skeEncAlgo)
      ..writeByte(24)
      ..write(obj.pubKeyHash)
      ..writeByte(25)
      ..write(obj.immutable);
  }
}

class PublicKeyHashAdapter extends TypeAdapter<PublicKeyHash> {
  @override
  final int typeId = typeAdapterMap['PublicKeyHashAdapter'];

  @override
  PublicKeyHash read(BinaryReader reader) {
    var numOfFields = reader.readByte();
    var fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PublicKeyHash(fields[0] as String, fields[1] as String);
  }

  @override
  void write(BinaryWriter writer, PublicKeyHash obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.hash)
      ..writeByte(1)
      ..write(obj.hashingAlgo);
  }
}
