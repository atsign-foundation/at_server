## 5.0.0

Major release: persistence-overhaul. Themes:

- **Bootstrap is now factory + bundle, not singletons.**
  `AtPersistenceFactory` / `AtPersistenceBundle` replace every
  legacy `getInstance()` shim. Backend-pluggable by design.
- **Hive concretes renamed; abstract interfaces freed.**
  `HiveAtCommitLog` / `HiveAtAccessLog` /
  `HiveAtNotificationKeystore` / `HiveSecondaryKeyStore`
  implement abstract `AtCommitLog` / `AtAccessLog` /
  `AtNotificationKeystore` / `SecondaryKeyStore`. Bundles type
  at the abstracts.
- **Slim bundle + capability toggles.** `keyStore` /
  `commitLog` are core; `accessLog?` / `notificationKeystore?`
  / compactor fields are optional, gated by
  `AtPersistenceConfig` toggles. `serverDefaults` opts into
  every capability; `clientDefaults` opts into core only.
- **`SecondaryKeyStore` widened with ten new primitives** for
  at_client adoption: `exists`, `scanKeys` (with
  `KeyPattern` + ordering + pagination), `getMany`,
  `removeMany`, `changes` stream, `transaction`,
  `queryByPath` (+ `supportsPathQueries`), `snapshot`
  (+ `supportsSnapshots`), and `stats`. Capability flags let
  Phase 4 SQL backends light up native indexed query / MVCC
  paths while Hive falls back gracefully.
- **Keystore type hierarchy collapsed.**
  `SecondaryKeyStore` renamed to `AtKeyValueStore`;
  `HiveSecondaryKeyStore` renamed to `HiveAtKeyValueStore`.
  Bundle field `keyStore` renamed to `keyValueStore`.
  `Keystore` (read-only), `WritableKeystore`, and
  `SynchronizableKeyStore` collapsed into a single
  `KeyValueStore<K, V>` interface that holds the merged
  CRUD + rich surface (scan, bulk, expire, change stream,
  transaction, snapshot, stats). `AtKeyValueStore<K, V, T>`
  extends `KeyValueStore` and adds the sync-coupled surface:
  the (nullable) `commitLog`, `putMeta` / `putAll` /
  `getMeta`, and `queryByPath` /  `supportsPathQueries`.
- **Model classes decoupled from Hive.** `AtData`, `AtMetaData`,
  `CommitEntry`, `AccessLogEntry` and `AtNotification` no longer
  carry Hive's `@HiveType` / `@HiveField` annotations (they were
  dead — no codegen) or `extends HiveObject`. The hand-written
  `TypeAdapter`s moved to `lib/src/hive/adapters/` (re-exported by
  the barrel; on-disk wire format unchanged). `AtData` and
  `CommitEntry` keep a transient, non-serialized `key` field that
  the keystore populates on read, replacing the `HiveObject.key`
  that Hive used to auto-stamp. The five models are now plain Dart
  objects — the seam a future SQLite/Postgres backend needs.
- **`HiveAtKeyValueStore` value type tightened to non-null
  `AtData`.** The main keystore now implements
  `AtKeyValueStore<String, AtData, AtMetaData?>` (was
  `<String, AtData?, AtMetaData?>`), and `AtPersistenceBundle`
  surfaces it as such. `put` / `create` / `putAll` reject a
  null value at compile time instead of crashing on an internal
  `value!`; `getMany` returns `Map<String, AtData>`. `get` is
  unchanged — it still returns `Future<AtData?>` (`null` for an
  absent key). The metadata type parameter stays nullable
  (`AtMetaData?`) since `getMeta` legitimately returns `null`.
- **Keystore listing/existence APIs are now fully async, and
  list-returning queries stream.** `KeyValueStore.getKeys`,
  `getExpiredKeys` and `scanKeys` now return
  `Future<Stream<…>>`; `LogKeyStore.getExpired` and
  `AtCommitLog.getChanges` likewise return `Future<Stream<…>>`.
  The `Future` completes once the backend has accepted the
  request (so setup failures — store not open, invalid regex —
  reject eagerly rather than mid-stream); the `Stream` then
  yields the results. The synchronous `isKeyExists` is removed —
  use the async `exists` (the two were duplicates; `exists` is
  the backend-agnostic shape SQL backends need).
