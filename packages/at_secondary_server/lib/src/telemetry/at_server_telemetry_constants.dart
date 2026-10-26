const String atServerServiceName = 'at_secondary_server';
const String atServerTelemetryEventPrefix = 'atsign.atserver';

// events
const String atServerStartedEventName =
    '$atServerTelemetryEventPrefix.lifecycle.started';
const String atServerHeartbeatEventName =
    '$atServerTelemetryEventPrefix.lifecycle.heartbeat';
const String atServerStoppedEventName =
    '$atServerTelemetryEventPrefix.lifecycle.stopped';
const String atServerNotificationDeliveredEventName =
    '$atServerTelemetryEventPrefix.notification.delivered';
const String atServerNotificationExpiredEventName =
    '$atServerTelemetryEventPrefix.notification.expired';
const String atServerNotificationErrorEventName =
    '$atServerTelemetryEventPrefix.notification.error';
const String atServerNotificationReceivedEventName =
    '$atServerTelemetryEventPrefix.notification.received';

// attributes
const String notificationFromAttribute = 'atsign.notification.from';
const String notificationToAttribute = 'atsign.notification.to';
const String notificationPushCountAttribute = 'atsign.notification.push_count';
const String notificationPushedToAttribute = 'atsign.notification.pushed_to';
