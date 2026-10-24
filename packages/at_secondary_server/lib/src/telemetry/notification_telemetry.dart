import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/monitor_sink.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:at_telemetry/at_telemetry.dart';

import 'at_server_telemetry.dart';
import 'at_server_telemetry_constants.dart';

/// Reports what becomes of notifications, through an [AtServerTelemetry].
final class NotificationTelemetry {
  /// Reports through [telemetry], or nowhere when it is omitted.
  NotificationTelemetry([AtServerTelemetry? telemetry])
      : _telemetry = telemetry ?? AtServerTelemetry(heartbeatInterval: null);

  static const Map<NotificationStatus, String> _settledEvents =
      <NotificationStatus, String>{
    NotificationStatus.delivered: atServerNotificationDeliveredEventName,
    NotificationStatus.expired: atServerNotificationExpiredEventName,
    NotificationStatus.errored: atServerNotificationErrorEventName,
  };

  final AtServerTelemetry _telemetry;

  bool get isEnabled => _telemetry.isEnabled;

  /// Reports how a notification this atServer sends to another atSign
  /// settled, by its status: delivered, expired or errored. Any other status
  /// sends nothing.
  ///
  /// Delivered means the recipient's atServer answered `data:success`, which
  /// it also answers for a notification it drops. The sender chooses the id,
  /// so a collector matches this to the recipient's report on sender,
  /// recipient and id together.
  void settled(AtNotification n) {
    final String? name = _settledEvents[n.notificationStatus];
    if (name == null) {
      return;
    }
    _emit(name, n, <String, Object?>{
      if (n.toAtSign case final String toAtSign)
        notificationToAttribute: toAtSign,
    });
  }

  /// Reports a notification another atServer delivered, listing once each
  /// enrollment proved by pkam that one of [pushedTo] was written for. A
  /// push to a CRAM connection is neither listed nor counted, and
  /// [pushedTo] holds only pushes written before the report went out.
  void received(
    AtNotification n, {
    List<LivePush> pushedTo = const <LivePush>[],
  }) {
    final Set<String> devices = <String>{
      for (final LivePush push in pushedTo)
        if (push.authType == AuthType.apkam ||
            push.authType == AuthType.pkamLegacy)
          if (push.enrollmentId case final String enrollmentId) enrollmentId,
    };
    _emit(atServerNotificationReceivedEventName, n, <String, Object?>{
      if (n.fromAtSign case final String fromAtSign)
        notificationFromAttribute: fromAtSign,
      notificationPushCountAttribute: devices.length,
      if (devices.isNotEmpty)
        notificationPushedToAttribute: <Map<String, Object?>>[
          for (final String enrollmentId in devices)
            <String, Object?>{
              AtTelemetryAttributes.enrollmentId: enrollmentId,
            },
        ],
    });
  }

  void _emit(String name, AtNotification n, Map<String, Object?> attributes) {
    _telemetry.emitEvent(name,
        attributes: attributes,
        notificationIds: <String>[if (n.id case final String id) id]);
  }
}
