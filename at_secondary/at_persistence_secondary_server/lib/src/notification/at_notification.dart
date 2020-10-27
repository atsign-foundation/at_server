import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';
import 'package:hive/hive.dart';

class AtNotification {
  @HiveField(0)
  final String _id;

  @HiveField(1)
  final String _fromAtSign;

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
  DateTime _expiresAt;

  @HiveField(8)
  String _atValue;

  AtNotification(this._id, this._fromAtSign, this._notificationDateTime,
      this._toAtSign, this._notification, this._type, this._opType,
      [this._expiresAt]);

  String get id => _id;

  String get fromAtSign => _fromAtSign;

  DateTime get notificationDateTime => _notificationDateTime;

  String get toAtSign => _toAtSign;

  String get notification => _notification;

  NotificationType get type => _type;

  OperationType get opType => _opType;

  DateTime get expiresAt => _expiresAt;

  String get atValue => _atValue;

  Map toJson() => {
        'id': _id,
        'fromAtSign': _fromAtSign,
        'notificationDateTime': _notificationDateTime,
        'toAtSign': _toAtSign,
        'notification': _notification,
        'type': _type,
        'opType': _opType,
        'expiresAt': _expiresAt
      };

  @override
  String toString() {
    return 'AtNotification{id: ${_id},fromAtSign: ${_fromAtSign}, '
        'notificationDateTime: ${_notificationDateTime}, '
        'toAtSign:${_toAtSign}, notification:${_notification}, '
        'type:${_type}, opType:${_opType}, expiresAt:${_expiresAt}';
  }

  set notificationDateTime(DateTime value) {
    _notificationDateTime = value;
  }

  set toAtSign(String value) {
    _toAtSign = value;
  }

  set notification(String value) {
    _notification = value;
  }

  set type(NotificationType value) {
    _type = value;
  }

  set opType(OperationType value) {
    _opType = value;
  }

  set expiresAt(DateTime value) {
    _expiresAt = value;
  }

  set atValue(String value) {
    _atValue = value;
  }
}

enum NotificationType {
  @HiveField(0)
  sent,
  @HiveField(1)
  received
}

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

enum OperationType {
  @HiveField(0)
  update,
  @HiveField(1)
  delete
}

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

/// Hive adapter for [AtNotification]
class AtNotificationAdapter extends TypeAdapter<AtNotification> {
  @override
  final typeId = typeAdapterMap['AtNotificationAdapter'];

  @override
  AtNotification read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read()
    };
    var atNotification = AtNotification(
        fields[0] as String,
        fields[1] as String,
        fields[2] as DateTime,
        fields[3] as String,
        fields[4] as String,
        fields[5] as NotificationType,
        fields[6] as OperationType,
        fields[7] as DateTime);
    return atNotification;
  }

  @override
  void write(BinaryWriter writer, AtNotification atNotification) {
    writer
      ..writeByte(9)
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
      ..write(atNotification.expiresAt)
      ..writeByte(8)
      ..write(atNotification.atValue);
  }
}
