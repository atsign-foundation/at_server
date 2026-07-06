import 'package:at_persistence_secondary_server/src/spec/spec.dart';

/// Abstract contract for an access log: an append-only audit trail
/// of which atSign performed which verb on the secondary, when, and
/// against what optional lookup-key. The Hive-backed implementation
/// is [HiveAtAccessLog]; future backends provide their own.
///
/// Access-log functionality is server-only — clients (e.g.
/// `at_client_sdk`) never read or write it. Bundle consumers that
/// run a full secondary opt into this capability via
/// [AtPersistenceConfig.enableAccessLog]; client-only consumers
/// leave it disabled.
abstract class AtAccessLog implements Compactable {
  /// Append a new entry recording that [fromAtSign] performed
  /// [verbName] (optionally against [lookupKey]) at the current
  /// instant. Returns the assigned entry id, or `null` on failure.
  Future<int?> insert(String fromAtSign, String verbName, {String? lookupKey});

  /// Top [length] atSigns by access-log entry count. Result map:
  /// atSign → visit count, ordered by descending count.
  Future<Map<String, int>> mostVisitedAtSigns(int length);

  /// Top [length] lookup keys by access-log entry count. Result map:
  /// lookup-key → visit count, ordered by descending count.
  Future<Map<String, int>> mostVisitedKeys(int length);

  /// Most-recent access-log entry, regardless of verb.
  Future<AccessLogEntry> getLastAccessLogEntry();

  /// Most-recent access-log entry whose verb is `pkam`.
  Future<AccessLogEntry?> getLastPkamAccessLogEntry();

  /// Iterate every access-log entry in insertion order. Used by the
  /// persistence migrator to copy access-log content from one
  /// backend to another.
  Stream<AccessLogEntry> iterate();

  /// Append [entry] **verbatim**, preserving its `requestDateTime`
  /// (unlike [insert], which stamps the current instant). The
  /// keystore counterpart to [iterate] for the persistence migrator:
  /// replaying every iterated entry into a fresh backend reproduces
  /// the same insertion-ordered log.
  Future<void> replay(AccessLogEntry entry);

  /// Total entry count. Used by operators / metrics; not on any
  /// hot path.
  int entriesCount();

  /// Approximate on-disk size in bytes.
  int getSize();

  /// Close the underlying storage handle.
  Future<void> close();

  /// Compact the access log. If [dryRun] is `true`, yields each
  /// entry id that WOULD be removed without performing the
  /// deletion. If `false`, performs the compaction and yields each
  /// id as it is removed.
  @override
  Stream<int> compact(bool dryRun);
}
