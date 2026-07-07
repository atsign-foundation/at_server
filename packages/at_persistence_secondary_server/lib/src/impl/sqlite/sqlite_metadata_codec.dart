import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// Encodes / decodes the `at_data.metadata` column and derives its indexed
/// extract columns (`expires_at` / `available_at` / `refresh_at`).
///
/// The column stores the **canonical** `AtMetaData` JSON — the exact wire
/// (`llookup:all`) form: `AtMetaData.toJson()` in its declared field order,
/// with null-valued keys stripped (readers treat absent == null; the
/// unguarded `createdAt`/`updatedAt` are always present on stored data).
/// This is the canonical interchange form.
class SqliteMetadataCodec {
  SqliteMetadataCodec._();

  /// The metadata column value for [metaData]: null-stripped canonical JSON.
  static String encode(AtMetaData metaData) =>
      jsonEncode(_stripNulls(metaData.toJson()));

  /// Reconstructs an [AtMetaData] from a stored [metadataJson] column.
  static AtMetaData decode(String metadataJson) =>
      AtMetaData().fromJson(jsonDecode(metadataJson) as Map);

  /// The `expires_at` extract (epoch millis, UTC) — the metadata's derived
  /// `expiresAt` (populated by [AtMetadataBuilder] on write, or carried
  /// verbatim on restore). `null` when the key never expires.
  static int? expiresAtMillis(AtMetaData m) =>
      m.expiresAt?.toUtc().millisecondsSinceEpoch;

  /// The `available_at` extract (epoch millis, UTC).
  static int? availableAtMillis(AtMetaData m) =>
      m.availableAt?.toUtc().millisecondsSinceEpoch;

  /// The `refresh_at` extract (epoch millis, UTC).
  static int? refreshAtMillis(AtMetaData m) =>
      m.refreshAt?.toUtc().millisecondsSinceEpoch;

  static Map<String, dynamic> _stripNulls(Map map) {
    final out = <String, dynamic>{};
    for (final entry in map.entries) {
      if (entry.value != null) out[entry.key as String] = entry.value;
    }
    return out;
  }
}
