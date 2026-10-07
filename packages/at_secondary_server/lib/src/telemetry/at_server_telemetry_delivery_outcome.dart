// What one attempt to send a buffered batch to the collector came to
enum AtServerTelemetryDeliveryOutcome {
  // The collector took it; remove it from the buffer
  delivered,
  // The collector will never take it; drop it
  rejected,
  // Try again after a backoff
  retry,
}
