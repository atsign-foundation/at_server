# Persistence overhaul — 5.0.0 migration guide

`at_persistence_secondary_server` 5.0.0 is a major release that
overhauls how persistence stores are constructed, named, typed, and
wired together. It is a clean break from 4.3.5 — there is no
overlap-version with deprecation shims.

This guide has three sections; read the one(s) you need:

1. **[What changed in
   `at_persistence_secondary_server`](#section-1--what-changed-in-at_persistence_secondary_server)
   **
   — the 5.0.0 (this branch) vs 4.3.5 (trunk) delta, and why.
2. *
   *[What changed in the atServer](#section-2--what-changed-in-at_secondary_server)
   **
   — how `at_secondary_server` was reworked to consume the new
   persistence package.
3. *
   *[Migrating the at_client package](#section-3--migrating-the-at_client-package)
   **
   — a step-by-step guide for moving `at_client` onto 5.0.0 and a
   **commit-log-free** local keystore.

Throughout: the package now ships **two barrels**. Import the
abstract / spec surface from
`package:at_persistence_secondary_server/at_persistence_secondary_server.dart`
and the Hive implementation from
`package:at_persistence_secondary_server/hive.dart`. A future SQLite /
Postgres backend will be a separate package that depends on the spec
barrel only.

---

## Section 1 — What changed in `at_persistence_secondary_server`

5.0.0 vs 4.3.5. The themes below are ordered roughly by blast radius.

### 1.1 Bootstrap is a factory + bundle, not singletons

4.3.5 constructed every store through a process-global singleton:
`SecondaryPersistenceStoreFactory.getInstance()`,
`AtCommitLogManagerImpl.getInstance()`,
`AtAccessLogManagerImpl.getInstance()`, plus a per-atSign
`HivePersistenceManager`. Lifecycle was implicit and ownership
diffuse.

5.0.0 replaces all of it with an injectable factory:

- `AtPersistenceFactory.initialize(atSign, config)` → `AtPersistenceBundle`.
  The factory owns the per-atSign lifecycle: calling `initialize`
  twice for the same atSign returns the **same** bundle;
  `factory.close()` tears everything down.
- `HiveAtPersistenceFactory` is the Hive-backed implementation.
- `AtPersistenceBundle` holds the per-atSign resources: `keyValueStore`
  (core), `accessLog?` and `notificationKeystore?` (optional
  capabilities), plus `clear()` and `close()`.

**Why:** the singleton web made the backend un-swappable and the
lifecycle untestable. A factory that hands back a typed bundle lets
`at_secondary_server` (and any consumer) be wired explicitly, and lets
a future RDBMS backend slot in behind the same abstraction.

Every `*.getInstance()` shim is **removed** — there is no deprecated
bridge.

### 1.2 Hive concretes renamed; abstract interfaces freed

The unprefixed names are now backend-agnostic abstract interfaces; the
Hive implementations carry a `Hive` prefix.

| Abstract interface       | Hive implementation          |
|--------------------------|------------------------------|
| `AtCommitLog`            | `HiveAtCommitLog`            |
| `AtAccessLog`            | `HiveAtAccessLog`            |
| `AtNotificationKeystore` | `HiveAtNotificationKeystore` |
| `AtKeyValueStore`        | `HiveAtKeyValueStore`        |

The `at_persistence_spec` dependency is **dropped**: the interface
types that package used to provide (`AtKeyValueStore`, exceptions, the
`@server` / `@client` annotations, and the new query types listed
below) now live alongside the Hive implementation in this package.
Future backend packages depend on `at_persistence_secondary_server`
for the interfaces they implement.

### 1.3 Keystore type hierarchy collapsed and widened

4.3.5 split the keystore contract across `Keystore` (read-only),
`WritableKeystore`, and `SynchronizableKeyStore`, and named the main
store `SecondaryKeyStore`.

5.0.0:

- `SecondaryKeyStore` → **`AtKeyValueStore`**;
  `HiveSecondaryKeyStore` → **`HiveAtKeyValueStore`**. The bundle field
  `keyStore` → **`keyValueStore`**.
- The three read/write tiers collapse into a single
  `KeyValueStore<K, V>` interface holding the full CRUD + rich surface.
  `AtKeyValueStore<K, V, T>` extends it with the sync-coupled extras:
  the (nullable) `commitLog`, the `putMeta` / `putAll` / `getMeta`
  metadata triplet, and `queryByPath` / `supportsPathQueries`.
- `HiveAtKeyValueStore` is now `AtKeyValueStore<String, AtData, AtMetaData?>`
  — the value type tightened from `AtData?` to non-null `AtData`, so
  `put` / `create` / `putAll` reject a null value at compile time
  instead of crashing on an internal `value!`. `get` still returns
  `Future<AtData?>` (`null` for an absent key).

`KeyValueStore` was **widened with ten new primitives** for at_client
adoption — all additive, none of them break a 4.3.5 caller:

| Primitive                             | Notes                                                          |
|---------------------------------------|----------------------------------------------------------------|
| `exists(key)`                         | async existence check; replaces the removed sync `isKeyExists` |
| `scanKeys(KeyPattern, …)`             | structured filtering + `OrderByKey` ordering + `limit`/`skip`  |
| `getMany(keys)`                       | bulk fetch                                                     |
| `removeMany(keys)`                    | bulk delete                                                    |
| `changes`                             | broadcast `Stream<KeyStoreChange>` of mutations                |
| `transaction(body)`                   | buffered all-or-nothing writes                                 |
| `queryByPath` + `supportsPathQueries` | value-field predicate query (capability-gated)                 |
| `snapshot` + `supportsSnapshots`      | isolated read snapshot (capability-gated)                      |
| `stats()`                             | diagnostic counts                                              |

On Hive the capability flags (`supportsPathQueries`,
`supportsSnapshots`) are `false` and consumers fall back; a future SQL
backend flips them to `true` and the same call site becomes an indexed
query / real MVCC snapshot.

### 1.4 The commit log is nullable, end to end

This is the headline change for client consumers.

- `AtKeyValueStore.commitLog` is nullable. Server keystores hold a
  non-null commit log (every write appends to it for sync); client
  keystores hold `null`.
- `AtPersistenceConfig.enableCommitLog` (default `true`) selects
  which. `serverDefaults` → `true`; `clientDefaults` → `false`. When
  `false`, the factory builds the keystore **commit-log-free** and
  never opens a commit-log box.
- `HiveAtKeyValueStore` honours a `null` commit log throughout:
  `put` / `create` / `putAll` / `putMeta` / `remove` / `removeMany`
  succeed and return `null` (no sequence number), and `compact()` is a
  no-op that yields nothing.
- `AtPersistenceBundle` no longer exposes the commit log directly —
  `bundle.commitLog` is gone; reach it (server-side) as
  `bundle.keyValueStore.commitLog`.

Related commit-log changes:

- **`AtCommitLog.getEntries` retired.** Use
  `iterate({fromCommitId, where})` — a lazy box-walk; the `where`
  closure carries any caller-side filtering (regex, skipDeletesUntil).
- **One-entry-per-atKey by construction.** `CommitLogKeyStore.add()`
  dedups inline, plus a one-time startup dedup migration.
  `CommitLogCompactionService` / `CompactionSortedList` are retired.
- **Migrator-friendly walks:** `replay(CommitEntry)` and
  `iterate(…)` on `AtCommitLog`; `iterate()` on the access log and
  notification keystore.

### 1.5 Model classes decoupled from Hive

`AtData`, `AtMetaData`, `CommitEntry`, `AccessLogEntry` and
`AtNotification` no longer carry Hive's `@HiveType` / `@HiveField`
annotations or `extends HiveObject`. The hand-written `TypeAdapter`s
moved to `lib/src/impl/hive/adapters/` (on-disk wire format
unchanged). The five models are now plain Dart objects — the seam a
future non-Hive backend needs.

### 1.6 Compaction is intrinsic; scheduling left the package

The `Compactable` interface — one method, `Stream<Object> compact(bool dryRun)`
— replaces the whole 4.3.5 strategy machinery (`AtCompactionStrategy`,
`HiveCompactionStrategy`, `AtCompaction`, `AtLogType`,
`AtCompactionConfig`, `AtCompactionStats`, `AtCompactionJob` — all
**deleted**). `AtCommitLog`, `AtAccessLog`, `AtNotificationKeystore`
and `AtKeyValueStore` all implement `Compactable`; `compact(false)`
yields the items removed, `compact(true)` yields what would be removed.

The persistence layer no longer **schedules** anything: the cron /
timer that drives compaction (and the key-expiry sweep) now lives in
`at_secondary_server` — see [Section 2](#section-2--what-changed-in-at_secondary_server).

### 1.7 Async / streaming APIs; `dynamic` removed

- `getKeys`, `getExpiredKeys` and `scanKeys` return
  `Future<Stream<…>>`. The `Future` completes once the backend has
  accepted the request (setup failures — store not open, invalid
  regex — reject eagerly rather than mid-stream); the `Stream` then
  yields results.
- The synchronous `isKeyExists` is **removed** — use async `exists`.
- CRUD methods return `Future<int?>` (commit-log sequence number, or
  `null`) instead of `Future<dynamic>`; `get` is `Future<V?>`. Call
  sites can drop their `as int?` / `as AtData?` / `as Map` casts.
- `AtKeyValueStore.deleteExpiredKeys` drops its `skipCommit`
  parameter — expiry is backend-local maintenance, never sync'd.

### 1.8 `AtConfig` moved out

`AtConfig` (block-list configuration) is no longer in this package; it
moved to `at_secondary_server` (`package:at_secondary/src/config/at_config.dart`).
Client consumers never used it.

---

## Section 2 — What changed in `at_secondary_server`

How the atServer (this branch, 3.14.0) was reworked to consume
`at_persistence_secondary_server` 5.0.0. If you maintain a fork of the
atServer or another full-secondary consumer, this is your checklist.

### 2.1 Bootstrap through the factory

`AtSecondaryServerImpl._initializePersistentInstances` (and `start` /
`stop`) no longer call `*.getInstance()`. They drive a
`HiveAtPersistenceFactory`:

```dart
final factory = HiveAtPersistenceFactory();
final bundle = await factory.initialize(
  atSign,
  HivePersistenceConfig.serverDefaults(
    storagePath: ...,
    commitLogPath: ...,
    accessLogPath: ...,
    notificationStoragePath: ...,
  ),
);
```

`serverDefaults` opts into every capability. The bootstrap then
asserts the optional capabilities are present **once** and binds them
to non-nullable `late` fields, so verb handlers never carry `!`:

```dart
// commitLog is nullable on the keystore; the server always has one.
commitLog = bundle.keyValueStore.commitLog!;
keyValueStore = bundle.keyValueStore;
accessLog = bundle.accessLog!;
notificationKeystore = bundle.notificationKeystore!;
```

See `lib/src/server/at_secondary_impl.dart`.

### 2.2 Singletons removed from `lib/`; dependencies injected

Every `getInstance()` call onto the legacy persistence singletons is
gone from `lib/`. Resources are now passed by constructor:

- Verb handlers that need the commit log and/or access log
  (`from`, `cram`, `lookup`, `pol`, `proxy_lookup`, `config`,
  `sync_progressive`) take `AtCommitLog` / `AtAccessLog` constructor
  parameters. `DefaultVerbHandlerManager` threads them in — its
  constructor now takes `commitLog` and `accessLog` (before the
  trailing `atSign` positional). **External code that constructs
  `DefaultVerbHandlerManager` directly must pass these.**
- `metrics_impl` reads `atServer.commitLog` / `atServer.accessLog` /
  `atServer.secondaryKeyStore`.
- `StatsNotificationService.schedule()` takes its `AtCommitLog`
  parameter rather than fetching it lazily;
  `StatsNotificationService.getInstance()` is gone — the instance is
  constructed and held by `AtSecondaryServerImpl`.
- `SecondaryUtil.saveCookie` takes a `SecondaryKeyStore` parameter.

### 2.3 Verb-handler keystore is strongly typed

`AbstractVerbHandler.keyValueStore` and
`DefaultVerbHandlerManager.keyValueStore` are typed
`AtKeyValueStore<String, AtData, AtMetaData?>` rather than a raw
`AtKeyValueStore`. This surfaced and fixed a set of latent nullability
gaps the raw type had masked — unchecked `get()` results bound to a
non-null `AtData`, `String?` keys passed into `get` / `remove` /
`put`, and a `bool?` metadata field (`isCascade`) used directly as a
condition.

### 2.4 `AtConfig` moved in

`AtConfig` (block-list config) moved from `at_persistence_secondary_server`
to `package:at_secondary/src/config/at_config.dart`. It is now
fully backend-agnostic: the constructor takes a `SecondaryKeyStore`
(not an `AtCommitLog`), reads/writes go through the abstract keystore,
and writes pass `skipCommit: true` so block-list state no longer bumps
the local `commitId`. Construction signature is `AtConfig(keyStore, atSign)`;
`from_verb_handler` and `config_verb_handler` updated accordingly.

### 2.5 Compaction + expiry scheduling moved into the atServer

Because the persistence layer no longer schedules anything, the
atServer now owns:

- **Compaction** — three `Timer.periodic` ticks (commit log, access
  log, notification keystore) with overlap guards, each calling
  `compact(false)` on the resource. `AtCompactionStatsService.record()`
  takes primitives (`label`, `start`, `compactedCount`, `duration`).
- **Key-expiry sweep** — the cron that calls
  `keyValueStore.deleteExpiredKeys()` moved out of the persistence
  package into the atServer.
- The compactor `enable*` flags moved from `AtPersistenceConfig` to
  `AtSecondaryConfig` (`enableKeyStoreCompactor` →
  `enableNotificationCompactor`, matching the resource it gates).

### 2.6 Sync verb handler tracks the `iterate` API

`SyncProgressiveVerbHandler` and `LatestCommitEntryOfEachKey` were
updated to consume `AtCommitLog.iterate(…)` instead of the retired
`getEntries`. This also fixed an **empty-response wedge**: when every
entry in a requested range failed `isAuthorized`, the handler used to
return `[]`, leaving the client unable to advance its `from`
watermark. The `iterate(where:)` scan is unbounded, so the client
always sees forward progress. No wire-format change.

### 2.7 Tests

`test/test_utils.dart`'s `verbTestsSetUp` / `verbTestsTearDown` drive a
`HiveAtPersistenceFactory` instead of the per-singleton `getInstance()`
paths. The `atServer.<field> = …` injection seam is preserved.

---

## Section 3 — Migrating the at_client package

This section is a step-by-step guide for moving `at_client` from
`at_persistence_secondary_server: ^4.3.5` to `^5.0.0`, **and** onto a
commit-log-free local keystore. Call-site references are against the
`gkc-fewer-connections` branch of `at_client_sdk`.

### 3.0 The shape of the migration

There are two distinct bodies of work:

- **A — Mechanical churn.** Factory + bundle bootstrap, class renames,
  removed singletons, async/streaming APIs. Required, and largely
  recipe-driven (§3.2–§3.6).
- **B — The commit-log-free transition.** at_client's local keystore
  becomes commit-log-free (`HivePersistenceConfig.clientDefaults`).
  Everything in at_client that still reads or writes the commit log
  must be removed or re-pointed (§3.7). This is the headline work
  item — the sync engine is the bulk of it.

Good news from the current code: at_client's **push** path already
drains `LocalSecondary`'s `AtSyncQueue`, not the commit log
(`sync_util.dart` says so in its own header comment). The commit log
is no longer at_client's source of truth for *what to push* — it
survives only as (a) a commitId high-water mark, (b) the substrate for
client-side commit-log compaction, and (c) back-write bookkeeping
after each push/pull. Section B is therefore about removing those
three residual uses, not rewriting the whole sync engine.

### 3.1 Dependency bump

`packages/at_client/pubspec.yaml`:

```yaml
dependencies:
  at_persistence_secondary_server: ^5.0.0
```

`at_client` is the only package that depends on it directly. Run
`dart pub get`, then `dart analyze` — the error wall is the migration
to-do list.

### 3.2 Bootstrap: replace the singleton dance with the factory

`StorageManager._initStorage` is the heart of the mechanical
migration. Today (`storage_manager.dart`) it runs a nine-step dance
across three singletons — get commit log, get `HivePersistenceManager`,
`init`, get keystore, wire commit log, get keystore manager, `initialize`,
assign. Replace the whole body:

```dart
// Before (4.3.5):
var atCommitLog = await AtCommitLogManagerImpl.getInstance().getCommitLog(
    currentAtSign, commitLogPath: commitLogPath, enableCommitId: false);
var hivePersistenceManager = SecondaryPersistenceStoreFactory.getInstance()
    .getSecondaryPersistenceStore(currentAtSign)!
    .getHivePersistenceManager()!;
await hivePersistenceManager.init(storagePath);
var hiveKeyStore = SecondaryPersistenceStoreFactory.getInstance()
    .getSecondaryPersistenceStore(currentAtSign)!
    .getSecondaryKeyStore()!;
hiveKeyStore.commitLog = atCommitLog;
var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
    .getSecondaryPersistenceStore(currentAtSign)!
    .getSecondaryKeyStoreManager()!;
await hiveKeyStore.initialize();
keyStoreManager.keyStore = hiveKeyStore;

// After (5.0.0): one factory call, commit-log-free.
final factory = HiveAtPersistenceFactory();
final bundle = await factory.initialize(
  currentAtSign,
  HivePersistenceConfig.clientDefaults(storagePath: storagePath),
);
```

Notes:

- `clientDefaults` takes only `storagePath` — there is no
  `commitLogPath` and no `enableCommitId`. The keystore it produces is
  commit-log-free (`bundle.keyValueStore.commitLog == null`), and the
  access log / notification keystore are off.
- `HivePersistenceManager` and `SecondaryKeyStoreManager` no longer
  exist — the factory owns box-opening and lifecycle.
- The factory + bundle must be **owned** by `AtClientImpl` (the
  natural lifecycle owner), with a `persistenceBundle` getter on the
  `AtClient` interface so `LocalSecondary`, `StorageManager` and the
  sync engine can reach `bundle.keyValueStore`. Tear down via
  `factory.close()` on the matching close path.

`LocalSecondary`'s constructor does the same singleton lookup as a
fallback (`local_secondary.dart`) — replace it with
`keyStore ??= _atClient.persistenceBundle.keyValueStore`.

### 3.3 Class renames and removed singletons

| Removed / renamed (4.3.5)                              | 5.0.0 replacement                            |
|--------------------------------------------------------|----------------------------------------------|
| `SecondaryPersistenceStoreFactory.getInstance()`       | `HiveAtPersistenceFactory()` + the `bundle`  |
| `AtCommitLogManagerImpl.getInstance().getCommitLog(…)` | `bundle.keyValueStore.commitLog` (or `null`) |
| `AtAccessLogManagerImpl` / `AtAccessLogManager`        | server-only; not used by at_client           |
| `HivePersistenceManager`                               | gone — factory owns box-opening              |
| `SecondaryKeyStoreManager`                             | gone — factory owns the keystore             |
| `SecondaryKeyStore` (type)                             | `AtKeyValueStore`                            |
| `HiveKeystore` (type)                                  | `HiveAtKeyValueStore`                        |
| `isKeyExists(key)`                                     | `await exists(key)`                          |
| `AtCommitLog.getEntries(…)`                            | `AtCommitLog.iterate({fromCommitId, where})` |

`LocalSecondary.keyStore` is typed `SecondaryKeyStore?` — retype to
`AtKeyValueStore<String, AtData, AtMetaData?>?`.

### 3.4 Drop the private `hive_keystore.dart` import

`local_secondary.dart` reaches into the package internals:

```dart
// ignore: implementation_imports
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore.dart';
```

— used for `is HiveKeystore` guards and `getExpiredKeys()` /
`getExpiryKeysCache()` (an `@visibleForTesting` member). The path
itself is dead (the file moved to `src/impl/hive/hive_at_keyvalue_store.dart`),
but more importantly the **reason** for the private import is gone:
`getExpiredKeys()` is now a public `KeyValueStore` method, and `exists`
/ `scanKeys` / `stats` cover the structured access at_client was
reaching for. Replace the `is HiveKeystore` guards + private calls
with the public abstract API; delete the `implementation_imports`
ignore and the file-level `invalid_use_of_visible_for_testing_member`
ignore.

### 3.5 Async / streaming API changes

- `getKeys({regex})` and `getExpiredKeys()` now return
  `Future<Stream<String>>` — `await` the future, then consume the
  stream (`await (await keyStore.getKeys()).toList()`).
- `isKeyExists` is removed — `await keyStore.exists(key)`.
- CRUD methods return `Future<int?>`; on a commit-log-free keystore
  the result is always `null`. Any at_client code that treats the
  return as a commit sequence number (or `as int`) must stop doing so.

### 3.6 Compaction is deleted, not migrated

`AtCompactionJob`, `AtCompactionConfig`, `AtCompactionService` and
`AtCompactionStats` are **deleted** in 5.0.0. at_client's
`at_commit_log_compaction.dart` (`AtClientCommitLogCompaction`), the
`AtClientImpl.startCompactionJob` path, and the `MockAtCompactionJob`
test double therefore do not compile.

In a commit-log-free at_client there is **nothing to compact** — there
is no commit log. Delete `at_commit_log_compaction.dart`, the
`startCompactionJob` / `stopCompactionJob` surface on `AtClientImpl`,
and the related tests outright. (If at_client ever needs to shed
keystore entries, that is a keystore concern — `AtKeyValueStore`
implements `Compactable` — not a separate job class.)

### 3.7 The commit-log-free transition (work item B)

Everything below currently touches the commit log and must be removed
or re-pointed. The cursors at_client's sync service actually runs on
(`_highestPushedCommitId`, `lastReceivedServerCommitId`, the
`AtSyncQueue`) do **not** depend on the commit log — these residual
uses are bookkeeping around them.

**`sync_util.dart`** — the file's own header already marks the
read-side scans (`getChangesSinceLastCommit`, `getEntry`, `isInSync`,
`removeCommitEntry`) `@Deprecated` with no caller; delete them. The
methods still live are all commit-log back-write / lookup:

| Method                 | Current role                                               | Commit-log-free disposition               |
|------------------------|------------------------------------------------------------|-------------------------------------------|
| `getCommitEntry`       | `_pullToLocal` finds the entry `executeVerb` appended      | remove — no entries exist                 |
| `updateCommitEntry`    | push + pull stamp the server commitId onto the entry       | remove — nothing to stamp                 |
| `getLastSyncedEntry`   | commitId high-water mark for downstream / functional tests | replace the high-water source (see below) |
| `getLatestCommitEntry` | `_pushFromSyncQueue` finds the entry to stamp              | remove                                    |

**`sync_service_impl.dart`** — drop the
`AtCommitLogManagerImpl.getInstance().getCommitLog(atSign)` lookup and
the `commitLogSeqNum` plumbing on queue entries. The push decision is
already `AtSyncQueue`-driven; what remains is removing the commitId
back-writes that follow a successful push/pull.

**`local_secondary.dart`** — `_removeOrphanedCommitLogEntry` (and its
`commitLogKeyStore.remove`) has no meaning without a commit log;
delete it.

**The high-water mark.** at_client's sync correctness needs a "what
have I sync'd up to" marker. Today that is the commitId stamped on
commit-log entries; `getLastSyncedEntry` reads it back. Commit-log-free,
this marker must live somewhere else — a dedicated key in the keystore,
or in-memory state owned by the sync service. **Designing that marker
is at_client's call and is out of scope for this guide** — but it is
the one piece of section B that is a genuine design decision rather
than a deletion. Every other commit-log use above is removed outright.

### 3.8 Tests

The sweep is wide — ~19 `at_client/test/` files plus four functional
tests import the package. Patterns:

- Test fixtures that build a keystore via the singleton dance →
  factory + `HivePersistenceConfig.clientDefaults`. Use a file-scoped
  factory with `tearDownAll` close and per-test `bundle.clear()` for
  isolation.
- `sync_new_test.dart` casts to `HiveKeystore` and asserts on commit
  entries (`getChanges`, `getEntry`, `lastCommittedSequenceNumber`) in
  40+ places — these assert against a substrate that no longer exists.
  They must be rewritten against the new sync-state model from §3.7,
  or retired.
- `commit_log_compaction_test.dart` (end2end + functional) tests a
  feature that is being deleted — retire it.
- Run with `dart test --concurrency=1` (atsign repos share Hive box
  state by atSign across parallel runs).

### 3.9 Verification

The migration is done when:

1. `git grep -nE 'getInstance\(\)|SecondaryKeyStoreManager|HivePersistenceManager|AtCompactionJob|implementation_imports' -- packages/at_client/lib`
   returns nothing.
2. No `lib/` reference to `commitLog`, `CommitEntry`, `getChanges`,
   `commitLogKeyStore` survives outside the new sync-state model.
3. `dart analyze` is clean across `at_client_sdk`.
4. `dart test --concurrency=1` passes in every package.
5. The functional test pack passes (`tests/at_functional_test/runLocal.sh`).
6. Smoke test: a write on one client syncs to the server and pulls to
   a second client — with `bundle.keyValueStore.commitLog == null` on
   both.