- **`AtKeyValueStore.commitLog` is nullable, end to end.**
  Server bundles hold a non-null commit log on the keystore;
  client bundles hold `null` (sync via fsync or other
  mechanism). `AtPersistenceConfig.enableCommitLog` (default
  `true`; `serverDefaults` → `true`, `clientDefaults` → `false`)
  selects which — when `false` the factory builds the keystore
  commit-log-free and never opens the commit-log box.
  `HiveAtKeyValueStore` honours a `null` commit log throughout:
  `put` / `create` / `putAll` / `putMeta` / `remove` /
  `removeMany` succeed and return `null` (no sequence number),
  and `compact()` is a no-op that yields nothing. The server's
  bootstrap asserts non-null once and binds to a non-nullable
  local for downstream consumers.
- **Bundle no longer exposes the commit log directly.**
  `AtPersistenceBundle.commitLog` is gone; reach it as
  `bundle.keyValueStore.commitLog!`.
- **`AtNotificationKeystore` re-parented to `KeyValueStore`.**
  No longer extends the AtKeyValueStore tier — notifications
  don't participate in the commit log. Drops the six
  `UnimplementedError` stubs and the no-op `commitLog`
  override that the old interface forced on it. Notification
  keystore implementations stop pretending to support
  `putMeta` / `putAll` / `getMeta` / `queryByPath`. Now
  strongly typed `KeyValueStore<String, AtNotification>`
  (was `<dynamic, dynamic>`) — keys are notification ids,
  values are `AtNotification`; consumers no longer cast.
- **Compaction is intrinsic, not strategy-wrapped.** The
  `Compactable` interface (one method: `Stream<Object>
  compact(bool dryRun)`) replaces `AtCompactionStrategy`,
  `HiveCompactionStrategy`, `AtCompaction`, `AtLogType`,
  `AtCompactionConfig`, and `AtCompactionStats` — all
  deleted. `AtCommitLog`, `AtAccessLog`,
  `AtNotificationKeystore`, and `AtKeyValueStore` all
  implement `Compactable`. The Hive impls each carry their
  own `compactionPercentage` constructor parameter; on
  `compact(false)` they yield the items removed,
  `compact(true)` yields what would be removed.
- **Compactor scheduling moves to `at_secondary_server`.**
  The persistence layer no longer schedules anything — the
  secondary server runs three `Timer.periodic` ticks with
  overlap guards. `AtCompactionJob` deleted.
  `AtCompactionStatsService.record()` takes primitives
  (`label`, `start`, `compactedCount`, `duration`) instead
  of an `AtCompactionStats` object.
- **`AtPersistenceConfig` compactor flags removed.**
  `enableCommitLogCompactor` / `enableAccessLogCompactor` /
  `enableKeyStoreCompactor` moved to `AtSecondaryConfig`
  (with `enableKeyStoreCompactor` → `enableNotificationCompactor`,
  matching the resource it actually gates).
- **Migrator-friendly walks.** `replay(CommitEntry)` and
  `iterate({fromCommitId, where})` on `AtCommitLog`, plus
  `iterate()` on access log + notification keystore. Lazy box-
  walks; no upfront map materialisation.
- **Commit log is one-entry-per-atKey by construction.** Inline
  single-atKey dedup in `CommitLogKeyStore.add()` plus a
  startup dedup migration. `CommitLogCompactionService` and
  `CompactionSortedList` retired (their job is done eagerly by
  the write path).
- **`AtCommitLog.getEntries` retired.** Migrate to
  `iterate(fromCommitId, where: closure)`; the closure carries
  any caller-side filtering (regex, skipDeletesUntil, etc.).
- **Keystore signatures tightened to remove `dynamic`.** CRUD
  methods on `WritableKeystore` / `SynchronizableKeyStore` now
  return `Future<int?>` (commit-log sequence number or `null`)
  instead of `Future<dynamic>`. `Keystore.get` is `Future<V?>`
  instead of `Future<V>?`. `LogKeyStore.add` returns
  `Future<int>` (Hive-assigned key); `update`/`remove` return
  `Future<void>`; `getFirstNEntries` returns `List<int>`;
  `getExpired` returns `Future<List<K>>`. `AtAccessLog`'s
  `mostVisitedAtSigns` / `mostVisitedKeys` return
  `Future<Map<String, int>>`. Pre/post-remove hook callbacks
  are `Future<void> Function(...)`. Call sites can drop
  `as int?` / `as AtData?` / `as Map` casts.
