import 'dart:math';

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

  /// 1. A notification may have an expiration no more than this duration into
  /// the future.
  /// 2. If notificationDateTime is before now minus this duration,
  /// then the notification is considered to be expired.
  static Duration maxTtl = Duration(days: 8);

  /// The default used by [AtNotificationBuilder.build] to calculate expiresAt
  static Duration defaultTtl = Duration(minutes: 15);

  /// true if
  /// - [notificationStatus] is [NotificationStatus.expired]
  /// - or [expiresAt] is null, or before now
  /// - or [notificationDateTime] is null, or more than
  ///   [maxTtl] ago
  ///
  /// The reason for the check on [notificationDateTime] is to help with
  /// cleaning out old bad data from a time when there were no guards on [ttl]
  /// or [expiresAt]
  bool isExpired() {
    // expiresAt == null never made sense and never now happens
    if (notificationStatus == NotificationStatus.expired ||
        expiresAt == null ||
        notificationDateTime == null) {
      return true;
    }
    final now = DateTime.timestamp();
    return expiresAt!.isBefore(now) ||
        notificationDateTime!.isBefore(now.subtract(maxTtl));
  }
}

enum NotificationStatus { delivered, errored, queued, expired }

enum NotificationType { sent, received, self }

enum OperationType { update, delete }

enum NotificationPriority { dummy, low, medium, high }

enum MessageType { key, text }

/// AtNotificationBuilder class to build [AtNotification] object
class AtNotificationBuilder {
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

  int? ttl = AtNotification.defaultTtl.inMilliseconds;

  AtMetaData? atMetaData;

  /// Applies the following rules, then builds the [AtNotification]
  /// 1. if [expiresAt] is null
  ///   1. If [ttl] is null or non-positive, set to [defaultTtl]
  ///   2. Ensure that [ttl] is no greater than [AtNotification.maxTtl]
  ///   3. calculate [expiresAt] by adding [ttl] to [DateTime.now]
  /// 2. Ensure that [expiresAt] is no more than [AtNotification.maxTtl] in
  /// the future
  ///
  /// Explanation of the above:
  /// - [ttl] can be supplied by AtClients when sending a notification, and
  /// [expiresAt] is calculated at that time. (Note: In future, clients will be
  /// able to specify a precise [expiresAt], and the above rules will work
  /// unchanged.)
  /// - expiresAt should be sent as-is from sending atServer to receiving
  /// - if expiresAt is set, ttl is not relevant
  AtNotification build() {
    final now = DateTime.now().toUtcMillisecondsPrecision();
    final maxExpiresAt = now.add(AtNotification.maxTtl);

    // 1.1 - set ttl to default if null or non-positive
    if (ttl == null || ttl! <= 0) {
      ttl = AtNotification.defaultTtl.inMilliseconds;
    }
    // 1.2 - enforce max ttl value
    ttl = min(ttl!, AtNotification.maxTtl.inMilliseconds);

    // ignore: prefer_conditional_assignment
    if (expiresAt == null) {
      // 1.3 - calculate expiresAt
      expiresAt ??= now.add(Duration(milliseconds: ttl!));
    }

    // 2. ensure no later than maxExpiresAt
    if (expiresAt!.millisecondsSinceEpoch >
        maxExpiresAt.millisecondsSinceEpoch) {
      expiresAt = maxExpiresAt;
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
      ..ttl = AtNotification.defaultTtl.inMilliseconds
      ..atMetaData = null;
  }
}
