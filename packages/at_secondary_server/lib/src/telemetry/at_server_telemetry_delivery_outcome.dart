// What one attempt to send an outbox batch to the collector came to
enum AtServerTelemetryDeliveryOutcome {
  // The collector took it; remove it from the outbox
  delivered,
  // The collector will never take it; drop it
  rejected,
  // Try again after a backoff
  retry,
}
