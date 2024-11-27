import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:hive_ce/hive.dart';
import 'package:uuid/uuid.dart';
part 'at_notification.g.dart';

/// Represents an [AtNotification] entry in keystore.
@HiveType(typeId: 6)
class AtNotification extends HiveObject {
  @HiveField(0)
  final String? id;

  @HiveField(1)
  final String? fromAtSign;

  @HiveField(2)
  final DateTime? notificationDateTime;

  @HiveField(3)
  final String? toAtSign;

  @HiveField(4)
  final String? notification;

  @HiveField(5)
  final NotificationType? type;

  @HiveField(6)
  final OperationType? opType;

  @HiveField(7)
  final MessageType? messageType;

  @HiveField(8)
  final DateTime? expiresAt;

  @HiveField(9)
  NotificationPriority? priority;

  @HiveField(10)
  NotificationStatus? notificationStatus;

  @HiveField(11)
  int retryCount;

  @HiveField(12)
  final String? strategy;

  @HiveField(13)
  final String? notifier;

  @HiveField(14)
  final int? depth;

  @HiveField(15)
  final String? atValue;

  @HiveField(16)
  final AtMetaData? atMetadata;

  @HiveField(17)
  final int? ttl;

  AtNotification(
      this.id,
      this.fromAtSign,
      this.notificationDateTime,
      this.toAtSign,
      this.notification,
      this.type,
      this.opType,
      this.messageType,
      this.expiresAt,
      this.strategy,
      this.notifier,
      this.depth,
      this.atValue,
      this.atMetadata,
      this.ttl,
      this.retryCount,
      this.priority,
      this.notificationStatus);

  AtNotification._builder(AtNotificationBuilder atNotificationBuilder)
      : id = atNotificationBuilder.id,
        fromAtSign = atNotificationBuilder.fromAtSign,
        notificationDateTime = atNotificationBuilder.notificationDateTime,
        toAtSign = atNotificationBuilder.toAtSign,
        notification = atNotificationBuilder.notification,
        type = atNotificationBuilder.type,
        opType = atNotificationBuilder.opType,
        messageType = atNotificationBuilder.messageType,
        expiresAt = atNotificationBuilder.expiresAt,
        priority = atNotificationBuilder.priority,
        notificationStatus = atNotificationBuilder.notificationStatus,
        retryCount = atNotificationBuilder.retryCount,
        strategy = atNotificationBuilder.strategy,
        notifier = atNotificationBuilder.notifier,
        depth = atNotificationBuilder.depth,
        atValue = atNotificationBuilder.atValue,
        atMetadata = atNotificationBuilder.atMetaData,
        ttl = atNotificationBuilder.ttl;

  Map toJson() => {
        'id': id,
        'fromAtSign': fromAtSign,
        'notificationDateTime': notificationDateTime,
        'toAtSign': toAtSign,
        'notification': notification,
        'type': type,
        'opType': opType,
        'messageType': messageType,
        'priority': priority,
        'notificationStatus': notificationStatus,
        'retryCount': retryCount,
        'strategy': strategy,
        'depth': depth,
        'notifier': notifier,
        'expiresAt': expiresAt,
        'atValue': atValue,
        'atMetadata': atMetadata?.toJson(),
        'ttl': ttl
      };

  @override
  String toString() {
    return 'AtNotification{id: $id, notificationStatus:$notificationStatus, '
        'fromAtSign: $fromAtSign, toAtSign:$toAtSign, '
        'strategy:$strategy, notificationDateTime: $notificationDateTime, '
        'notification:$notification, type:$type, opType:$opType, '
        'ttl: $ttl, expiresAt:$expiresAt, priority:$priority, '
        'atValue:$atValue';
  }

  bool isExpired() {
    return expiresAt != null && expiresAt!.isBefore(DateTime.now().toUtc());
  }
}

@HiveType(typeId: 5)
enum NotificationStatus {
  @HiveField(0)
  delivered,
  @HiveField(1)
  errored,
  @HiveField(2)
  queued,
  @HiveField(3)
  expired
}

@HiveType(typeId: 7)
enum NotificationType {
  @HiveField(0)
  sent,
  @HiveField(1)
  received,
  @HiveField(2)
  self
}

@HiveType(typeId: 8)
enum OperationType {
  @HiveField(0)
  update,
  @HiveField(1)
  delete
}

@HiveType(typeId: 9)
enum NotificationPriority {
  @HiveField(0)
  dummy,
  @HiveField(1)
  low,
  @HiveField(2)
  medium,
  @HiveField(3)
  high
}

@HiveType(typeId: 10)
enum MessageType {
  @HiveField(0)
  key,
  @HiveField(1)
  text
}

/// class for representing [OperationType] enum to the hive type adapter
// class OperationTypeAdapter extends TypeAdapter<OperationType?> {
//   @override
//   final int typeId = typeAdapterMap['OperationTypeAdapter'];
//
//   @override
//   OperationType? read(BinaryReader reader) {
//     switch (reader.readByte()) {
//       case 0:
//         return OperationType.update;
//       case 1:
//         return OperationType.delete;
//       default:
//         return null;
//     }
//   }
//
//   @override
//   void write(BinaryWriter writer, OperationType? obj) {
//     switch (obj) {
//       case OperationType.update:
//         writer.writeByte(0);
//         break;
//       case OperationType.delete:
//         writer.writeByte(1);
//         break;
//       default:
//         break;
//     }
//   }
// }

