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
/// leaves the builder's behaviour unchanged. In particular an asserted
/// `expiresAt`/`availableAt` suppresses the ttl/ttb derivation for that
/// write only — a later write without an assertion derives as usual.
///
/// Values are truncated to millisecond precision on construction, matching
/// the precision the keystore can hold (Hive stores [DateTime]s to
/// milliseconds).
class AtAssertedTimestamps {
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? expiresAt;
  final DateTime? availableAt;

  AtAssertedTimestamps(
      {DateTime? createdAt,
      DateTime? updatedAt,
      DateTime? expiresAt,
      DateTime? availableAt})
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
      ' expiresAt: $expiresAt, availableAt: $availableAt}';
}
