import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/utils/type_adapter_util.dart';
import 'package:hive_ce/hive.dart';
import 'package:uuid/uuid.dart';

/// Represents an [AtNotification] entry in keystore.
class AtNotification extends HiveObject {
  final String? id;

  final String? fromAtSign;

  final DateTime? notificationDateTime;

  final String? toAtSign;

  final String? notification;

  final NotificationType? type;

  final OperationType? opType;

  final MessageType? messageType;

  final DateTime? expiresAt;

  NotificationPriority? priority;

  NotificationStatus? notificationStatus;

  int retryCount=0;

  final String? strategy;

  final String? notifier;

  final int? depth;

  final String? atValue;

  final AtMetaData? atMetadata;

  final int? ttl;

  AtNotification(this.id, this.fromAtSign, this.notificationDateTime, this.toAtSign, this.notification, this.type, this.opType, this.messageType, this.expiresAt, this.strategy, this.notifier, this.depth, this.atValue, this.atMetadata, this.ttl);

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

enum NotificationStatus { delivered, errored,  queued, expired }

enum NotificationType { sent, received, self }

enum OperationType {  update,  delete }

enum NotificationPriority {  dummy,  low,  medium,  high }

enum MessageType {  key,   text }

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
