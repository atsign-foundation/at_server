const String atServerServiceName = 'at_secondary_server';
const String atServerTelemetryEventPrefix = 'atsign.atserver';
// The one event sent so far
const String atServerHeartbeatEventName =
    '$atServerTelemetryEventPrefix.lifecycle.heartbeat';
// Heartbeat attributes reporting the in-memory buffer: the batches and bytes
// waiting to be sent, and the batches dropped since boot for going over its
// limit
const String atServerBufferBatchesAttribute = 'atsign.telemetry.buffer.batches';
const String atServerBufferBytesAttribute = 'atsign.telemetry.buffer.bytes';
const String atServerBufferDroppedAttribute = 'atsign.telemetry.buffer.dropped';
