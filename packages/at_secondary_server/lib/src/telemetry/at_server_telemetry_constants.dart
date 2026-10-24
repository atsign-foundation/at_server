const String atServerServiceName = 'at_secondary_server';
const String atServerTelemetryEventPrefix = 'atsign.atserver';

// events
const String atServerStartedEventName =
    '$atServerTelemetryEventPrefix.lifecycle.started';
const String atServerHeartbeatEventName =
    '$atServerTelemetryEventPrefix.lifecycle.heartbeat';
const String atServerStoppedEventName =
    '$atServerTelemetryEventPrefix.lifecycle.stopped';
const String atServerConnectionAuthenticatedEventName =
    '$atServerTelemetryEventPrefix.connection.authenticated';
const String atServerConnectionMonitoringEventName =
    '$atServerTelemetryEventPrefix.connection.monitoring';
const String atServerConnectionClosedEventName =
    '$atServerTelemetryEventPrefix.connection.closed';
const String atServerNotificationDeliveredEventName =
    '$atServerTelemetryEventPrefix.notification.delivered';
const String atServerNotificationExpiredEventName =
    '$atServerTelemetryEventPrefix.notification.expired';
const String atServerNotificationErrorEventName =
    '$atServerTelemetryEventPrefix.notification.error';
const String atServerNotificationReceivedEventName =
    '$atServerTelemetryEventPrefix.notification.received';

// attributes
const int atServerTelemetryMaxValueLength = 64;
const String connectionIdAttribute = 'atsign.connection.id';
const String connectionTransportAttribute = 'atsign.connection.transport';
const String connectionCloseReasonAttribute = 'atsign.connection.close_reason';
const String enrollmentAppNameAttribute = 'atsign.enrollment.app_name';
const String enrollmentDeviceNameAttribute = 'atsign.enrollment.device_name';
const String notificationFromAttribute = 'atsign.notification.from';
const String notificationToAttribute = 'atsign.notification.to';
const String notificationPushCountAttribute = 'atsign.notification.push_count';
const String notificationPushedToAttribute = 'atsign.notification.pushed_to';
const String connectionAuthTypeAttribute = 'atsign.connection.auth_type';
