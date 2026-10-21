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

// attributes
const int atServerTelemetryMaxValueLength = 64;
const String connectionIdAttribute = 'atsign.connection.id';
const String connectionOpenedAtAttribute = 'atsign.connection.opened_at';
const String connectionTransportAttribute = 'atsign.connection.transport';
const String connectionAuthTypeAttribute = 'atsign.connection.auth_type';
const String connectionSelfNotificationsAttribute =
    'atsign.connection.self_notifications';
const String connectionCloseReasonAttribute = 'atsign.connection.close_reason';
const String connectionDurationAttribute = 'atsign.connection.duration_ms';
const String enrollmentAppNameAttribute = 'atsign.enrollment.app_name';
const String enrollmentDeviceNameAttribute = 'atsign.enrollment.device_name';
const String clientAppNameAttribute = 'atsign.client.app_name';
const String clientAppVersionAttribute = 'atsign.client.app_version';
const String clientPlatformAttribute = 'atsign.client.platform';
const String clientSdkVersionAttribute = 'atsign.client.sdk_version';
