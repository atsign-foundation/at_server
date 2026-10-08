const String atServerServiceName = 'at_secondary_server';
const String atServerTelemetryEventPrefix = 'atsign.atserver';

// events
const String atServerStartedEventName =
    '$atServerTelemetryEventPrefix.lifecycle.started';
const String atServerHeartbeatEventName =
    '$atServerTelemetryEventPrefix.lifecycle.heartbeat';
const String atServerStoppedEventName =
    '$atServerTelemetryEventPrefix.lifecycle.stopped';

// Attributes of the heartbeat and stopped events reporting the in-memory
// buffer: the batches and bytes waiting to be sent, and the batches dropped
// since boot for going over its limit
const String atServerBufferBatchesAttribute = 'atsign.telemetry.buffer.batches';
const String atServerBufferBytesAttribute = 'atsign.telemetry.buffer.bytes';
const String atServerBufferDroppedAttribute = 'atsign.telemetry.buffer.dropped';