///class for representing [NotificationType] enum to the hive type adapter
// class NotificationTypeAdapter extends TypeAdapter<NotificationType?> {
//   @override
//   final int typeId = typeAdapterMap['NotificationTypeAdapter'];
//
//   @override
//   NotificationType? read(BinaryReader reader) {
//     switch (reader.readByte()) {
//       case 0:
//         return NotificationType.sent;
//       case 1:
//         return NotificationType.received;
//       case 2:
//         return NotificationType.self;
//       default:
//         return null;
//     }
//   }
//
//   @override
//   void write(BinaryWriter writer, NotificationType? obj) {
//     switch (obj) {
//       case NotificationType.sent:
//         writer.writeByte(0);
//         break;
//       case NotificationType.received:
//         writer.writeByte(1);
//         break;
//       case NotificationType.self:
//         writer.writeByte(2);
//         break;
//       default:
//         break;
//     }
//   }
// }

/// class for representing [NotificationStatus] enum to the hive type adapter
// class NotificationStatusAdapter extends TypeAdapter<NotificationStatus?> {
//   @override
//   final int typeId = typeAdapterMap['NotificationStatusAdapter'];
//
//   @override
//   NotificationStatus? read(BinaryReader reader) {
//     switch (reader.readByte()) {
//       case 0:
//         return NotificationStatus.delivered;
//       case 1:
//         return NotificationStatus.errored;
//       case 2:
//         return NotificationStatus.queued;
//       case 3:
//         return NotificationStatus.expired;
//       default:
//         return null;
//     }
//   }
//
//   @override
//   void write(BinaryWriter writer, NotificationStatus? obj) {
//     switch (obj) {
//       case NotificationStatus.delivered:
//         writer.writeByte(0);
//         break;
//       case NotificationStatus.errored:
//         writer.writeByte(1);
//         break;
//       case NotificationStatus.queued:
//         writer.writeByte(2);
//         break;
//       case NotificationStatus.expired:
//         writer.writeByte(3);
//         break;
//       default:
//         break;
//     }
//   }
// }

/// class for representing [NotificationStatus] enum to the hive type adapter
// class NotificationPriorityAdapter extends TypeAdapter<NotificationPriority?> {
//   @override
//   final int typeId = typeAdapterMap['NotificationPriorityAdapter'];
//
//   @override
//   NotificationPriority? read(BinaryReader reader) {
//     switch (reader.readByte()) {
//       case 0:
//         return NotificationPriority.dummy;
//       case 1:
//         return NotificationPriority.low;
//       case 2:
//         return NotificationPriority.medium;
//       case 3:
//         return NotificationPriority.high;
//       default:
//         return null;
//     }
//   }
//
//   @override
//   void write(BinaryWriter writer, NotificationPriority? obj) {
//     switch (obj) {
//       case NotificationPriority.dummy:
//         writer.writeByte(0);
//         break;
//       case NotificationPriority.low:
//         writer.writeByte(1);
//         break;
//       case NotificationPriority.medium:
//         writer.writeByte(2);
//         break;
//       case NotificationPriority.high:
//         writer.writeByte(3);
//         break;
//       default:
//         break;
//     }
//   }
// }

// class MessageTypeAdapter extends TypeAdapter<MessageType?> {
//   @override
//   int get typeId => typeAdapterMap['MessageTypeAdapter'];
//
//   @override
//   MessageType? read(BinaryReader reader) {
//     switch (reader.readByte()) {
//       case 0:
//         return MessageType.key;
//       case 1:
//         return MessageType.text;
//       default:
//         return null;
//     }
//   }
//
//   @override
//   void write(BinaryWriter writer, MessageType? obj) {
//     switch (obj) {
//       case MessageType.key:
//         writer.writeByte(0);
//         break;
//       case MessageType.text:
//         writer.writeByte(1);
//         break;
//       default:
//         break;
//     }
//   }
// }

/// AtNotificationBuilder class to build [AtNotification] object
class AtNotificationBuilder {
  static const int _defaultTTLInMins = 15;

  String? id = Uuid().v4();

  String? fromAtSign;

  DateTime? notificationDateTime = DateTime.now();

  String? toAtSign;

  String? notification;

  NotificationType? type;

  OperationType? opType;

  MessageType? messageType = MessageType.key;

  DateTime? expiresAt;

  NotificationPriority? priority = NotificationPriority.low;

  NotificationStatus? notificationStatus = NotificationStatus.queued;

  int retryCount = 1;

  String? strategy = 'all';

  String? notifier = 'system';

  int? depth = 1;

  String? atValue;

  int? ttl = Duration(minutes: _defaultTTLInMins).inMilliseconds;

  AtMetaData? atMetaData;

  AtNotification build() {
    if ((ttl != null && ttl! > 0) && expiresAt == null) {
      expiresAt = DateTime.now()
          .toUtcMillisecondsPrecision()
          .add(Duration(milliseconds: ttl!));
    }
    return AtNotification._builder(this);
  }

  reset() {
    this
      ..id = Uuid().v4()
      ..fromAtSign = null
      ..notificationDateTime = DateTime.now()
      ..toAtSign = null
      ..notification = null
      ..type = null
      ..opType = null
      ..messageType = MessageType.key
      ..expiresAt = null
      ..priority = NotificationPriority.low
      ..notificationStatus = NotificationStatus.queued
      ..retryCount = 1
      ..strategy = 'all'
      ..notifier = 'system'
      ..depth = 1
      ..atValue = null
      ..ttl = Duration(hours: _defaultTTLInMins).inMilliseconds
      ..atMetaData = null;
  }
}
