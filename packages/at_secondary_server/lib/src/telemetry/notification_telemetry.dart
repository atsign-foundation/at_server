import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
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

  /// Reports a notification another atServer delivered, with the monitor
  /// connections it was pushed to.
  void received(
    AtNotification n, {
    List<InboundConnectionMetadata> pushedTo =
        const <InboundConnectionMetadata>[],
  }) {
    _emit(atServerNotificationReceivedEventName, n, <String, Object?>{
      if (n.fromAtSign case final String fromAtSign)
        notificationFromAttribute: fromAtSign,
      notificationPushCountAttribute: pushedTo.length,
      if (pushedTo.isNotEmpty)
        notificationPushedToAttribute: <Map<String, Object?>>[
          for (final InboundConnectionMetadata connection in pushedTo)
            <String, Object?>{
              if (connection.enrollmentId case final String enrollmentId)
                AtTelemetryAttributes.enrollmentId: _bounded(enrollmentId),
            },
        ],
    });
  }

  void _emit(String name, AtNotification n, Map<String, Object?> attributes) {
    _telemetry.emitEvent(name,
        attributes: attributes,
        notificationIds: <String>[if (n.id case final String id) id]);
  }

  String _bounded(String value) {
    return value.length <= atServerTelemetryMaxValueLength
        ? value
        : value.substring(0, atServerTelemetryMaxValueLength);
  }
}
