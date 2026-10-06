const String atServerServiceName = 'at_secondary_server';
const String atServerTelemetryEventPrefix = 'atsign.atserver';
// The one event class sent so far. Its events are named
// atsign.atserver.lifecycle.<event>.
const String atServerLifecycleClass = 'lifecycle';
const String atServerLifecycleEventPrefix =
    '$atServerTelemetryEventPrefix.$atServerLifecycleClass';
const String atServerHeartbeatEventName =
    '$atServerLifecycleEventPrefix.heartbeat';
const String atServerStartedEventName = '$atServerLifecycleEventPrefix.started';
const String atServerStoppedEventName = '$atServerLifecycleEventPrefix.stopped';
const List<String> atServerEnabledTelemetryClasses = <String>[
  atServerLifecycleClass,
];
