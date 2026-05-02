## 5.5.0

- feat: add `Stream<KeyStoreChange> get changes` to the abstract
  `SecondaryKeyStore`, plus a sealed `KeyStoreChange` hierarchy
  in `at_persistence_spec` (`KeyAdded` / `KeyUpdated` /
  `KeyRemoved`). Broadcast stream of every successful mutation:
  `create()` emits `KeyAdded`; the update path of `put()` (and
  `putAll` / `putMeta` when they write) emits `KeyUpdated` (or
  `KeyAdded` if the key didn't previously exist); `remove()` and
  `removeMany()` emit `KeyRemoved` per actually-removed key.
  Failed writes don't emit. Late subscribers don't see prior
  events (broadcast semantics). HiveSecondaryKeyStore +
  HiveAtNotificationKeystore both implement. Phase 3 sub-phase
  3e — pushes the broadcast pattern from at_client_sdk's
  `LocalSecondary` (commit `7820f99b6` over there) down a layer
  so `LocalSecondary.dataEvents` simplifies to a filter/transform.
  See `MIGRATION.md` "What's new in 5.5.0".

## 5.4.0

- feat: add
  `Future<int> removeMany(List<K> keys, {bool skipCommit = false})`
  to the abstract `SecondaryKeyStore`. Bulk delete — returns the
  number of keys actually removed (race-tolerant: absent keys
  don't contribute to the count). On the secondary keystore each
  removal still emits a commit-log DELETE entry (one per removed
  key) unless `skipCommit: true` is passed, in which case prior
  commit entries for the deleted keys are scrubbed and no new
  ones are written. Hive impl: contains-checks each input,
  dedupes by lowercased form, runs preRemoveHooks, calls a single
  batched `Box.deleteAll`, then per-key `_expiryKeysCache.remove`,
  commit-log bookkeeping, and postRemoveHooks. Empty input is a
  no-op that returns 0. Phase 3 sub-phase 3d. See `MIGRATION.md`
  "What's new in 5.4.0" for the migration recipe.

## 5.3.0

- feat: add `Future<Map<K, V>> getMany(List<K> keys)` to the
  abstract `SecondaryKeyStore`. Bulk fetch — returns the values
  for every key in the input list that's currently present in
  the keystore (absent keys are NOT in the result map; callers
  that need to know which inputs missed compare `result.keys`
  against `keys.toSet()`). Hive impl iterates the input,
  `box.containsKey`-checks each, fetches present ones from the
  underlying LazyBox; map keyed by lowercased input form to
  match `get()` semantics. Phase 3 sub-phase 3c. See
  `MIGRATION.md` "What's new in 5.3.0" for the migration recipe.

## 5.2.0

- feat: add `KeyPattern` (in `at_persistence_spec`) and
  `Stream<String> scanKeys(KeyPattern pattern, {bool includeExpired = false})`
  on the abstract `SecondaryKeyStore`. Backend-portable structured
  successor to `getKeys(regex: ...)`: filter by `sharedBy`,
  `sharedWith`, `namespace`, and/or `idPrefix` (each independently
  optional; AND-combined). Hive impl iterates and filters with
  `AtKey.fromString` parsing per-key (O(box-size) — same as
  `getKeys(regex)`); future SQL backends translate the pattern into
  composite-index `WHERE` clauses (O(matching)). The notification
  keystore implements `scanKeys` too — only `idPrefix` and the
  unrestricted-pattern path are meaningful for notification ids
  (which aren't atKey-shaped); atKey-only fields return empty.
  `getKeys(regex: ...)` stays in place — nothing is deprecated in
  5.2.0. Phase 3 sub-phase 3b. See `MIGRATION.md` "What's new in
  5.2.0" for the migration recipe.

## 5.1.0

- feat: add `Future<bool> exists(String key)` to the abstract
  `SecondaryKeyStore`. Async flavour of the existing synchronous
  `bool isKeyExists(String key)`; provides a backend-agnostic
  forward-compat shape that works against Hive today and async
  backends (SQLite, Postgres) tomorrow. Hive impls (in
  `HiveSecondaryKeyStore` and `HiveAtNotificationKeystore`)
  delegate to `isKeyExists`. Both methods coexist — pick whichever
  fits the call site. Phase 3 sub-phase 3a of the persistence
  overhaul (design source: `better-cheaper-faster-at-client.md`).
  See `MIGRATION.md` "What's new in 5.1.0" for the migration recipe.

## 5.0.0

- feat: introduce `AtPersistenceFactory` and `AtPersistenceBundle`
  abstractions plus a `HiveAtPersistenceFactory` concrete impl as
  the new way to wire per-atSign persistence stores. Designed to be
  backend-pluggable (a future RDBMS-backed factory can satisfy the
  same interface).
- refactor: `HivePersistenceManager.scheduleKeyExpireTask` no longer
  reaches back into `SecondaryPersistenceStoreFactory.getInstance()`
  at each cron tick; uses a `keyStoreForExpireTask` reference set at
  construction. Falls back to the singleton lookup if not set,
  preserving backward compatibility for external callers that
  construct `HivePersistenceManager` outside the factory.
- refactor: `AtCompactionJob._random` is now an instance field
  rather than `static final`, so concurrent jobs across atSigns no
  longer share an RNG.
- chore: add `clear()` methods to `AtAccessLogManagerImpl` and
  `SecondaryPersistenceStoreFactory` (mirroring the existing
  `AtCommitLogManagerImpl.clear()`) so callers can wipe the
  per-atSign cache without re-closing already-closed Hive boxes.
- deprecate: `SecondaryPersistenceStoreFactory.getInstance()`,
  `AtCommitLogManagerImpl.getInstance()`,
  `AtAccessLogManagerImpl.getInstance()`,
  `AtCompactionService.getInstance()`,
  `HiveKeyStoreHelper.getInstance()`. Use `HiveAtPersistenceFactory`
  (or any `AtPersistenceFactory`) and inject the resulting bundle
  instead. Will be removed in the next major release.
- chore: delete the previously-deprecated `AtNotificationCallback`
  class and its only caller (in `AtNotificationKeystore.put()`).
- refactor!: `AtConfig` now takes a `SecondaryKeyStore` (not an
  `AtCommitLog`) by constructor. All reads / writes route through
  the abstract keystore; writes pass `skipCommit: true` so block-list
  changes no longer bump the local `commitId`. Drops three deprecated
  `getInstance()` calls (`SecondaryPersistenceStoreFactory`,
  `HiveKeyStoreHelper.prepareKey` / `prepareDataForKeystoreOperation`)
  and all direct `LazyBox` / `HiveError` use. Eliminates the
  redundant double-fetch in `addToBlockList` / `removeFromBlockList`.
- breaking: `AtConfig` and `Configuration` have moved to
  `package:at_secondary/src/config/`. `at_persistence_secondary_server`
  no longer re-exports `AtConfig` (a deprecated re-export shim is
  not feasible because `at_secondary` depends on
  `at_persistence_secondary_server`, not the other way around). No
  external consumers were found in a sweep of the atsign repos
  (`at_client_sdk`, `at_services`, `at_tools`); update any local
  imports to `package:at_secondary/src/config/at_config.dart`.
- breaking: `AtCompactionJob` and `AtCompactionStatsServiceImpl`
  constructors now take a `SecondaryKeyStore` instead of a
  `SecondaryPersistenceStore`. Callers that construct these directly
  (none found in the atsign repos sweep) need to pass the keystore
  in place of the persistence store.
- refactor: `HiveAtPersistenceBundle` no longer exposes
  `secondaryPersistenceStore` or `hivePersistenceManager`. Production
  consumers use only the abstract `AtPersistenceBundle` surface
  (`keyStore`, `commitLog`, `accessLog`, `notificationKeystore`,
  `scheduleKeyExpireTask`, `close`).
- refactor!: Hive-backed concrete classes renamed so the unprefixed
  names are free for the abstract interfaces introduced in a
  follow-up commit. `AtCommitLog` → `HiveAtCommitLog`,
  `ClientAtCommitLog` → `HiveClientAtCommitLog`, `AtAccessLog` →
  `HiveAtAccessLog`, `AtNotificationKeystore` →
  `HiveAtNotificationKeystore`, `HiveKeystore` →
  `HiveSecondaryKeyStore`. File paths follow the same rename
  (`at_commit_log.dart` → `hive_at_commit_log.dart`, etc.). No
  deprecated re-exports under the old names — see `MIGRATION.md`
  for find-and-replace recipes.
- docs: add `MIGRATION.md` covering the 4.3.5 → 5.0.0 changes,
  split into server and client tracks (the impact differs
  significantly between consumers that run a full atSecondary
  versus those that only run a local-secondary cache).
- feat!: introduce abstract `AtCommitLog` / `AtAccessLog` /
  `AtNotificationKeystore` interfaces under the now-free unprefixed
  names. The Hive concretes (`HiveAtCommitLog` etc.) implement
  them; bundle fields type at the abstracts. Replaces the legacy
  `BaseAtCommitLog` parent class. `SecondaryKeyStore` was already
  abstract in `at_persistence_spec` and is unaffected.
- feat: `AtPersistenceBundle` is now a slim core (`keyStore`,
  `commitLog`, `scheduleKeyExpireTask`, `close`) plus optional
  capabilities exposed as nullable getters (`accessLog?`,
  `notificationKeystore?`). `AtPersistenceConfig` gains
  `enableAccessLog` and `enableNotificationKeystore` toggles.
  `HivePersistenceConfig.serverDefaults(...)` opts into every
  capability; `HivePersistenceConfig.clientDefaults(...)` opts into
  core only — the latter intended for at_client_sdk's local-secondary
  cache.
- feat: add `AtCommitLog.replay(CommitEntry)` and
  `AtCommitLog.iterate({int? fromCommitId})`,
  `AtAccessLog.iterate()`,
  `AtNotificationKeystore.iterate()` for use by the Phase 3
  persistence-backend migrator. `replay` writes an entry under its
  supplied `commitId` without firing change-event listeners.
- breaking: removed the deprecated `getInstance()` shims:
  `SecondaryPersistenceStoreFactory.getInstance()`,
  `AtCommitLogManagerImpl.getInstance()`,
  `AtAccessLogManagerImpl.getInstance()`,
  `AtCompactionService.getInstance()`,
  `HiveKeyStoreHelper.getInstance()`. Bootstrap via
  `HiveAtPersistenceFactory` instead.
- breaking: `AtCommitLogManagerImpl` and `AtAccessLogManagerImpl`
  are deleted (their only purpose was the singleton + per-atSign
  cache; the factory now does both). The orphaned spec interfaces
  `AtCommitLogManager` and `AtAccessLogManager` are removed from
  `at_persistence_spec` — nothing else implemented them.
- refactor: `HiveKeyStoreHelper` is now stateless with static
  methods (`HiveKeyStoreHelper.prepareKey(k)`,
  `HiveKeyStoreHelper.prepareDataForKeystoreOperation(...)`).
  Drop the singleton.
- refactor: `AtCompactionService` no longer carries a singleton;
  construct one with `AtCompactionService()` per job.
- refactor: `HiveAtPersistenceFactory.initialize` no longer routes
  through the legacy singleton-based managers — it constructs the
  per-atSign keystore / commit log / access log / notification
  keystore directly.
- feat: introduce `AtCompactionStrategy` abstract +
  `HiveCompactionStrategy` concrete. Bundle gains nullable
  `commitLogCompactor`, `accessLogCompactor`, `keyStoreCompactor`
  fields, populated based on the new `enableCommitLogCompactor` /
  `enableAccessLogCompactor` / `enableKeyStoreCompactor` config
  toggles. Server defaults all-on; client defaults commit-log-only.
- breaking: `AtCompactionJob` constructor changed from
  `(AtLogType, SecondaryKeyStore)` to
  `(AtCompactionStrategy, [AtCompactionStatsService?])`. The
  scheduler now delegates to the strategy's `compact()` method
  rather than reaching into the log type's keys-to-delete
  primitives directly.
- breaking: removed the deprecated `AtCompactionStrategy` interface
  from `at_persistence_spec` (it was annotated
  `@Deprecated('use CompactionService')`, had a single
  `performCompaction(AtLogType)` method, and was unimplemented).
  The new `AtCompactionStrategy` in
  `at_persistence_secondary_server` is the replacement.
- feat: add `AtPersistenceBundle.clear()` — drops every entry from
  each store while keeping the underlying boxes open. Idempotent
  per-bundle. Cheap test isolation primitive: tests using a
  file-scoped factory can call `bundle.clear()` in `setUp` rather
  than tearing down the factory per test. `at_secondary_server`'s
  test/test_utils.dart documents the recommended setup conventions.
- docs: finalise MIGRATION.md — added a worked-example appendix
  covering at_client_sdk's `LocalSecondary` bootstrap, the
  compaction-job constructor change in `AtClientImpl`, the sync
  helpers in `sync_util.dart`, and the test-file migration shape.
  Cross-repo sweep against at_client_sdk / at_services / at_tools
  found 56 sites — all in at_client_sdk, all covered by the
  existing recipes. Linked canonical example files for every major
  surface (factory bootstrap, slim bundle, replay/iterate, clear,
  AtConfig, compaction wiring).

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