- **`SecondaryKeyStore.deleteExpiredKeys` drops `skipCommit`.**
  Expiry is treated as backend-local maintenance: the sweep
  never advances `commitId` and never propagates via sync.
- **`SecondaryKeyStore.commitLog` typed `AtCommitLog?` rather
  than `AtLogType?`.** Callers no longer need `as AtCommitLog`
  at every access site.
- **`HiveAtNotificationKeystore.commitLog` is a no-op
  getter/setter** instead of a mutable field — notifications
  never participate in the commit log.
- **`SyncProgressiveVerbHandler` empty-response wedge fixed.**
  When every entry in a requested range failed `isAuthorized`
  (or another in-loop filter), the handler returned `[]` and
  the client could not advance its `from` watermark. The
  switch to `iterate(where:)` makes the scan unbounded; the
  client now always sees forward progress. No wire-format
  change.
- **`AtConfig` moved out** of this package into
  `at_secondary_server`. Block-list writes pass
  `skipCommit: true` and don't bump the local `commitId`.
- **Test-isolation primitive.** `AtPersistenceBundle.clear()`
  drops every entry from each store while keeping underlying
  boxes open.
- **Dependency on `at_persistence_spec` dropped.** The
  interface types this package previously imported from
  `at_persistence_spec` (`SecondaryKeyStore`,
  `AtCompactionStrategy`, exceptions, the `@server`/`@client`
  annotations, and the new Phase 3 types — `KeyEntry`,
  `KeyPattern`, `KeyStoreChange`, `KeyStoreSnapshot`,
  `KeyStoreStats`, `KeyStoreTxn`, `OrderByKey`, `Predicate`)
  now live alongside the Hive implementation in this package.
  Future backend packages depend on
  `at_persistence_secondary_server` for the interface types
  they need to satisfy.

See [`MIGRATION.md`](MIGRATION.md) for the full 4.3.5 → 5.0.0
migration guide, including server / client tracks, per-primitive
recipes (signatures, before/after examples, capability-flag
callouts), and a worked-example appendix.

## 4.3.5

- perf: `NullCommitEntry` is now a singleton — no fresh `DateTime.now()`
  allocation per commit-log miss
- perf: `HiveKeystore.getKeys` caches compiled `RegExp` patterns in a
  bounded LRU and captures `DateTime.timestamp()` once per call,
  threading it into `_isExpired` / `_isBorn` / `_isKeyAvailable` so each
  key check no longer allocates two DateTime objects
- perf: `DateTime.now().toUtc()` replaced with `DateTime.timestamp()`
  (one allocation instead of two) on the keystore expiry, notification
  expiry, access-log and commit-log hot paths
- perf: `HiveKeystore.create` no longer builds a 17-element `Set` per
  put just to ask "any metadata field non-null?" — replaced with a
  direct null-check chain

## 4.3.4

- fix: Make AtNotificationKeystore.getExpiredKeys more memory efficient

## 4.3.3

- fix: Fix the `expiresAt` and `ttl` rules in `AtNotificationBuilder.build`

## 4.3.2

- fix: fixes to `AtNotification.isExpired`
- fix: fixed use of `defaulTtl` in `AtNotificationBuilder.reset` 

## 4.3.1

- fix: backwards compatibility: revert AtNotificationKeystore.currentAtSign to 
  a non-final instance variable

## 4.3.0

- feat: deprecated AtNotificationCallback class
- feat: deprecated use of AtNotificationKeystore singleton
- feat: deprecated NotificationManagerSpec
- fix: AtNotificationBuilder.build will update a null ttl to the default value
- fix: AtNotification.isExpired treats null expiry as expired, as the idea of notifications without expiration is a historical antipattern and is no longer possible

## 4.2.0 

- chore(deps): bump uuid to `^4.0.0`
- chore(deps): bump at_commons to `^5.5.0`

## 4.1.0
- feat: Add `preRemoveHook` and `postRemoveHook` to KeyStore interfaces

