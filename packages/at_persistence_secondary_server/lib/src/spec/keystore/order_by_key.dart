/// Ordering options for [`SecondaryKeyStore.scanKeys`].
///
/// `null` (the default) means "use the backend's natural order" —
/// Hive returns insertion order; SQL backends return primary-key
/// order. Callers that need a specific ordering should pick a
/// member of this enum.
enum OrderByKey {
  /// Lexicographic ascending order on the key string.
  byKey,

  /// Ascending order by the entry's `createdAt` metadata field.
  /// Hive impl: O(N log N) — must materialise every entry to read
  /// metadata, then sort. SQL impls: indexed ORDER BY.
  byCreatedAt,

  /// Ascending order by the entry's `expiresAt` metadata field.
  /// Entries with no expiry sort last. Hive impl: O(N log N) for
  /// the same reason as `byCreatedAt`. SQL impls: indexed ORDER BY.
  byExpiresAt,
}
