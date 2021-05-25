import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

/// Represents an [AtNotification] entry in keystore.
class AtNotification {
  @HiveField(0)
  String _id;

  @HiveField(1)
  String _fromAtSign;

  @HiveField(2)
  DateTime _notificationDateTime;

  @HiveField(3)
  String _toAtSign;

  @HiveField(4)
  String _notification;

  @HiveField(5)
  NotificationType _type;

  @HiveField(6)
  OperationType _opType;

  @HiveField(7)
  MessageType _messageType;

  @HiveField(8)
  DateTime _expiresAt;

  @HiveField(9)
  NotificationPriority priority;

  @HiveField(10)
  NotificationStatus notificationStatus;

  @HiveField(11)
  int retryCount;

  @HiveField(12)
  String _strategy;

  @HiveField(13)
  String _notifier;

  @HiveField(14)
  int _depth;

  @HiveField(15)
  String _atValue;

  @HiveField(16)
  AtMetaData _atMetadata;

  AtNotification._builder(AtNotificationBuilder atNotificationBuilder)
      : _id = atNotificationBuilder.id,
        _fromAtSign = atNotificationBuilder.fromAtSign,
        _notificationDateTime = atNotificationBuilder.notificationDateTime,
        _toAtSign = atNotificationBuilder.toAtSign,
        _notification = atNotificationBuilder.notification,
        _type = atNotificationBuilder.type,
        _opType = atNotificationBuilder.opType,
        _messageType = atNotificationBuilder.messageType,
        _expiresAt = atNotificationBuilder.expiresAt,
        priority = atNotificationBuilder.priority,
        notificationStatus = atNotificationBuilder.notificationStatus,
        retryCount = atNotificationBuilder.retryCount,
        _strategy = atNotificationBuilder.strategy,
        _notifier = atNotificationBuilder.notifier,
        _depth = atNotificationBuilder.depth,
        _atValue = atNotificationBuilder.atValue,
        _atMetadata = atNotificationBuilder.atMetaData;

  String get id => _id;

  String get fromAtSign => _fromAtSign;

  DateTime get notificationDateTime => _notificationDateTime;

  String get toAtSign => _toAtSign;

  String get notification => _notification;

  NotificationType get type => _type;

  OperationType get opType => _opType;

  DateTime get expiresAt => _expiresAt;

  String get atValue => _atValue;

  //int get retryCount => _retryCount;

  //NotificationStatus get notificationStatus => _notificationStatus;

  String get notifier => _notifier;

  int get depth => _depth;

  String get strategy => _strategy;

  MessageType get messageType => _messageType;

  AtMetaData get atMetadata => _atMetadata;

  Map toJson() => {
        'id': _id,
        'fromAtSign': _fromAtSign,
        'notificationDateTime': _notificationDateTime.toUtc().toString(),
        'toAtSign': _toAtSign,
        'notification': _notification,
        'type': _type.toString(),
        'opType': _opType.toString(),
        'messageType': _messageType.toString(),
        'priority': priority.toString(),
        'notificationStatus': notificationStatus.toString(),
        'retryCount': retryCount,
        'strategy': _strategy,
        'depth': _depth,
        'notifier': _notifier,
        'expiresAt':
            (_expiresAt != null ? _expiresAt.toUtc().toString() : _expiresAt),
        'atValue': _atValue,
        'atMetadata': (_atMetadata != null ? _atMetadata.toJson() : _atMetadata)
      };

  AtNotification.fromJson(Map<String, dynamic> json) {
    _id = json['id'] as String;
    _fromAtSign = json['fromAtSign'] as String;
    _notificationDateTime =
        DateTime.parse(json['notificationDateTime'] as String);
    _toAtSign = json['toAtSign'] as String;
    _notification = json['notification'] as String;
    _type = NotificationType.values
        .firstWhere((element) => element.toString() == json['type']);
    _opType = OperationType.values
        .firstWhere((element) => element.toString() == json['opType']);
    _messageType = MessageType.values
        .firstWhere((element) => element.toString() == json['messageType']);
    priority = NotificationPriority.values
        .firstWhere((element) => element.toString() == json['priority']);
    notificationStatus = json['notificationStatus'] != 'null' ? NotificationStatus.values.firstWhere(
        (element) => element.toString() == json['notificationStatus']) : null;
    retryCount = json['retryCount'] as int;
    _strategy = json['strategy'] as String;
    _depth = json['depth'] as int;
    _notifier = json['notifier'] as String;
    _expiresAt = (_expiresAt != null
        ? DateTime.parse(json['expiresAt'] as String)
        : _expiresAt);
    _atValue = json['atValue'] as String;
    _atMetadata = (_atMetadata != null
        ? AtMetaData().fromJson(json['atMetadata'])
        : _atMetadata);
  }

  @override
  String toString() {
    return 'AtNotification{id: $_id,fromAtSign: $_fromAtSign, '
        'notificationDateTime: $_notificationDateTime, '
        'toAtSign:$_toAtSign, notification:$_notification, '
        'type:$_type, opType:$_opType, expiresAt:$_expiresAt : priority:$priority : notificationStatus:$notificationStatus : atValue:$atValue';
  }
}

enum NotificationStatus { delivered, errored, queued }

enum NotificationType { sent, received }

enum OperationType { update, delete }

enum NotificationPriority { dummy, low, medium, high }

enum MessageType { key, text }

