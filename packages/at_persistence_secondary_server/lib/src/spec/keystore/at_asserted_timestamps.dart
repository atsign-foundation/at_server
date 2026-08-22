import 'package:at_persistence_secondary_server/src/utils/date_time_extensions.dart';

/// Caller-asserted timestamps for a keystore write.
///
/// The Atsign Protocol lets a caller transmit `createdAt` / `updatedAt` /
/// `expiresAt` / `availableAt` with a write (the `:cAt:` / `:uAt:` / `:eAt:` /
/// `:aAt:` metadata fragments), to be stored faithfully rather than rederived
/// on the receiving side. Those assertions travel as this explicit argument —
/// never smuggled through the nullable timestamp fields on `AtMetaData` —
/// because the metadata builder cannot otherwise tell "the caller asserts
/// this value" from "this value was copied out of the stored record":
/// internal read-modify-write callers routinely pass metadata objects whose
/// timestamp fields came from the store, and those writes must keep their
/// server-derived stamping.
///
/// Precedence in `AtMetadataBuilder`: an asserted value wins; an absent one
/// leaves the builder's behaviour unchanged. An asserted
/// `expiresAt`/`availableAt` suppresses the ttl/ttb derivation for that
/// write. A later write that supplies a ttl/ttb without an assertion
/// derives from now as usual; a caller that wants a write to leave an
/// expiry axis untouched asserts the record's stored absolute back (that
/// is how the update verbs keep expiry-silent writes from moving expiry).
///
/// [deriveTtl] / [deriveTtb] carry the caller's per-axis derivation
/// intent: `deriveTtl: true` means "this write supplies [expiresAt] and no
/// ttl of its own — store the ttl the absolute implies, replacing whatever
/// ttl the metadata handed to the write may carry (a retained or coerced
/// value, not the caller's)". Only the caller can make that call: by the
/// time metadata reaches the builder, a caller-supplied ttl and one merged
/// in from the stored record (or coerced from an absent field, as commons
/// `Metadata.fromJson` and the notify wire layer do — both turn an absent
/// ttl/ttb into 0) are indistinguishable. The flags default to false, so a
/// plain assertion never overwrites a relative it did not ask about.
///
/// Values are truncated to millisecond precision on construction, matching
/// the precision the keystore can hold (Hive stores [DateTime]s to
/// milliseconds).
class AtAssertedTimestamps {
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? expiresAt;
  final DateTime? availableAt;

  /// Derive and store the ttl implied by [expiresAt], replacing any ttl on
  /// the write's metadata. Meaningful only when [expiresAt] is non-null.
  final bool deriveTtl;

  /// Derive and store the ttb implied by [availableAt], replacing any ttb
  /// on the write's metadata. Meaningful only when [availableAt] is
  /// non-null.
  final bool deriveTtb;

  AtAssertedTimestamps(
      {DateTime? createdAt,
      DateTime? updatedAt,
      DateTime? expiresAt,
      DateTime? availableAt,
      this.deriveTtl = false,
      this.deriveTtb = false})
      : createdAt = createdAt?.toUtcMillisecondsPrecision(),
        updatedAt = updatedAt?.toUtcMillisecondsPrecision(),
        expiresAt = expiresAt?.toUtcMillisecondsPrecision(),
        availableAt = availableAt?.toUtcMillisecondsPrecision();

  /// `true` when no field is asserted.
  bool get isEmpty =>
      createdAt == null &&
      updatedAt == null &&
      expiresAt == null &&
      availableAt == null;

  @override
  String toString() =>
      'AtAssertedTimestamps{createdAt: $createdAt, updatedAt: $updatedAt,'
      ' expiresAt: $expiresAt, availableAt: $availableAt,'
      ' deriveTtl: $deriveTtl, deriveTtb: $deriveTtb}';
}
