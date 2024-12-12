// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'at_notification.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

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
      (fields[11] as num).toInt(),
      fields[9] as NotificationPriority?,
      fields[10] as NotificationStatus?,
    );
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