/// Class for registering [AtNotification] to the hive type adapter.
class AtNotificationAdapter extends TypeAdapter<AtNotification> {
  @override
  final typeId = typeAdapterMap['AtNotificationAdapter'];

  @override
  AtNotification read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read()
    };

    final atNotification = (AtNotificationBuilder()
          ..id = fields[0] as String
          ..fromAtSign = fields[1] as String
          ..notificationDateTime = fields[2] as DateTime
          ..toAtSign = fields[3] as String
          ..notification = fields[4] as String
          ..type = fields[5] as NotificationType
          ..opType = fields[6] as OperationType
          ..messageType = fields[7] as MessageType
          ..expiresAt = fields[8] as DateTime
          ..priority = fields[9] as NotificationPriority
          ..notificationStatus = fields[10] as NotificationStatus
          ..retryCount = fields[11] as int
          ..strategy = fields[12] as String
          ..notifier = fields[13] as String
          ..depth = fields[14] as int
          ..atValue = fields[15] as String
          ..atMetaData = fields[16] as AtMetaData)
        .build();

    return atNotification;
  }

  @override
  void write(BinaryWriter writer, AtNotification atNotification) {
    writer
      ..writeByte(17)
      ..writeByte(0)
      ..write(atNotification.id)
      ..writeByte(1)
      ..write(atNotification.fromAtSign)
      ..writeByte(2)
      ..write(atNotification.notificationDateTime)
      ..writeByte(3)
      ..write(atNotification.toAtSign)
      ..writeByte(4)
      ..write(atNotification.notification)
      ..writeByte(5)
      ..write(atNotification.type)
      ..writeByte(6)
      ..write(atNotification.opType)
      ..writeByte(7)
      ..write(atNotification.messageType)
      ..writeByte(8)
      ..write(atNotification.expiresAt)
      ..writeByte(9)
      ..write(atNotification.priority)
      ..writeByte(10)
      ..write(atNotification.notificationStatus)
      ..writeByte(11)
      ..write(atNotification.retryCount)
      ..writeByte(12)
      ..write(atNotification.strategy)
      ..writeByte(13)
      ..write(atNotification.notifier)
      ..writeByte(14)
      ..write(atNotification.depth)
      ..writeByte(15)
      ..write(atNotification.atValue)
      ..writeByte(16)
      ..write(atNotification.atMetadata);
  }
}

/// class for representing [OperationType] enum to the hive type adapter
class OperationTypeAdapter extends TypeAdapter<OperationType> {
  @override
  final typeId = typeAdapterMap['OperationTypeAdapter'];

  @override
  OperationType read(BinaryReader reader) {
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
  void write(BinaryWriter writer, OperationType obj) {
    switch (obj) {
      case OperationType.update:
        writer.writeByte(0);
        break;
      case OperationType.delete:
        writer.writeByte(1);
        break;
    }
  }
}

///class for representing [NotificationType] enum to the hive type adapter
class NotificationTypeAdapter extends TypeAdapter<NotificationType> {
  @override
  final typeId = typeAdapterMap['NotificationTypeAdapter'];

  @override
  NotificationType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return NotificationType.sent;
      case 1:
        return NotificationType.received;
      default:
        return null;
    }
  }

  @override
  void write(BinaryWriter writer, NotificationType obj) {
    switch (obj) {
      case NotificationType.sent:
        writer.writeByte(0);
        break;
      case NotificationType.received:
        writer.writeByte(1);
        break;
    }
  }
}

/// class for representing [NotificationStatus] enum to the hive type adapter
class NotificationStatusAdapter extends TypeAdapter<NotificationStatus> {
  @override
  final typeId = typeAdapterMap['NotificationStatusAdapter'];

  @override
  NotificationStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return NotificationStatus.delivered;
      case 1:
        return NotificationStatus.errored;
      case 2:
        return NotificationStatus.queued;
      default:
        return null;
    }
  }

  @override
  void write(BinaryWriter writer, NotificationStatus obj) {
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
    }
  }
}

/// class for representing [NotificationStatus] enum to the hive type adapter
class NotificationPriorityAdapter extends TypeAdapter<NotificationPriority> {
  @override
  final typeId = typeAdapterMap['NotificationPriorityAdapter'];

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
        return null;
    }
  }

  @override
  void write(BinaryWriter writer, NotificationPriority obj) {
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
    }
  }
}

class MessageTypeAdapter extends TypeAdapter<MessageType> {
  @override
  int get typeId => typeAdapterMap['MessageTypeAdapter'];

  @override
  MessageType read(BinaryReader reader) {
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
  void write(BinaryWriter writer, MessageType obj) {
    switch (obj) {
      case MessageType.key:
        writer.writeByte(0);
        break;
      case MessageType.text:
        writer.writeByte(1);
        break;
    }
  }
}

/// AtNotificationBuilder class to build [AtNotification] object
class AtNotificationBuilder {
  String id = Uuid().v4();

  String fromAtSign;

  DateTime notificationDateTime = DateTime.now();

  String toAtSign;

  String notification;

  NotificationType type;

  OperationType opType;

  MessageType messageType = MessageType.key;

  DateTime expiresAt;

  NotificationPriority priority = NotificationPriority.low;

  NotificationStatus notificationStatus = NotificationStatus.queued;

  int retryCount = 1;

  String strategy = 'all';

  String notifier = 'system';

  int depth = 1;

  String atValue;

  AtMetaData atMetaData;

  AtNotification build() {
    return AtNotification._builder(this);
  }
}
