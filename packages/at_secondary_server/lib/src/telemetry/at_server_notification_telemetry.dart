import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_telemetry/at_telemetry.dart';

import 'at_server_telemetry.dart';
import 'at_server_telemetry_constants.dart';

final class AtServerNotificationTelemetry {
  final AtServerTelemetry _telemetry;

  AtServerNotificationTelemetry(this._telemetry);

  void delivered(AtNotification notification) {
    _emit(
      atServerNotificationDeliveredEventName,
      notification,
      <String, Object?>{
        if (notification.toAtSign case final String toAtSign)
          notificationToAttribute: toAtSign,
      },
    );
  }

  void expired(AtNotification notification) {
    _emit(
      atServerNotificationExpiredEventName,
      notification,
      <String, Object?>{
        if (notification.toAtSign case final String toAtSign)
          notificationToAttribute: toAtSign,
      },
    );
  }

  void error(AtNotification notification) {
    _emit(
      atServerNotificationErrorEventName,
      notification,
      <String, Object?>{
        if (notification.toAtSign case final String toAtSign)
          notificationToAttribute: toAtSign,
      },
    );
  }

  void received(AtNotification notification) {
    _emit(
      atServerNotificationReceivedEventName,
      notification,
      <String, Object?>{
        if (notification.fromAtSign case final String fromAtSign)
          notificationFromAttribute: fromAtSign,
      },
    );
  }

  void pushed(AtNotification notification, {String? enrollmentId}) {
    _emit(
      atServerNotificationPushedEventName,
      notification,
      <String, Object?>{
        if (notification.fromAtSign case final String fromAtSign)
          notificationFromAttribute: fromAtSign,
        if (enrollmentId != null)
          AtTelemetryAttributes.enrollmentId: enrollmentId,
      },
    );
  }

  void _emit(
    String name,
    AtNotification notification,
    Map<String, Object?> attributes,
  ) {
    _telemetry.emitEvent(
      name,
      attributes: <String, Object?>{
        ...attributes,
        if (notification.id case final String id)
          AtTelemetryAttributes.notificationIds: <String>[id],
      },
    );
  }
}
