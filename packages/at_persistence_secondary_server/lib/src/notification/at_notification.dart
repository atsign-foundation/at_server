import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:uuid/uuid.dart';

/// Represents an [AtNotification] entry in keystore.
class AtNotification {
  final String? _id;

  final String? _fromAtSign;

  final DateTime? _notificationDateTime;

  final String? _toAtSign;

  final String? _notification;

  final NotificationType? _type;

  final OperationType? _opType;

  final MessageType? _messageType;

  final DateTime? _expiresAt;

  NotificationPriority? priority;

  NotificationStatus? notificationStatus;

  int retryCount;

  final String? _strategy;

  final String? _notifier;

  final int? _depth;
  final String? _atValue;

  final AtMetaData? _atMetadata;

  final int? _ttl;

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
        _atMetadata = atNotificationBuilder.atMetaData,
        _ttl = atNotificationBuilder.ttl;

  String? get id => _id;

  String? get fromAtSign => _fromAtSign;

  DateTime? get notificationDateTime => _notificationDateTime;

  String? get toAtSign => _toAtSign;

  String? get notification => _notification;

  NotificationType? get type => _type;

  OperationType? get opType => _opType;

  DateTime? get expiresAt => _expiresAt;

  String? get atValue => _atValue;

  String? get notifier => _notifier;

  int? get depth => _depth;

  String? get strategy => _strategy;

  MessageType? get messageType => _messageType;

  AtMetaData? get atMetadata => _atMetadata;

  /// Time in milliseconds after which the notification will expire
  int? get ttl => _ttl;

  Map toJson() => {
        'id': _id,
        'fromAtSign': _fromAtSign,
        'notificationDateTime': _notificationDateTime,
        'toAtSign': _toAtSign,
        'notification': _notification,
        'type': _type,
        'opType': _opType,
        'messageType': _messageType,
        'priority': priority,
        'notificationStatus': notificationStatus,
        'retryCount': retryCount,
        'strategy': _strategy,
        'depth': _depth,
        'notifier': _notifier,
        'expiresAt': _expiresAt,
        'atValue': _atValue,
        'atMetadata': _atMetadata?.toJson(),
        'ttl': _ttl
      };

  @override
  String toString() {
    return 'AtNotification{id: $_id, notificationStatus:$notificationStatus, '
        'fromAtSign: $_fromAtSign, toAtSign:$_toAtSign, '
        'strategy:$_strategy, notificationDateTime: $_notificationDateTime, '
        'notification:$_notification, type:$_type, opType:$_opType, '
        'ttl: $_ttl, expiresAt:$_expiresAt, priority:$priority, '
        'atValue:$atValue';
  }

  bool isExpired() {
    return _expiresAt != null && _expiresAt!.isBefore(DateTime.now().toUtc());
  }
}

enum NotificationStatus { delivered, errored, queued, expired }

enum NotificationType { sent, received, self }

enum OperationType { update, delete }

enum NotificationPriority { dummy, low, medium, high }

enum MessageType { key, text }

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
