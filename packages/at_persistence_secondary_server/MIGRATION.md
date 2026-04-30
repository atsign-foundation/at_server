# Migrating from 4.3.5 to 5.0.0

`at_persistence_secondary_server` 5.0.0 is a major release that
overhauls how persistence stores are constructed, named, and
wired together. There is no overlap-version with deprecation
shims — consumers move directly from 4.3.5 to 5.0.0.

This guide is split into two tracks because the impact differs
significantly between server-side consumers (such as
`at_secondary_server`) and client-side consumers (such as
`at_client_sdk`).

**If you are migrating `at_client_sdk`, read in this order:**

1. [TL;DR](#tldr) — 1-minute overview of what changed.
2. [What NOT to worry about (client track)](#client-track-what-not-to-worry-about)
   — quick wins by elimination.
3. [Step-by-step playbook (at_client_sdk)](#step-by-step-playbook-at_client_sdk)
   — opinionated order of operations.
4. The reference sections below as needed when you hit a specific
   call site.
5. [Verification: how to know you're done](#verification-how-to-know-youre-done).

**If you are migrating a server-side consumer, read:**

1. [TL;DR](#tldr).
2. [Server-track migration](#server-track-migration).
3. Reference sections as needed.
4. [Verification](#verification-how-to-know-youre-done).

---

## Table of contents

- [TL;DR](#tldr)
- [Pubspec dependency bump](#pubspec-dependency-bump)
- [What NOT to worry about (client track)](#client-track-what-not-to-worry-about)
- [Step-by-step playbook (at_client_sdk)](#step-by-step-playbook-at_client_sdk)
- [Server-track migration](#server-track-migration)
- [Class renames](#class-renames)
- [Bundle shape: slim core + optional capabilities](#bundle-shape-slim-core--optional-capabilities)
- [New abstract interfaces](#new-abstract-interfaces)
- [Migration / iteration primitives (additive)](#migration--iteration-primitives-additive)
- [Constructor changes](#constructor-changes)
- [Removed APIs](#removed-apis)
- [Compaction](#compaction)
- [New APIs](#new-apis)
- [Test patterns](#test-patterns)
- [Worked example: at_client_sdk's `LocalSecondary` and sync engine](#worked-example-at_client_sdks-localsecondary-and-sync-engine)
- [Canonical example files](#canonical-example-files)
- [Verification: how to know you're done](#verification-how-to-know-youre-done)

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
  `AtCompactionStatsServiceImpl`, and `AtConfig` (see
  [Constructor changes](#constructor-changes) below).

---

## Pubspec dependency bump

In your downstream package's `pubspec.yaml`:

```yaml
dependencies:
  at_persistence_secondary_server: ^5.0.0
```

After bumping, run `dart pub get` (or `flutter pub get`) to
refresh `pubspec.lock`. The first `dart analyze` after the bump
will surface every breaking-change call site at once — work
through them using the playbook and reference sections below.

---

## Client track: what NOT to worry about

A lot of the 5.0.0 surface area is server-only. As an
`at_client_sdk` (or downstream client app) maintainer you can
**ignore** these entirely:

- **`AtConfig`** — server-only block-list config; client never
  imported it. The fact that it moved from
  `at_persistence_secondary_server` to `at_secondary` is invisible
  to clients.
- **`AtAccessLog`** — server-only audit trail. No client code
  ever wrote to it.
- **`AtNotificationKeystore`** (as a storage class) — server
  uses it as a queue; client doesn't. The
  `NotificationStatus` enum (a model type, not the storage class)
  IS still used by clients and continues to be exported under
  the same name from
  `package:at_persistence_secondary_server/at_persistence_secondary_server.dart`.
  No change needed there.
- **`AtCompactionStrategy` for access log / keystore** — clients
  only compact the commit log. The other two compactor fields on
  the bundle are `null` under `clientDefaults`.
- **Server-side `StatsNotificationService`** — lives in
  `at_secondary`, not `at_persistence_secondary_server`. Clients
  never imported it.
- **Bundle escape hatches** (`secondaryPersistenceStore`,
  `hivePersistenceManager` getters) — Phase 1c removed them; the
  client never used them.
- **`AtCommitLogManager` / `AtAccessLogManager`** abstract
  interfaces in `at_persistence_spec` — both were removed (they
  were paired with the deleted impl classes), but `at_client_sdk`
  used the impl-side getInstance shims, not the spec-side
  interfaces. So this removal is invisible.

If you find yourself touching anything on this list during the
migration, you're probably on the wrong track. Stop and re-read
the playbook below.

---

## Step-by-step playbook (at_client_sdk)

This is the recommended order. Each step keeps the codebase in a
buildable state — you can stop and run `dart analyze` after every
step.

### Step 1 — Bump the dep + run analyze

Update `pubspec.yaml`:

```yaml
dependencies:
  at_persistence_secondary_server: ^5.0.0
```

Run `dart pub get`, then `dart analyze`. Expect a wall of errors;
that's the migration surface. The errors are the to-do list.

### Step 2 — Class renames (mechanical)

Run the find-and-replace recipes from the [Class renames](#class-renames)
section against `lib/` and `test/`:

```bash
perl -i -pe 's/\bClientAtCommitLog\b/HiveClientAtCommitLog/g; s/\bAtCommitLog\b/HiveAtCommitLog/g' \
    $(find lib test -name '*.dart')
perl -i -pe 's/\bAtAccessLog\b/HiveAtAccessLog/g' $(find lib test -name '*.dart')
perl -i -pe 's/\bAtNotificationKeystore\b/HiveAtNotificationKeystore/g' \
    $(find lib test -name '*.dart')
perl -i -pe 's/\bHiveKeystore\b/HiveSecondaryKeyStore/g' $(find lib test -name '*.dart')
```

**Important:** the `\b` boundaries protect siblings —
`BaseAtCommitLog`, `AtCommitLogManager`, `HiveKeyStoreHelper`
will NOT be matched. If your codebase has subtypes of
`BaseAtCommitLog`, those are now `extends AtCommitLog` instead;
adjust by hand.

After Step 2, mocks like `MockAtCommitLog extends Mock implements
AtCommitLog` continue to work — the abstract `AtCommitLog` is the
type they were already mocking against, just abstract now instead
of concrete.

### Step 3 — Add a `persistenceBundle` getter on `AtClient`

The factory pattern owns the bundle's lifecycle. The natural
owner on the client side is `AtClientImpl`. Add a field and a
getter:

```dart
// In AtClient (interface):
AtPersistenceBundle get persistenceBundle;

// In AtClientImpl:
late final HiveAtPersistenceFactory _persistenceFactory;
late final AtPersistenceBundle _persistenceBundle;

@override
AtPersistenceBundle get persistenceBundle => _persistenceBundle;
```

Initialise in `AtClientImpl`'s init/start path (wherever Hive is
currently being opened):

```dart
_persistenceFactory = HiveAtPersistenceFactory();
_persistenceBundle = await _persistenceFactory.initialize(
  _atSign,
  HivePersistenceConfig.clientDefaults(
    storagePath: <existing storage path>,
    commitLogPath: <existing commit log path>,
  ),
);
```

`clientDefaults` sets `enableCommitId: false` internally — the
client commit log uses commitIds assigned by the server during
sync, not auto-incremented locally. **Don't override this.**

Tear down in the matching close path:

```dart
await _persistenceFactory.close();
```

### Step 4 — Migrate the lib/ call sites

Reference: [Removed APIs](#removed-apis) table.

The four files in `at_client/lib/src/` that hold call sites:

| File                                     | Pattern                                                                                                                                                                       | Replacement                                                                                             |
|------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------|
| `client/local_secondary.dart`            | `SecondaryPersistenceStoreFactory.getInstance().getSecondaryPersistenceStore(_atClient.getCurrentAtSign())!.getSecondaryKeyStore()`                                           | `_atClient.persistenceBundle.keyStore`                                                                  |
| `client/at_client_impl.dart`             | `AtCompactionJob((await AtCommitLogManagerImpl.getInstance().getCommitLog(_atSign))!, SecondaryPersistenceStoreFactory.getInstance().getSecondaryPersistenceStore(_atSign)!)` | `AtCompactionJob(persistenceBundle.commitLogCompactor!)`                                                |
| `manager/storage_manager.dart` (4 sites) | `SecondaryPersistenceStoreFactory.getInstance()...` chains                                                                                                                    | `_atClient.persistenceBundle.<X>` (keystore, commitLog, scheduleKeyExpireTask)                          |
| `manager/preference_manager.dart`        | Same                                                                                                                                                                          | Same                                                                                                    |
| `util/sync_util.dart` (7 sites)          | `await AtCommitLogManagerImpl.getInstance().getCommitLog(atSign)`                                                                                                             | `_atClient.persistenceBundle.commitLog` (helper takes `AtClient` or `AtPersistenceBundle` by parameter) |

After this step, `git grep -nE 'getInstance' at_client/lib/`
should return zero hits for the removed singletons (the only
allowed `getInstance` left is `AtClientImpl.getInstance()` if it
exists).

### Step 5 — Migrate the test files

The ~30 test sites can be migrated in batches. The recommended
pattern:

```dart
// At top of file:
late HiveAtPersistenceFactory testFactory;
late AtPersistenceBundle testBundle;

// In the file's setUpFunc (or equivalent):
testFactory = HiveAtPersistenceFactory();
testBundle = await testFactory.initialize(
  atSign,
  HivePersistenceConfig.clientDefaults(
    storagePath: storageDir,
    commitLogPath: storageDir,
  ),
);

// Each test then references testBundle.X instead of the singleton chains.

// In tearDownAll (NOT tearDown — see Test patterns below):
await testFactory.close();
```

If a test relies on cross-test data leak (cram-style), keep the
factory file-scoped and only call `bundle.clear()` in `setUp`
when the test actually needs isolation. See
[Test patterns](#test-patterns).

### Step 6 — Run the suites

```bash
# in each package under at_client_sdk:
dart test --concurrency=1
```

`--concurrency=1` is required for atsign repos because Hive boxes
are process-global by atSign sha; parallel test runs collide.

If the at_client_sdk has a functional test suite, run that too.

### Step 7 — Verify

See [Verification](#verification-how-to-know-youre-done).

---

## Server-track migration

For consumers that run a full atSecondary (e.g.
`at_secondary_server` itself, plus any downstream that runs its
own secondary). These consumers use the **full** persistence
surface.

The migration shape is similar to the client playbook above, with
two differences:

1. Use `HivePersistenceConfig.serverDefaults(...)` (opts into
   every capability) rather than `clientDefaults`.
2. After `factory.initialize(...)`, run a single
   `_assertServerCapabilities(bundle)` helper at bootstrap to
   confirm the optional capabilities are populated, then bind
   them to non-nullable `late` fields. This keeps `!` litter out
   of every verb handler. See
   [Bundle shape](#bundle-shape-slim-core--optional-capabilities)
   for the recommended pattern.

The reference implementation lives at
`packages/at_secondary_server/lib/src/server/at_secondary_impl.dart`
in this repo (`_initializePersistentInstances`).

---

## Class renames

Phase 2 Commit 1 renames the Hive-backed concretes so the
unprefixed names can be reused as the abstract interfaces
introduced in Commit 2.

| Old name (concrete)      | New name (concrete)          | Notes                                                                                              |
|--------------------------|------------------------------|----------------------------------------------------------------------------------------------------|
| `AtCommitLog`            | `HiveAtCommitLog`            | Server-flavour Hive impl. The unprefixed `AtCommitLog` becomes the abstract interface in Commit 2. |
| `ClientAtCommitLog`      | `HiveClientAtCommitLog`      | Client-flavour Hive impl (extends `HiveAtCommitLog`).                                              |
| `AtAccessLog`            | `HiveAtAccessLog`            | Hive impl. Unprefixed name will become abstract in Commit 2.                                       |
| `AtNotificationKeystore` | `HiveAtNotificationKeystore` | Hive impl of the notification queue. Unprefixed name will become abstract in Commit 2.             |
| `HiveKeystore`           | `HiveSecondaryKeyStore`      | Hive impl of the abstract `SecondaryKeyStore` (which already existed in `at_persistence_spec`).    |

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

| Old path                                         | New path                                              |
|--------------------------------------------------|-------------------------------------------------------|
| `src/log/commitlog/at_commit_log.dart`           | `src/log/commitlog/hive_at_commit_log.dart`           |
| `src/log/accesslog/at_access_log.dart`           | `src/log/accesslog/hive_at_access_log.dart`           |
| `src/notification/at_notification_keystore.dart` | `src/notification/hive_at_notification_keystore.dart` |
| `src/keystore/hive_keystore.dart`                | `src/keystore/hive_secondary_keystore.dart`           |

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

| Abstract                                                       | Hive concrete                |
|----------------------------------------------------------------|------------------------------|
| `AtCommitLog`                                                  | `HiveAtCommitLog`            |
| `AtAccessLog`                                                  | `HiveAtAccessLog`            |
| `AtNotificationKeystore`                                       | `HiveAtNotificationKeystore` |
| `SecondaryKeyStore` (already existed in `at_persistence_spec`) | `HiveSecondaryKeyStore`      |

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

These are the constructor signatures that changed between 4.3.5
and 5.0.0. Only the **final** 5.0.0 signature is shown — some
classes (`AtCompactionJob`) changed twice across the arc but the
intermediate forms never shipped to consumers.

- **`AtCompactionJob`**:
  - 4.3.5: `AtCompactionJob(AtLogType logType, SecondaryPersistenceStore store)`
  - 5.0.0: `AtCompactionJob(AtCompactionStrategy strategy, [AtCompactionStatsService? stats])`
  - Migration: pass `bundle.commitLogCompactor!` (or
    `accessLogCompactor!` / `keyStoreCompactor!`) as the
    strategy. Stats writing is optional now — pass an
    `AtCompactionStatsServiceImpl(<atLogType>, <keyStore>)` as
    the second argument to keep the 4.3.5 stats-recording
    behaviour.
- **`AtCompactionStatsServiceImpl`**:
  - 4.3.5: `(AtCompaction atCompaction, SecondaryPersistenceStore store)`
  - 5.0.0: `(AtCompaction atCompaction, SecondaryKeyStore keyStore)`
  - Migration: pass the keystore directly instead of the
    persistence-store wrapper.
- **`AtConfig`** (server-track only — `at_client_sdk` never imported it):
  - 4.3.5: `AtConfig(AtCommitLog commitLog, String atSign)`
  - 5.0.0: `AtConfig(SecondaryKeyStore keyStore, String atSign)`
  - Also moved to `package:at_secondary/src/config/at_config.dart`.
- **`HiveAtCommitLog`** / **`HiveClientAtCommitLog`** /
  **`HiveAtAccessLog`** / **`HiveAtNotificationKeystore`**:
  unchanged constructor signatures (just renamed; the args still
  take the same `*KeyStore` / atSign as 4.3.5). These exist to
  let `HiveAtPersistenceFactory.initialize` build them; downstream
  consumers should construct via the factory, not directly.

## Removed APIs

The deprecated `getInstance()` shims that 4.x exposed are gone in
5.0.0. Bootstrap via the factory pattern instead.

| Removed                                                                 | Replacement                                                            |
|-------------------------------------------------------------------------|------------------------------------------------------------------------|
| `SecondaryPersistenceStoreFactory.getInstance()`                        | `HiveAtPersistenceFactory()` and the resulting `bundle`                |
| `AtCommitLogManagerImpl.getInstance().getCommitLog(atSign)`             | `bundle.commitLog`                                                     |
| `AtAccessLogManagerImpl.getInstance().getAccessLog(atSign)`             | `bundle.accessLog` (server-track only)                                 |
| `AtCompactionService.getInstance()`                                     | `AtCompactionService()` (per-job)                                      |
| `HiveKeyStoreHelper.getInstance().prepareKey(k)`                        | `HiveKeyStoreHelper.prepareKey(k)` (now static)                        |
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

### Compaction

Phase 2 splits the compaction surface into a *strategy* (which
the bundle owns) and a *scheduler* (`AtCompactionJob`).

- New abstract `AtCompactionStrategy` with `setConfig(AtCompactionConfig)`
  + `Future<AtCompactionStats> compact()`. Bundle exposes three
  nullable strategy fields: `commitLogCompactor?`,
  `accessLogCompactor?`, `keyStoreCompactor?`. Server config opts
  in to all; client config opts in to commit-log-only.
- `AtCompactionJob` constructor changed: takes
  `(AtCompactionStrategy strategy, [AtCompactionStatsService? stats])`
  rather than `(AtLogType logType, SecondaryKeyStore keyStore)`.
- The deprecated `AtCompactionStrategy` *interface* in
  `at_persistence_spec` is gone (it was already
  `@Deprecated('use CompactionService')` and unimplemented).

**Server-track recipe.** Server consumers (this repo's
`at_secondary_server`) construct an `AtCompactionStatsServiceImpl`
explicitly (the old constructor built one internally) and pull
the strategy off the bundle:

```dart
commitLogCompactionJobInstance = AtCompactionJob(
    bundle.commitLogCompactor!,
    AtCompactionStatsServiceImpl(commitLog, secondaryKeyStore));
commitLogCompactionJobInstance.scheduleCompactionJob(
    AtCompactionConfig()
      ..compactionPercentage = 50
      ..compactionFrequencyInMins = 30);
```

Same shape for `accessLogCompactor` and `keyStoreCompactor`.

**Client-track recipe.** `at_client_sdk` previously did:

```dart
AtCompactionJob atCompactionJob = AtCompactionJob(
    (await AtCommitLogManagerImpl.getInstance().getCommitLog(_atSign))!,
    SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(_atSign)!);
```

After 5.0.0:

```dart
AtCompactionJob atCompactionJob =
    AtCompactionJob(bundle.commitLogCompactor!);
```

(Stats writing is optional on the client, so the second arg is
omitted. Pass an `AtCompactionStatsServiceImpl(commitLog, keyStore)`
if the client wants to record metrics — same shape as server.)

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

**Note on `enableCommitId`.** The client commit log uses
commitIds assigned by the server (during sync), not auto-incremented
locally. `HivePersistenceConfig.clientDefaults(...)` sets
`enableCommitId: false` internally; this matches the explicit
`enableCommitId: false` you'd see in the 4.3.5 bootstrap. You
do not need to set it (or override it) when using `clientDefaults`.

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
  primitives.
- `AtCompactionStrategy` interface +
  `bundle.commitLogCompactor` / `accessLogCompactor` /
  `keyStoreCompactor`. `AtCompactionJob` now takes a strategy
  rather than a log+keystore pair.
- `AtPersistenceBundle.clear()` — drops every entry from each
  store while keeping the underlying boxes open. Cheap test
  isolation primitive; production code uses `close()` instead.

## Test patterns

`bundle.clear()` (Phase 2 Commit 5) lets test files use a
file-scoped factory + `tearDownAll` close + per-test `clear()` for
isolation, instead of opening and closing the factory per test
(which surfaces Hive lifecycle bugs that aren't representative of
production behaviour).

```dart
late HiveAtPersistenceFactory factory;
late AtPersistenceBundle bundle;

setUpAll(() async {
  factory = HiveAtPersistenceFactory();
  bundle = await factory.initialize(
    '@alice',
    HivePersistenceConfig.serverDefaults(...),
  );
});

setUp(() async => await bundle.clear()); // empty store before each test

tearDownAll(() => factory.close());
```

The `at_secondary_server` test suite documents these conventions
at the top of `test/test_utils.dart`. Downstream test suites
(including the at_client_sdk migration) can adopt the same shape.

## Worked example: at_client_sdk's `LocalSecondary` and sync engine

The pre-Phase-2 sweep against `at_client_sdk` (gkc-at-collection-snagging
branch) found 56 sites across 6 `lib/` files and ~30 test files. All
patterns map to recipes already documented above. Two are illustrated
here end-to-end as worked examples for the at_client_sdk migration.

### `LocalSecondary` keystore bootstrap

Before (`at_client/lib/src/client/local_secondary.dart`):

```dart
class LocalSecondary implements Secondary {
  final AtClient _atClient;
  SecondaryKeyStore? keyStore;

  LocalSecondary(this._atClient, {this.keyStore}) {
    keyStore ??= SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(_atClient.getCurrentAtSign())!
        .getSecondaryKeyStore();
  }
}
```

After:

```dart
class LocalSecondary implements Secondary {
  final AtClient _atClient;
  SecondaryKeyStore? keyStore;

  LocalSecondary(this._atClient, {this.keyStore}) {
    // The bundle is owned by AtClientImpl; LocalSecondary just
    // reads `bundle.keyStore`.
    keyStore ??= _atClient.persistenceBundle.keyStore;
  }
}
```

The `AtClient` interface gains a `persistenceBundle` getter that
exposes the bundle the at_client_sdk's `AtClientImpl` initialised
at startup against `HivePersistenceConfig.clientDefaults(...)`.

### Compaction job in `AtClientImpl.startCompactionJob`

Before (`at_client/lib/src/client/at_client_impl.dart:364`):

```dart
AtCompactionJob atCompactionJob = AtCompactionJob(
    (await AtCommitLogManagerImpl.getInstance().getCommitLog(_atSign))!,
    SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(_atSign)!);

_atClientCommitLogCompaction ??=
    AtClientCommitLogCompaction.create(_atSign, atCompactionJob);
```

After:

```dart
AtCompactionJob atCompactionJob =
    AtCompactionJob(persistenceBundle.commitLogCompactor!);

_atClientCommitLogCompaction ??=
    AtClientCommitLogCompaction.create(_atSign, atCompactionJob);
```

(Stats writing was implicit in the old constructor; clients that
want to record compaction metrics should pass an
`AtCompactionStatsServiceImpl(commitLog, keyStore)` as the second
arg, same as the server-track recipe.)

### Sync helpers in `at_client/lib/src/util/sync_util.dart`

The seven `AtCommitLogManagerImpl.getInstance().getCommitLog(atSign)`
sites all become `_atClient.persistenceBundle.commitLog` once the
sync helpers take the AtClient (or just the bundle) by parameter.

### Tests

Test files (~30 sites across `local_secondary_test`,
`sync_new_test`, `at_client_termination_test`,
`apkam_authorization_test`, `encryption_service_test`,
`delete_expired_keys_task_test`, `at_onboarding_cli_test`)
mirror the `at_persistence_secondary_server`'s own test migration:
top-of-file `late HiveAtPersistenceFactory factory; late
AtPersistenceBundle bundle;` plus a `setUpFunc` that calls
`factory.initialize(...)` and assigns. Each `*.getInstance()...`
call site becomes a reference to `bundle.X`.

The functional-test sites in `tests/at_functional_test/test/`
(`commit_log_compaction_test`, `sync_multiple_client_test`,
`atclient_sync_callback_test`) follow the same pattern, with
`AtCompactionService.getInstance().executeCompaction(...)` →
`bundle.commitLogCompactor!.compact()`.

## Canonical example files

When a worked example would help — point at concrete sources that
exercise the new API rather than embed snippets that drift:

- **Server bootstrap end-to-end:**
  `packages/at_persistence_secondary_server/test/at_persistence_factory_test.dart`
  — exhaustive tests of factory init / close / two-atSign isolation,
  using `HivePersistenceConfig.serverDefaults(...)`.
- **Bundle slimming + serverDefaults / clientDefaults:**
  `packages/at_persistence_secondary_server/test/iterate_replay_test.dart`
  ("Bundle slimming" group) — exercises both factory shapes side
  by side.
- **`replay` and `iterate` migration primitives:**
  `packages/at_persistence_secondary_server/test/iterate_replay_test.dart`
  — yield-order, idempotency, no-listener-fire on replay.
- **`bundle.clear()` test isolation pattern:**
  `packages/at_persistence_secondary_server/test/iterate_replay_test.dart`
  ("Bundle clear" group) — populate every store, clear, verify
  bundle is reusable.
- **AtConfig (now in `at_secondary`):**
  `packages/at_secondary_server/lib/src/config/at_config.dart`
  — server-side block-list config wired through the new
  `SecondaryKeyStore` constructor.
- **Server-side compaction wiring:**
  `packages/at_secondary_server/lib/src/server/at_secondary_impl.dart`
  (search for `commitLogCompactionJobInstance`) — three jobs
  constructed against `bundle.commitLogCompactor` /
  `accessLogCompactor` / `keyStoreCompactor`.

---

## Verification: how to know you're done

After working through the playbook, the migration is complete
when **all** of these hold:

1. **No deprecated symbols in `lib/` or `test/`.** Run from the
   downstream package's root:

   ```bash
   git grep -nE \
     'SecondaryPersistenceStoreFactory\.getInstance|AtCommitLogManagerImpl\.getInstance|AtAccessLogManagerImpl\.getInstance|AtCompactionService\.getInstance|HiveKeyStoreHelper\.getInstance|StatsNotificationService\.getInstance|BaseAtCommitLog|AtNotificationCallback|getHivePersistenceManager\b' \
     -- lib test
   ```

   Expected output: zero hits.

2. **No bare unprefixed concrete-name uses.** Make sure the old
   concrete names aren't being constructed directly (mocking the
   abstract is fine — that's the SAME unprefixed name now):

   ```bash
   git grep -nE '\bAtCommitLog\(|\bClientAtCommitLog\(|\bAtAccessLog\(|\bAtNotificationKeystore\(|\bHiveKeystore\(' \
     -- lib test
   ```

   Expected output: zero hits. (The `Hive`-prefixed names are
   constructor calls of the renamed classes; if any test
   constructs them directly, that's fine — the names are correct.)

3. **`dart analyze` clean.** From every package's root:

   ```bash
   dart analyze
   ```

   Expected: `No issues found!`. If `info`-level hints remain
   they're cosmetic and OK.

4. **Tests green.** Use the `--concurrency=1` flag — atsign repos
   share Hive box state by atSign sha across parallel runs:

   ```bash
   dart test --concurrency=1
   ```

5. **Functional / integration tests green** (if the package has
   them — `at_client_sdk` does at `tests/at_functional_test/`).

6. **No imports of removed files.** Confirm:

   ```bash
   git grep -nE \
     'src/log/commitlog/at_commit_log\.dart|src/log/accesslog/at_access_log\.dart|src/notification/at_notification_keystore\.dart|src/keystore/hive_keystore\.dart|src/log/at_commit_log_manager\.dart|src/log/at_access_log_manager\.dart' \
     -- lib test
   ```

   Expected output: zero hits.

If all six pass, the migration is done. Open a PR; the diff
should be entirely import / type / call-site updates, no
behavioural changes.

### Smoke-testing the runtime

If you want to verify behavioural parity beyond passing tests:

- **Sync flow:** create a key on one client, sync to the server,
  pull from a second client. The commit log on each client
  should still record the operation.
- **Compaction:** populate the commit log to past the configured
  threshold, wait for the cron tick, confirm `bundle.commitLog.entriesCount()`
  drops.
- **Local cache reads:** read a previously-synced key without
  network access — should still come from `bundle.keyStore`.

These exercise the parts of the bundle that unit tests don't
fully cover.