## 4.0.0
- refactor: Take up new major version 3.0.0 of at_persistence_spec, update and 
  simplify the HiveKeyStore implementation accordingly
- feat: (non-breaking) Add persistence support for the new `immutable` flag
## 3.1.0
- feat: commit log changes for sync skipDeletesUntil feature
- build[deps]: Upgraded the following package:
  - at_commons to v5.1.0
## 3.0.66
- feat: Add "PublicKeyHash" to the "AtMetadata" which holds the hash value of encryption public key
- build[deps]: Upgraded the following packages:
  - at_commons to v5.0.2
  - lints to v5.0.0
  - test to v1.25.8
## 3.0.65
- fix: Modified checks in commit log keystore _alwaysIncludeInSync method to match only reserved shared_key,
  encryption public key and public key without namespace.
- build[deps]: Upgraded the following packages:
  - at_commons to v5.0.1
## 3.0.64
- build[deps]: Upgraded the following packages:
  - at_commons to v5.0.0
  - at_utils to v3.0.19
## 3.0.63
- fix: Ensure only latest commitEntry for each present in CommitLogCache
## 3.0.62
- fix: Add check for hive key max length (255 chars)
- build[deps]: Upgraded the following packages:
  - at_commons to v4.0.5
  - hive to v2.2.3
  - crypto to v3.0.3
## 3.0.61
- feat: delete entries for expired keys are not committed to the commitLog [feature not enabled yet]
## 3.0.60
- build[deps]: Upgraded the following packages:
    - at_commons to v4.0.0
    - at_utils to v3.0.16
## 3.0.59
- fix: When checking namespace authorization, gracefully handle any malformed 
  keys which happen to be in the commit log for historical reasons
