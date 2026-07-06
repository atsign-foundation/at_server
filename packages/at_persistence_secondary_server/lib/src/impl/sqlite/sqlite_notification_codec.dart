import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// Encodes / decodes an [AtNotification] to the `notifications.payload`
/// column and derives its indexed extract columns.
///
/// [AtNotification.toJson] is not directly `jsonEncode`-able (it embeds
/// enum and `DateTime` values), so this codec maps every field to a
/// JSON-safe form (enum → `.name`, `DateTime` → ISO-8601 UTC string,
/// metadata → `AtMetaData.toJson()`). [decode] reconstructs through
/// [AtNotificationBuilder.build], matching the Hive adapter's read-time
/// normalization exactly (ttl/expiresAt re-derivation), so both backends
/// return byte-identical notifications for the same stored row.
class SqliteNotificationCodec {
  SqliteNotificationCodec._();

  static String encode(AtNotification n) => jsonEncode({
        'id': n.id,
        'fromAtSign': n.fromAtSign,
        'notificationDateTime': n.notificationDateTime?.toUtc().toString(),
        'toAtSign': n.toAtSign,
        'notification': n.notification,
        'type': n.type?.name,
        'opType': n.opType?.name,
        'messageType': n.messageType?.name,
        'priority': n.priority?.name,
        'notificationStatus': n.notificationStatus?.name,
        'retryCount': n.retryCount,
        'strategy': n.strategy,
        'depth': n.depth,
        'notifier': n.notifier,
        'expiresAt': n.expiresAt?.toUtc().toString(),
        'atValue': n.atValue,
        'atMetadata': n.atMetadata?.toJson(),
        'ttl': n.ttl,
      });

  static AtNotification decode(String payloadJson) {
    final m = jsonDecode(payloadJson) as Map;
    final builder = AtNotificationBuilder()
      ..id = m['id'] as String?
      ..fromAtSign = m['fromAtSign'] as String?
      ..notificationDateTime = _parseDate(m['notificationDateTime'])
      ..toAtSign = m['toAtSign'] as String?
      ..notification = m['notification'] as String?
      ..type = _enum(NotificationType.values, m['type'])
      ..opType = _enum(OperationType.values, m['opType'])
      ..messageType = _enum(MessageType.values, m['messageType'])
      ..priority = _enum(NotificationPriority.values, m['priority'])
      ..notificationStatus = _enum(NotificationStatus.values, m['notificationStatus'])
      ..retryCount = (m['retryCount'] as int?) ?? 1
      ..strategy = m['strategy'] as String?
      ..depth = m['depth'] as int?
      ..notifier = m['notifier'] as String?
      ..expiresAt = _parseDate(m['expiresAt'])
      ..atValue = m['atValue'] as String?
      ..atMetaData = _decodeAtMetadata(m['atMetadata'] as Map?)
      ..ttl = m['ttl'] as int?;
    return builder.build();
  }

  /// A notification's embedded metadata — unlike stored keystore metadata —
  /// can have a null `createdAt`/`updatedAt` (it is not run through
  /// [AtMetadataBuilder]). [AtMetaData.fromJson] calls `DateTime.parse` on
  /// those two fields with no null guard, so decode tolerantly: parse with
  /// placeholder dates, then restore the true (nullable) values — matching
  /// how Hive's binary adapter preserves the nulls.
  static AtMetaData? _decodeAtMetadata(Map? m) {
    if (m == null) return null;
    final createdAt = _parseDate(m['createdAt']);
    final updatedAt = _parseDate(m['updatedAt']);
    final placeholder =
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true).toString();
    final patched = Map.of(m)
      ..['createdAt'] = createdAt?.toUtc().toString() ?? placeholder
      ..['updatedAt'] = updatedAt?.toUtc().toString() ?? placeholder;
    // fromJson also coerces a null version to 0; restore the true nullable
    // value so a notification's metadata round-trips exactly as Hive's binary
    // adapter preserves it.
    return AtMetaData().fromJson(patched)
      ..createdAt = createdAt
      ..updatedAt = updatedAt
      ..version = m['version'] as int?;
  }

  /// The `notification_datetime` extract (epoch millis, UTC).
  static int? notificationDateTimeMillis(AtNotification n) =>
      n.notificationDateTime?.toUtc().millisecondsSinceEpoch;

  /// The `type` extract (`sent` / `received` / `self`).
  static String typeExtract(AtNotification n) => n.type?.name ?? '';

  /// The `status` extract (`delivered` / `errored` / `queued` / `expired`).
  static String statusExtract(AtNotification n) =>
      n.notificationStatus?.name ?? '';

  /// The `expires_at` extract (epoch millis, UTC).
  static int? expiresAtMillis(AtNotification n) =>
      n.expiresAt?.toUtc().millisecondsSinceEpoch;

  static DateTime? _parseDate(Object? v) =>
      (v == null || v == 'null') ? null : DateTime.parse(v as String).toUtc();

  static T? _enum<T extends Enum>(List<T> values, Object? name) {
    if (name == null) return null;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }
}
