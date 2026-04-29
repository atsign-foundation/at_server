# Migrating from 4.3.5 to 5.0.0

`at_persistence_secondary_server` 5.0.0 is a major release that
overhauls how persistence stores are constructed, named, and
wired together. There is no overlap-version with deprecation
shims — consumers move directly from 4.3.5 to 5.0.0.

This guide is split into two tracks because the impact differs
significantly between server-side consumers (such as
`at_secondary_server`) and client-side consumers (such as
`at_client_sdk`).

- [TL;DR](#tldr)
- [Server track](#server-track)
- [Client track](#client-track)
- [Class renames](#class-renames)
- [Constructor changes](#constructor-changes)
- [Removed APIs](#removed-apis)
- [New APIs](#new-apis)

---

## TL;DR

- **Bootstrap is now via a factory** (`HiveAtPersistenceFactory`),
  not the various `*.getInstance()` singletons. The factory hands
  back an `AtPersistenceBundle` that holds `keyStore`,
  `commitLog`, optionally `accessLog` / `notificationKeystore` /
  compactors, and lifecycle hooks.
- **Class renames.** The Hive-backed concretes carry a `Hive`
  prefix; the unprefixed names become abstract interfaces.
- **`AtConfig` moved out** of `at_persistence_secondary_server`
  into `package:at_secondary/src/config/at_config.dart`. Server-only
  concern; client consumers were never affected.
- **Deprecated `getInstance()` shims removed** outright. Every
  call site moves to the factory.
- **Constructor signature changes** for `AtCompactionJob`,
  `AtCompactionStatsServiceImpl`, and `AtConfig` (see below).

---

## Server track

For consumers that run a full atSecondary (this repo's
`at_secondary_server`, plus any downstream that runs its own
secondary). These consumers use the **full** persistence surface:
keystore, commit log, access log, notification keystore as
storage, all three compactors, key-expire scheduler, and
`AtConfig` block-list.

The bulk of the migration is mechanical — Phase 1 already moved
this repo onto the factory pattern. External servers follow the
same recipe.

(Detailed server-track recipes will be filled in as Phase 2
commits land.)

## Client track

For consumers that run a local-secondary cache (e.g.
`at_client_sdk` and downstream mobile/desktop apps). These
consumers use a **subset** of the persistence surface: keystore,
commit log, key-expire scheduler, and commit-log compactor.

What does **not** affect the client:

- `AtConfig` — server-only block-list config; client never
  imported it.
- `AtAccessLog` — server-only audit trail.
- `AtNotificationKeystore` (as a storage class) — only the
  `NotificationStatus` enum is consumed by the client.
- `AtCompactionStrategy` for access log / keystore — client only
  compacts the commit log.
- The bundle escape hatches (`secondaryPersistenceStore`,
  `hivePersistenceManager` getters) that Phase 1c removed — the
  client never used them.

(Detailed client-track recipes will be filled in as Phase 2
commits land.)

---

## Class renames

Phase 2 Commit 1 renames the Hive-backed concretes so the
unprefixed names can be reused as the abstract interfaces
introduced in Commit 2.

| Old name (concrete) | New name (concrete) | Notes |
| --- | --- | --- |
| `AtCommitLog` | `HiveAtCommitLog` | Server-flavour Hive impl. The unprefixed `AtCommitLog` becomes the abstract interface in Commit 2. |
| `ClientAtCommitLog` | `HiveClientAtCommitLog` | Client-flavour Hive impl (extends `HiveAtCommitLog`). |
| `AtAccessLog` | `HiveAtAccessLog` | Hive impl. Unprefixed name will become abstract in Commit 2. |
| `AtNotificationKeystore` | `HiveAtNotificationKeystore` | Hive impl of the notification queue. Unprefixed name will become abstract in Commit 2. |
| `HiveKeystore` | `HiveSecondaryKeyStore` | Hive impl of the abstract `SecondaryKeyStore` (which already existed in `at_persistence_spec`). |

The abstract `BaseAtCommitLog` (existing parent of the renamed
`HiveAtCommitLog`) stays in place for now — Commit 2 will rename
it to `AtCommitLog` and it will become the canonical abstract
interface.

**No deprecated re-exports under the old names.** 5.0.0 is a
clean major break; downstream code updates to the new names.

### Find-and-replace recipes

These cover the in-repo migration; downstream consumers can use
the same patterns.

```bash
# AtCommitLog → HiveAtCommitLog (whole-word, won't touch BaseAtCommitLog,
# ClientAtCommitLog, or AtCommitLogManager)
perl -i -pe 's/\bClientAtCommitLog\b/HiveClientAtCommitLog/g; s/\bAtCommitLog\b/HiveAtCommitLog/g' \
    $(find . -name '*.dart')

# AtAccessLog → HiveAtAccessLog (won't touch AtAccessLogManager)
perl -i -pe 's/\bAtAccessLog\b/HiveAtAccessLog/g' $(find . -name '*.dart')

# AtNotificationKeystore → HiveAtNotificationKeystore
perl -i -pe 's/\bAtNotificationKeystore\b/HiveAtNotificationKeystore/g' \
    $(find . -name '*.dart')

# HiveKeystore → HiveSecondaryKeyStore (won't touch HiveKeyStoreHelper —
# different spelling)
perl -i -pe 's/\bHiveKeystore\b/HiveSecondaryKeyStore/g' $(find . -name '*.dart')
```

### Import path changes

| Old path | New path |
| --- | --- |
| `src/log/commitlog/at_commit_log.dart` | `src/log/commitlog/hive_at_commit_log.dart` |
| `src/log/accesslog/at_access_log.dart` | `src/log/accesslog/hive_at_access_log.dart` |
| `src/notification/at_notification_keystore.dart` | `src/notification/hive_at_notification_keystore.dart` |
| `src/keystore/hive_keystore.dart` | `src/keystore/hive_secondary_keystore.dart` |

The library export
(`package:at_persistence_secondary_server/at_persistence_secondary_server.dart`)
re-exports the renamed files at the new paths; consumers that
import via the package URL only need the class-name updates.

---

## Bundle shape: slim core + optional capabilities

`AtPersistenceBundle` is now split into a *core* (always present)
plus *optional capabilities* (nullable, populated based on config):

**Core (non-nullable):**

- `String atSign`
- `AtPersistenceBackendId backendId`
- `SecondaryKeyStore keyStore`
- `AtCommitLog commitLog`
- `void scheduleKeyExpireTask(...)`
- `Future<void> close()`

**Optional capabilities (nullable):**

- `AtAccessLog? accessLog`
- `AtNotificationKeystore? notificationKeystore`

The optional capabilities are populated based on `enable*` toggles
on the config. Two factory constructors cover the common shapes:

```dart
// Server-shaped: opts into all capabilities (matches 4.3.5 behaviour
// for any consumer that ran a full atSecondary).
HivePersistenceConfig.serverDefaults(
  storagePath: ...,
  commitLogPath: ...,
  accessLogPath: ...,
  notificationStoragePath: ...,
);

// Client-shaped: opts into core only (keystore + commit log +
// scheduler). Suitable for at_client_sdk's local-secondary cache.
HivePersistenceConfig.clientDefaults(
  storagePath: ...,
  commitLogPath: ...,
);
```

The bundle's `accessLog` and `notificationKeystore` getters are
nullable. **Server callers that previously read them as non-null
need to bind via `!`** after asserting the capability is present.
Recommended pattern, used in this repo's `AtSecondaryServerImpl`:

```dart
final bundle = await persistenceFactory.initialize(atSign, config);

// Asserts that bundle.accessLog and bundle.notificationKeystore are
// non-null; throws StateError if the config disabled them.
_assertServerCapabilities(bundle);

late AtAccessLog accessLog = bundle.accessLog!;
late AtNotificationKeystore notificationKeystore =
    bundle.notificationKeystore!;
```

This keeps `!` litter out of every verb handler — the unwrapping
happens once at bootstrap.

## New abstract interfaces

The Hive concretes (renamed in Commit 1) now `implements` matching
abstract interfaces under the unprefixed names:

| Abstract | Hive concrete |
| --- | --- |
| `AtCommitLog` | `HiveAtCommitLog` |
| `AtAccessLog` | `HiveAtAccessLog` |
| `AtNotificationKeystore` | `HiveAtNotificationKeystore` |
| `SecondaryKeyStore` (already existed in `at_persistence_spec`) | `HiveSecondaryKeyStore` |

The bundle's fields are typed at the abstracts. Code that holds
a `HiveAtCommitLog` (or other concrete) typed local variable from
the bundle needs to relax the type to the abstract. Tests that
declare `Mock implements AtCommitLog` are unaffected — the abstract
name is the same as the type they were already mocking against.

The legacy `BaseAtCommitLog` abstract has been replaced by
`AtCommitLog` (which now lives at
`src/log/commitlog/at_commit_log.dart`). Direct subclasses of
`BaseAtCommitLog` (none found in the atsign repos) need to extend
`AtCommitLog` instead.

## Migration / iteration primitives (additive)

Two new methods land on the abstract surfaces, in preparation for
Phase 3's persistence-backend migrator:

- `Future<void> AtCommitLog.replay(CommitEntry entry)` — write an
  existing commit entry under its supplied `commitId` without
  firing change-event listeners. Idempotent on
  `(commitId, atKey, op)`. Throws `ArgumentError` if `entry.commitId`
  is null.
- `Stream<CommitEntry> AtCommitLog.iterate({int? fromCommitId})` —
  iterate every commit entry in `commitId` order, optionally
  starting from `fromCommitId`.
- `Stream<AccessLogEntry> AtAccessLog.iterate()` — every access-log
  entry, in insertion order.
- `Stream<AtNotification> AtNotificationKeystore.iterate()` — every
  pending notification.

Most consumers won't call these directly; they exist to let a Phase
3 backend migrator move data between any two backends without
backend-specific casts.

## Constructor changes

- `AtCompactionJob(AtLogType logType, SecondaryPersistenceStore store)` →
  `AtCompactionJob(AtLogType logType, SecondaryKeyStore keyStore)`.
  (Phase 1c.)
- `AtCompactionStatsServiceImpl(AtCompaction, SecondaryPersistenceStore)` →
  `(AtCompaction, SecondaryKeyStore)`. (Phase 1c.)
- `AtConfig(AtCommitLog, atSign)` →
  `AtConfig(SecondaryKeyStore, atSign)` AND moved to
  `package:at_secondary/src/config/at_config.dart`. (Phase 1b;
  server-track only.)

## Removed APIs

The deprecated `getInstance()` shims that 4.x exposed are gone in
5.0.0. Bootstrap via the factory pattern instead.

| Removed | Replacement |
| --- | --- |
| `SecondaryPersistenceStoreFactory.getInstance()` | `HiveAtPersistenceFactory()` and the resulting `bundle` |
| `AtCommitLogManagerImpl.getInstance().getCommitLog(atSign)` | `bundle.commitLog` |
| `AtAccessLogManagerImpl.getInstance().getAccessLog(atSign)` | `bundle.accessLog` (server-track only) |
| `AtCompactionService.getInstance()` | `AtCompactionService()` (per-job) |
| `HiveKeyStoreHelper.getInstance().prepareKey(k)` | `HiveKeyStoreHelper.prepareKey(k)` (now static) |
| `HiveKeyStoreHelper.getInstance().prepareDataForKeystoreOperation(...)` | `HiveKeyStoreHelper.prepareDataForKeystoreOperation(...)` (now static) |

Removed alongside:

- `AtCommitLogManagerImpl` class (its only purpose was the
  singleton + per-atSign cache, both now provided by
  `HiveAtPersistenceFactory`).
- `AtAccessLogManagerImpl` class (same).
- `AtCommitLogManager` and `AtAccessLogManager` abstract
  interfaces in `at_persistence_spec` (orphaned by the impl
  deletion; nothing else implemented them).
- The `clear()` lifecycle methods that were added in 4.x to
  let `HiveAtPersistenceFactory` reset the deprecated singletons —
  no longer needed.

Server-track callers also lose:

- `StatsNotificationService.getInstance()` (in `at_secondary_server`).
  The class is now constructed and held by `AtSecondaryServerImpl`
  as `statsNotificationService`. Tests that previously mocked the
  singleton continue to work via the same `MockStatsNotificationService`
  pattern; their construction now happens via `MockStatsNotificationService()`
  directly, no `getInstance` call.

### Bootstrap recipe (server)

Old (4.3.5):

```dart
final commitLog = (await AtCommitLogManagerImpl.getInstance()
    .getCommitLog(atSign, commitLogPath: commitLogPath))!;
final accessLog = (await AtAccessLogManagerImpl.getInstance()
    .getAccessLog(atSign, accessLogPath: accessLogPath))!;
final store = SecondaryPersistenceStoreFactory.getInstance()
    .getSecondaryPersistenceStore(atSign)!;
await store.getHivePersistenceManager()!.init(storagePath);
final keyStore = store.getSecondaryKeyStore()!;
keyStore.commitLog = commitLog;
await keyStore.initialize();
```

New (5.0.0):

```dart
final factory = HiveAtPersistenceFactory();
final bundle = await factory.initialize(
  atSign,
  HivePersistenceConfig.serverDefaults(
    storagePath: storagePath,
    commitLogPath: commitLogPath,
    accessLogPath: accessLogPath,
    notificationStoragePath: notificationStoragePath,
  ),
);
// Use bundle.keyStore, bundle.commitLog, bundle.accessLog!,
// bundle.notificationKeystore!, bundle.scheduleKeyExpireTask(...).
// `factory.close()` tears everything down.
```

### Bootstrap recipe (client)

Old (4.3.5) — the `at_client_sdk` flavour:

```dart
final commitLog = (await AtCommitLogManagerImpl.getInstance()
    .getCommitLog(atSign,
        commitLogPath: commitLogPath, enableCommitId: false))!;
final store = SecondaryPersistenceStoreFactory.getInstance()
    .getSecondaryPersistenceStore(atSign)!;
await store.getHivePersistenceManager()!.init(storagePath);
final keyStore = store.getSecondaryKeyStore()!;
keyStore.commitLog = commitLog;
await keyStore.initialize();
```

New (5.0.0):

```dart
final factory = HiveAtPersistenceFactory();
final bundle = await factory.initialize(
  atSign,
  HivePersistenceConfig.clientDefaults(
    storagePath: storagePath,
    commitLogPath: commitLogPath,
  ),
);
// Use bundle.keyStore, bundle.commitLog, bundle.scheduleKeyExpireTask(...).
// bundle.accessLog and bundle.notificationKeystore are null on
// the client config — they were never used by the client anyway.
```

## New APIs

- `AtPersistenceFactory` / `AtPersistenceBundle` — factory-based
  bootstrap (Phase 1).
- `HiveAtPersistenceFactory` / `HiveAtPersistenceBundle` — Hive
  concrete (Phase 1).
- `HivePersistenceConfig.serverDefaults(...)` /
  `HivePersistenceConfig.clientDefaults(...)` — opinionated config
  factories for the two common shapes (this commit).
- `AtCommitLog.replay(CommitEntry)`,
  `AtCommitLog.iterate({int? fromCommitId})`,
  `AtAccessLog.iterate()`,
  `AtNotificationKeystore.iterate()` — migration / iteration
  primitives (this commit).