## 3.0.58
- fix: Modify "lastCommittedSequenceNumberWithRegex" to return highest commitId among enrolled namespaces
## 3.0.57
- fix: Refactor commit log keystore to optimize memory usage
## 3.0.56
- fix: Refactor Hive keystore to optimize memory usage
- fix: Apply Utf7.decode function to decode the keys and atSigns containing emojis.
- feat: add skipCommit flag to keystore implementation which enables skipping commit log for put/create/remove.
## 3.0.54
- fix: Add NotificationType.Self in read and write methods of at_notification.dart
## 3.0.53
- feat: Introduced self notification type in enum for apkam enrollment
- chore: upgraded at_commons to 3.0.50 and at_utils to 3.0.14
## 3.0.52
- feat: Add new encryption metadata fields to core persistence classes
## 3.0.51
- feat: Extend sanity-checking of server-side commitLog upon startup
## 3.0.50
- fix: AtMetaData.fromJson now preserves null values for ttl, ttb and ttr
- test: Add '==' & hashCode to AtMetaData in order to be able to test equality
- test: Added tests which verify JSON round-tripping of AtMetaData objects
- refactor: Deprecate at_metadata_adapter; extract the 'to' and 'from' commons Metadata methods from there into the AtMetaData class itself
## 3.0.49
- fix: AtData.toJson() now works when the key is null
## 3.0.48
- fix: Ensure HiveKeystore's metaDataCache's keys are in lower case
## 3.0.47
- feat: conform to at_persistence_spec 2.0.11
## 3.0.46
- fix: AtMetadata.version does not update on the update of a key
## 3.0.45
- fix: Introduce "isScheduled" method in "AtCompactionService" to know if the compaction job is running
## 3.0.44
- fix: Refactor AtCompaction job
## 3.0.43
- fix: Fetch only commit entries with 'null' commit-id for uncommitted entries in at_client persistence
## 3.0.42
- fix: rollback keystore delete KeyNotFoundException
## 3.0.41
- fix: store actual keys in hive keystore metadata cache instead of encoded keys
- feat: throw KeyNotFoundException if key to be removed is not present in keystore
## 3.0.40
- feat: Refrain adding local keys to commit log.
## 3.0.39
- fix: lastSyncedEntry to accept signing private key
## 3.0.38
- fix: Revert sync of signing keys and 'statsNotificationId'
## 3.0.37
- fix: skip commit id for the 'statsNotificationId'
## 3.0.36
- fix: skip commit id and sync for signing keys
- fix: dart analyzer issues
- chore: upgrade third party dependencies
## 3.0.35
- fix: Randomize the cron job's start interval
- fix: Reduce the default notification expiry duration
## 3.0.34
* fix: Reverted dependency on 'meta' package to ^1.7.0 as flutter_test package (currently) requires 1.7.0
## 3.0.33
- feat: added key validation to keystore put and create methods
- chore: upgraded at_commons version to 3.0.24
## 3.0.32
- Add 'encoding' to AtMetadata which represents the type of encoding
## 3.0.31
- Invalidate commit log cache on removing entry from commit log
## 3.0.30
- Enhance KeyNotFoundException to chain into exception hierarchy.
- Upgrade at_commons version to 3.0.20 to encrypt notify text
## 3.0.29
- Introduced option to stop current schedule of a compaction job
- Enable the public hidden keys to sync between local and cloud secondary
- Uptake at_commons to 3.0.18 to optionally display hidden keys in scan
## 3.0.28
- Updated lastSyncedEntryCacheMap regex to match the reserved keys
- Upgraded to version 2.0.6 of at_persistence_spec containing @server/@client annotations
## 3.0.27
- Downgrade meta package to 1.7.0(minimum) version
## 3.0.26
- Replace null commitId's with hive internal key on secondary server startup
- Return commit entry with highest commitId from lastSyncedEntry
- Upgrade at_commons version for AtException hierarchy
## 3.0.25
- To reduce latency on notifications, publish the event for the notification before persisting the notification 
## 3.0.24
- Introduced a cache to speed up metaData retrieval.
- Removed unnecessary print statements
## 3.0.23
- Add remove method in NotificationManagerSpec.
## 3.0.22
- Bumped some dependencies
## 3.0.21
- Upgrade at_lookup and at_commons for NotifyRemove
## 3.0.20
- Upgrade Hive version to 2.1.0
## 3.0.19
- add encryption shared key and public key checksum to metadata
## 3.0.18
- Renamed compaction stats attributes
- Modified return type and added optional params in hive keystore put and create methods
## 3.0.17
- Support to collect and store compaction statistics
## 3.0.16
- at_lookup version upgrade for implementing server error responses
- at_commons version upgrade for AtTimeoutException
## 3.0.15
- at_utils version upgrade
## 3.0.14
- Fix commit log compaction issue.
## 3.0.13
- at_utils and at_commons version upgrade.
- Fix notification expiry bug.
## 3.0.12
- Changes to support reset of ttb
## 3.0.11
- Enhance commit log compaction service
## 3.0.10
- persistence spec version upgrade
## 3.0.9
- Added support for notification expiry based on ttl
## 3.0.8
- at_utils and at_commons version upgrade.
## 3.0.7
- compaction delete bug fix
- reduce compaction frequency to 12 hours
## 3.0.6
- Support for Hive lazy and in memory boxes
## 3.0.5
- Rollback hive lazy box
## 3.0.4
- Remove compaction strategy
## 3.0.3
- Fix for sync bug in commit log
## 3.0.2
- Add null check in commitLog KeyStore
## 3.0.1
- Change Hive box type to lazy box
## 3.0.0
- Sync pagination feature
## 2.0.6
- fix for hive closed box issue
## 2.0.5
- logs for hive closed box issue
## 2.0.4
- at_commons version change for last notification time in monitor
## 2.0.3
- at_commons version change for stream resume
## 2.0.2
- at_commons version change
## 2.0.1
- at_commons version change
## 2.0.0
- Null safety upgrade
## 1.0.1+8
- Refactor code with dart lint rules
- Fixed minor bug in secondary persistence store factory
## 1.0.1+7
- Third party package dependency upgrade
## 1.0.1+6
- Add await on close methods.
## 1.0.1+5
- Notification sub system changes
## 1.0.1+4
- Added Support for multiple AtSigns
- Introduced batch verb for sync
## 1.0.1+3
- Public data Signing
- Sync with regex
- at_persistence_spec changes
## 1.0.1+2
- Notifylist issue fix for atSigns with emojis Add close methods for keystore.
## 1.0.1+1
- at_persistence_spec version changes
## 1.0.1
 - Documentation changes
## 1.0.0
- Initial version, created by Stagehand




