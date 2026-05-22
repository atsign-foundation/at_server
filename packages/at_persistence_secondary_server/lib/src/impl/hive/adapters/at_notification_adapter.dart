import 'package:hive/hive.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/impl/hive/adapters/type_adapter_util.dart';

/// Class for registering [AtNotification] to the hive type adapter.
class AtNotificationAdapter extends TypeAdapter<AtNotification> {
  @override
  final int typeId = typeAdapterMap['AtNotificationAdapter'];

  @override
  AtNotification read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read()
    };

    final atNotification = (AtNotificationBuilder()
          ..id = fields[0] as String?
          ..fromAtSign = fields[1] as String?
          ..notificationDateTime = fields[2] as DateTime?
          ..toAtSign = fields[3] as String?
          ..notification = fields[4] as String?
          ..type = fields[5] as NotificationType?
          ..opType = fields[6] as OperationType?
          ..messageType = fields[7] as MessageType?
          ..expiresAt = fields[8] as DateTime?
          ..priority = fields[9] as NotificationPriority?
          ..notificationStatus = fields[10] as NotificationStatus?
          ..retryCount = fields[11] as int
          ..strategy = fields[12] as String?
          ..notifier = fields[13] as String?
          ..depth = fields[14] as int?
          ..atValue = fields[15] as String?
          ..atMetaData = fields[16] as AtMetaData?
          ..ttl = fields[17] as int?)
        .build();

    return atNotification;
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
}

/// class for representing [OperationType] enum to the hive type adapter
class OperationTypeAdapter extends TypeAdapter<OperationType?> {
  @override
  final int typeId = typeAdapterMap['OperationTypeAdapter'];

  @override
  OperationType? read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return OperationType.update;
      case 1:
        return OperationType.delete;
      default:
        return null;
    }
  }

  @override
  void write(BinaryWriter writer, OperationType? obj) {
    switch (obj) {
      case OperationType.update:
        writer.writeByte(0);
        break;
      case OperationType.delete:
        writer.writeByte(1);
        break;
      default:
        break;
    }
  }
}

///class for representing [NotificationType] enum to the hive type adapter
class NotificationTypeAdapter extends TypeAdapter<NotificationType?> {
  @override
  final int typeId = typeAdapterMap['NotificationTypeAdapter'];

  @override
  NotificationType? read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return NotificationType.sent;
      case 1:
        return NotificationType.received;
      case 2:
        return NotificationType.self;
      default:
        return null;
    }
  }

  @override
  void write(BinaryWriter writer, NotificationType? obj) {
    switch (obj) {
      case NotificationType.sent:
        writer.writeByte(0);
        break;
      case NotificationType.received:
        writer.writeByte(1);
        break;
      case NotificationType.self:
        writer.writeByte(2);
        break;
      default:
        break;
    }
  }
}

/// class for representing [NotificationStatus] enum to the hive type adapter
class NotificationStatusAdapter extends TypeAdapter<NotificationStatus?> {
  @override
  final int typeId = typeAdapterMap['NotificationStatusAdapter'];

  @override
  NotificationStatus? read(BinaryReader reader) {
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
        return null;
    }
  }

  @override
  void write(BinaryWriter writer, NotificationStatus? obj) {
    switch (obj) {
      case NotificationStatus.delivered:
        writer.writeByte(0);
        break;
      case NotificationStatus.errored:
        writer.writeByte(1);
        break;
      case NotificationStatus.queued:
        writer.writeByte(2);
        break;
      case NotificationStatus.expired:
        writer.writeByte(3);
        break;
      default:
        break;
    }
  }
}

/// class for representing [NotificationStatus] enum to the hive type adapter
class NotificationPriorityAdapter extends TypeAdapter<NotificationPriority?> {
  @override
  final int typeId = typeAdapterMap['NotificationPriorityAdapter'];

  @override
  NotificationPriority? read(BinaryReader reader) {
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
        return null;
    }
  }

  @override
  void write(BinaryWriter writer, NotificationPriority? obj) {
    switch (obj) {
      case NotificationPriority.dummy:
        writer.writeByte(0);
        break;
      case NotificationPriority.low:
        writer.writeByte(1);
        break;
      case NotificationPriority.medium:
        writer.writeByte(2);
        break;
      case NotificationPriority.high:
        writer.writeByte(3);
        break;
      default:
        break;
    }
  }
}

class MessageTypeAdapter extends TypeAdapter<MessageType?> {
  @override
  int get typeId => typeAdapterMap['MessageTypeAdapter'];

  @override
  MessageType? read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return MessageType.key;
      case 1:
        return MessageType.text;
      default:
        return null;
    }
  }

  @override
  void write(BinaryWriter writer, MessageType? obj) {
    switch (obj) {
      case MessageType.key:
        writer.writeByte(0);
        break;
      case MessageType.text:
        writer.writeByte(1);
        break;
      default:
        break;
    }
  }
}
