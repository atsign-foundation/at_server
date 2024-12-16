// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'hive_adapters.dart';

// **************************************************************************
// AdaptersGenerator
// **************************************************************************

class AtDataAdapter extends TypeAdapter<AtData> {
  @override
  final int typeId = 0;

  @override
  AtData read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AtData()
      ..data = fields[0] as String?
      ..metaData = fields[1] as AtMetaData?;
  }

  @override
  void write(BinaryWriter writer, AtData obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.data)
      ..writeByte(1)
      ..write(obj.metaData);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AtDataAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

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
      ..skeEncAlgo = fields[23] as String?
      ..pubKeyHash = fields[24] as PublicKeyHash?;
  }

  @override
  void write(BinaryWriter writer, AtMetaData obj) {
    writer
      ..writeByte(25)
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
      ..write(obj.skeEncAlgo)
      ..writeByte(24)
      ..write(obj.pubKeyHash);
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

class CommitEntryAdapter extends TypeAdapter<CommitEntry> {
  @override
  final int typeId = 2;

  @override
  CommitEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CommitEntry(
      fields[0] as String?,
      fields[1] as CommitOp?,
      fields[2] as DateTime?,
    )..commitId = (fields[3] as num?)?.toInt();
  }

  @override
  void write(BinaryWriter writer, CommitEntry obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.atKey)
      ..writeByte(1)
      ..write(obj.operation)
      ..writeByte(2)
      ..write(obj.opTime)
      ..writeByte(3)
      ..write(obj.commitId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommitEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class CommitOpAdapter extends TypeAdapter<CommitOp> {
  @override
  final int typeId = 3;

  @override
  CommitOp read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return CommitOp.UPDATE;
      case 1:
        return CommitOp.DELETE;
      case 2:
        return CommitOp.UPDATE_META;
      case 3:
        return CommitOp.UPDATE_ALL;
      default:
        return CommitOp.UPDATE;
    }
  }

  @override
  void write(BinaryWriter writer, CommitOp obj) {
    switch (obj) {
      case CommitOp.UPDATE:
        return writer.writeByte(0);
      case CommitOp.DELETE:
        return writer.writeByte(1);
      case CommitOp.UPDATE_META:
        return writer.writeByte(2);
      case CommitOp.UPDATE_ALL:
        return writer.writeByte(3);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommitOpAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AccessLogEntryAdapter extends TypeAdapter<AccessLogEntry> {
  @override
  final int typeId = 4;

  @override
  AccessLogEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AccessLogEntry(
      fields[0] as String?,
      fields[1] as DateTime?,
      fields[2] as String?,
      fields[3] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, AccessLogEntry obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.fromAtSign)
      ..writeByte(1)
      ..write(obj.requestDateTime)
      ..writeByte(2)
      ..write(obj.verbName)
      ..writeByte(3)
      ..write(obj.lookupKey);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccessLogEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class NotificationStatusAdapter extends TypeAdapter<NotificationStatus> {
  @override
  final int typeId = 5;

  @override
  NotificationStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return NotificationStatus.delivered;
      case 1:
        return NotificationStatus.errored;
      case 2:
        return NotificationStatus.queued;
      case 3:
        return NotificationStatus.expired;
      default:
        return NotificationStatus.delivered;
    }
  }

  @override
  void write(BinaryWriter writer, NotificationStatus obj) {
    switch (obj) {
      case NotificationStatus.delivered:
        return writer.writeByte(0);
      case NotificationStatus.errored:
        return writer.writeByte(1);
      case NotificationStatus.queued:
        return writer.writeByte(2);
      case NotificationStatus.expired:
        return writer.writeByte(3);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotificationStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AtNotificationAdapter extends TypeAdapter<AtNotification> {
  @override
  final int typeId = 6;

  @override
  AtNotification read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AtNotification(
      fields[0] as String?,
      fields[1] as String?,
      fields[2] as DateTime?,
      fields[3] as String?,
      fields[4] as String?,
      fields[5] as NotificationType?,
      fields[6] as OperationType?,
      fields[7] as MessageType?,
      fields[8] as DateTime?,
      fields[12] as String?,
      fields[13] as String?,
      (fields[14] as num?)?.toInt(),
      fields[15] as String?,
      fields[16] as AtMetaData?,
      (fields[17] as num?)?.toInt(),
    )
      ..priority = fields[9] as NotificationPriority?
      ..notificationStatus = fields[10] as NotificationStatus?
      ..retryCount = (fields[11] as num).toInt();
  }

  @override
  void write(BinaryWriter writer, AtNotification obj) {
    writer
      ..writeByte(18)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.fromAtSign)
      ..writeByte(2)
      ..write(obj.notificationDateTime)
      ..writeByte(3)
      ..write(obj.toAtSign)
      ..writeByte(4)
      ..write(obj.notification)
      ..writeByte(5)
      ..write(obj.type)
      ..writeByte(6)
      ..write(obj.opType)
      ..writeByte(7)
      ..write(obj.messageType)
      ..writeByte(8)
      ..write(obj.expiresAt)
      ..writeByte(9)
      ..write(obj.priority)
      ..writeByte(10)
      ..write(obj.notificationStatus)
      ..writeByte(11)
      ..write(obj.retryCount)
      ..writeByte(12)
      ..write(obj.strategy)
      ..writeByte(13)
      ..write(obj.notifier)
      ..writeByte(14)
      ..write(obj.depth)
      ..writeByte(15)
      ..write(obj.atValue)
      ..writeByte(16)
      ..write(obj.atMetadata)
      ..writeByte(17)
      ..write(obj.ttl);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AtNotificationAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class NotificationTypeAdapter extends TypeAdapter<NotificationType> {
  @override
  final int typeId = 7;

  @override
  NotificationType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return NotificationType.sent;
      case 1:
        return NotificationType.received;
      case 2:
        return NotificationType.self;
      default:
        return NotificationType.sent;
    }
  }

  @override
  void write(BinaryWriter writer, NotificationType obj) {
    switch (obj) {
      case NotificationType.sent:
        return writer.writeByte(0);
      case NotificationType.received:
        return writer.writeByte(1);
      case NotificationType.self:
        return writer.writeByte(2);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotificationTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class OperationTypeAdapter extends TypeAdapter<OperationType> {
  @override
  final int typeId = 8;

  @override
  OperationType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return OperationType.update;
      case 1:
        return OperationType.delete;
      default:
        return OperationType.update;
    }
  }

  @override
  void write(BinaryWriter writer, OperationType obj) {
    switch (obj) {
      case OperationType.update:
        return writer.writeByte(0);
      case OperationType.delete:
        return writer.writeByte(1);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OperationTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class NotificationPriorityAdapter extends TypeAdapter<NotificationPriority> {
  @override
  final int typeId = 9;

  @override
  NotificationPriority read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return NotificationPriority.dummy;
      case 1:
        return NotificationPriority.low;
      case 2:
        return NotificationPriority.medium;
      case 3:
        return NotificationPriority.high;
      default:
        return NotificationPriority.dummy;
    }
  }

  @override
  void write(BinaryWriter writer, NotificationPriority obj) {
    switch (obj) {
      case NotificationPriority.dummy:
        return writer.writeByte(0);
      case NotificationPriority.low:
        return writer.writeByte(1);
      case NotificationPriority.medium:
        return writer.writeByte(2);
      case NotificationPriority.high:
        return writer.writeByte(3);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotificationPriorityAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class MessageTypeAdapter extends TypeAdapter<MessageType> {
  @override
  final int typeId = 10;

  @override
  MessageType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return MessageType.key;
      case 1:
        return MessageType.text;
      default:
        return MessageType.key;
    }
  }

  @override
  void write(BinaryWriter writer, MessageType obj) {
    switch (obj) {
      case MessageType.key:
        return writer.writeByte(0);
      case MessageType.text:
        return writer.writeByte(1);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
