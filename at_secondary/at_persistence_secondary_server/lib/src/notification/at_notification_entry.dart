import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';
import 'package:hive/hive.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';

class NotificationEntry extends HiveObject {
  @HiveField(0)
  List<AtNotification> _sentNotifications;

  @HiveField(1)
  List<AtNotification> _receivedNotifications;

  NotificationEntry(this._sentNotifications, this._receivedNotifications);

  List<AtNotification> get sentNotifications => _sentNotifications;

  List<AtNotification> get receivedNotifications => _receivedNotifications;

  set sentNotifications(List<AtNotification> value) {
    _sentNotifications = value;
  }

  set receivedNotifications(List<AtNotification> value) {
    _receivedNotifications = value;
  }

  Map toJson() => {
        'sentNotifications': _sentNotifications,
        'receivedNotifications': _receivedNotifications
      };

  @override
  String toString() {
    return 'NotificationEntry{sentNotifications: ${_sentNotifications}, receivedNotifications: ${_receivedNotifications}}';
  }
}

class NotificationEntryMeta extends HiveObject {}

/// Hive adapter for [NotificationEntry]
class NotificationEntryAdapter extends TypeAdapter<NotificationEntry> {
  @override
  final typeId = typeAdapterMap['NotificationEntryAdapter'];

  @override
  NotificationEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read()
    };
    return NotificationEntry(
      (fields[0] as List)?.cast<AtNotification>(),
      (fields[1] as List)?.cast<AtNotification>(),
    );
  }

  @override
  void write(BinaryWriter writer, NotificationEntry notificationEntry) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(notificationEntry._sentNotifications)
      ..writeByte(1)
      ..write(notificationEntry._receivedNotifications);
  }
}
