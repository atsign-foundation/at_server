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
