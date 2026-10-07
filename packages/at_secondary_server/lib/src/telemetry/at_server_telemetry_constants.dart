const String atServerServiceName = 'at_secondary_server';
const String atServerTelemetryEventPrefix = 'atsign.atserver';
// The one event sent so far
const String atServerHeartbeatEventName =
    '$atServerTelemetryEventPrefix.lifecycle.heartbeat';
// Heartbeat attributes reporting the outbox: the batches and bytes waiting to
// be sent, and the batches dropped since boot for going over its limits
const String atServerOutboxBatchesAttribute = 'atsign.telemetry.outbox.batches';
const String atServerOutboxBytesAttribute = 'atsign.telemetry.outbox.bytes';
const String atServerOutboxDroppedAttribute = 'atsign.telemetry.outbox.dropped';
