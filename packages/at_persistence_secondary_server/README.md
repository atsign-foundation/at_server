<a href="https://atsign.com#gh-light-mode-only"><img width=250px src="https://atsign.com/wp-content/uploads/2022/05/atsign-logo-horizontal-color2022.svg#gh-light-mode-only" alt="The Atsign Foundation"></a><a href="https://atsign.com#gh-dark-mode-only"><img width=250px src="https://atsign.com/wp-content/uploads/2023/08/atsign-logo-horizontal-reverse2022-Color.svg#gh-dark-mode-only" alt="The Atsign Foundation"></a>

[![Pub Package](https://img.shields.io/pub/v/at_persistence_secondary_server)](https://pub.dev/packages/at_persistence_secondary_server)

# at_persistence_secondary_server

The per-atSign persistence layer for the Atsign Protocol. Used by:

- **`at_secondary_server`** (this repo) — the full atSecondary
  implementation that runs as a per-atSign cloud service.
- **`at_client_sdk`** — uses this package as the local-first cache
  backing every client app's `LocalSecondary`.

The package provides three per-atSign stores — the **keystore**
(optionally backed by a **commit log**), the **access log**, and the
**notification keystore** — plus the factory/bundle machinery that
opens and closes them. Compaction is exposed as a primitive on each
store; *scheduling* it is the consumer's concern.

The public surface is **backend-pluggable**: today's only backend is
Hive, but the abstractions are designed so a future backend (e.g.
SQLite, Postgres) drops in without changing call sites. Import the
abstract surface from
`package:at_persistence_secondary_server/at_persistence_secondary_server.dart`
and the Hive implementation from
`package:at_persistence_secondary_server/hive.dart`.

> ## Migrating from 4.3.5 to 5.0.0?
>
> 5.0.0 is a major release with a clean break — no deprecation
> shims. **See [`MIGRATION.md`](./MIGRATION.md)**: what changed in
> this package, how `at_secondary_server` was reworked to consume
> it, and a step-by-step guide for migrating `at_client`.

## Contents

- [Quick start](#quick-start)
- [Architecture](#architecture)
- [Server vs client configuration](#server-vs-client-configuration)
- [Bundle lifecycle](#bundle-lifecycle)
- [Compaction](#compaction)
- [Migration / iteration primitives](#migration--iteration-primitives)
- [Testing](#testing)
- [Worked examples](#worked-examples)
- [Migrating from 4.x](#migrating-from-4x)
- [License](#license)

## SQLite Version Pinning

This package pins the `sqlite3` dependency to `^2.4.0` (which resolves up to `2.9.x`). **Do not upgrade to `sqlite3 >= 3.0.0`.**

The `sqlite3` 3.x release introduced a major architectural breaking change: it removed `DynamicLibrary.open()` in favor of Dart's experimental Native Assets (`build hooks`) for loading the C library. Upgrading to 3.x would break our standalone compilation pipelines and Docker builds for the `atServer` across different platforms. We will remain on the 2.x line until Dart's Native Assets are fully stable and supported across our build targets.

## Quick start

Bootstrap a per-atSign bundle via the factory, then read the stores
off it:

```dart
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';

final factory = HiveAtPersistenceFactory();
final bundle = await factory.initialize(
  '@alice',
  HivePersistenceConfig.serverDefaults(
    storagePath: '/var/atsign/alice/keys',
    commitLogPath: '/var/atsign/alice/commitLog',
    accessLogPath: '/var/atsign/alice/accessLog',
    notificationStoragePath: '/var/atsign/alice/notifications',
  ),
);

// Read / write the keystore.
await bundle.keyValueStore.put('phone.wavi@alice', AtData()..data = '+1...');
final entry = await bundle.keyValueStore.get('phone.wavi@alice');

// ... later, on shutdown:
await factory.close();
```

For client-side consumers (e.g. `at_client_sdk`'s `LocalSecondary`),
use the slimmer config:

```dart
final bundle = await factory.initialize(
  '@alice',
  HivePersistenceConfig.clientDefaults(
    storagePath: '${appDocDir.path}/keys',
  ),
);
```

`clientDefaults` opts into the keystore only, and builds it
**commit-log-free**: `bundle.keyValueStore.commitLog`,
`bundle.accessLog`, and `bundle.notificationKeystore` are all `null`
under this config. Client writes succeed and return `null` (no
commit-log sequence number); the client tracks sync through its own
mechanism rather than the commit log.

## Architecture

### Factory + bundle

`AtPersistenceFactory` is the per-process owner of per-atSign
persistence resources. It hands back an `AtPersistenceBundle` for
each atSign, caching internally so repeat `initialize(...)` calls
return the same bundle. `HiveAtPersistenceFactory` is the only
concrete implementation today.

The factory pattern replaces the 4.x singleton chain
(`SecondaryPersistenceStoreFactory.getInstance().getSecondaryPersistenceStore(...)`
and friends) — see [`MIGRATION.md`](./MIGRATION.md) for the full
list of removed singletons and what to use instead.

### End-to-end encryption is architectural

Records in this package's keystore are end-to-end encrypted between
atSigns. **The server never holds the decryption keys for the data
it stores.** This is why the keystore exposes key-structure-based
filtering (regex / `KeyPattern` over the atKey, used by sync) but
NOT value-level filtering — the server can't see plaintext to filter
on. Don't try to add value-level predicates here; they're
architecturally impossible for any consumer that respects the trust
model.

### Slim core + optional capabilities

`AtPersistenceBundle` is a slim core (always present) plus optional
capabilities (nullable, populated based on config):

| Member                      | Type                                            | Core / optional | `serverDefaults` | `clientDefaults` |
|------------------------------|-------------------------------------------------|-----------------|------------------|------------------|
| `atSign`                     | `String`                                        | core            | ✓                | ✓                |
| `backendId`                  | `AtPersistenceBackendId`                        | core            | ✓                | ✓                |
| `keyValueStore`              | `AtKeyValueStore<String, AtData, AtMetaData?>`   | core            | ✓                | ✓                |
| `keyValueStore.commitLog`    | `AtCommitLog?`                                  | optional        | non-null         | `null`           |
| `accessLog`                  | `AtAccessLog?`                                  | optional        | non-null         | `null`           |
| `notificationKeystore`       | `AtNotificationKeystore?`                       | optional        | non-null         | `null`           |
| `clear()` / `close()`        | method                                          | core            | ✓                | ✓                |

The commit log is **not** a top-level bundle field — it lives on the
keystore as `keyValueStore.commitLog`, and is `null` on a
commit-log-free (client) bundle. The `enableX` toggles on
`AtPersistenceConfig` decide which optionals get populated.

**Server-side pattern** for binding the optionals as non-null
without `!` litter at every call site — assert once at bootstrap,
then bind to non-nullable `late` fields:

```dart
final bundle = await persistenceFactory.initialize(atSign, config);
_assertServerCapabilities(bundle); // throws StateError if any null

late AtCommitLog commitLog = bundle.keyValueStore.commitLog!;
late AtAccessLog accessLog = bundle.accessLog!;
late AtNotificationKeystore notificationKeystore =
    bundle.notificationKeystore!;
```

`_assertServerCapabilities` is a small helper on the consumer side;
see
`packages/at_secondary_server/lib/src/server/at_secondary_impl.dart`
for the reference implementation.

### Keystore interface hierarchy

`KeyValueStore<K, V>` is the unified, backend-agnostic CRUD + rich
surface (single-key reads/writes, `scanKeys`, bulk `getMany` /
`removeMany`, the `changes` stream, `transaction`, `snapshot`,
`stats`). `AtKeyValueStore<K, V, T>` extends it with the
sync-coupled surface: the nullable `commitLog`, the `putMeta` /
`putAll` / `getMeta` metadata triplet, and `queryByPath` /
`supportsPathQueries`. The notification queue implements plain
`KeyValueStore` — notifications have no commit log.

### Concrete classes (Hive)

Each abstract is paired with a Hive-backed concrete that the factory
wires up internally. Consumers normally interact with the abstract
via the bundle and don't construct the concretes directly:

| Abstract                                       | Hive concrete                |
|------------------------------------------------|------------------------------|
| `AtKeyValueStore<String, AtData, AtMetaData?>` | `HiveAtKeyValueStore`        |
| `AtCommitLog`                                  | `HiveAtCommitLog`            |
| `AtAccessLog`                                  | `HiveAtAccessLog`            |
| `AtNotificationKeystore`                       | `HiveAtNotificationKeystore` |

The abstracts and the new query types (`KeyPattern`, `KeyEntry`,
`Predicate`, `KeyStoreChange`, `KeyStoreSnapshot`, `KeyStoreStats`,
`KeyStoreTxn`, `OrderByKey`) ship from this package — there is no
`at_persistence_spec` dependency.

## Server vs client configuration

The two `HivePersistenceConfig` factories cover the common shapes:

| Config                | `enableCommitLog` | `enableAccessLog` | `enableNotificationKeystore` |
|-----------------------|:-----------------:|:-----------------:|:----------------------------:|
| `serverDefaults(...)` | ✓                 | ✓                 | ✓                            |
| `clientDefaults(...)` | ✗                 | ✗                 | ✗                            |

`serverDefaults` requires all four storage paths; `clientDefaults`
takes only `storagePath` (the keystore is commit-log-free, so no
`commitLogPath`). Custom mixes are supported via the full
`HivePersistenceConfig(...)` constructor — every flag has a named
parameter.

## Bundle lifecycle

- `factory.initialize(atSign, config)` — open every store the config
  requested. Idempotent per atSign within a factory.
- `bundle.clear()` — drop every entry from the bundle's stores while
  keeping the underlying boxes open. Idempotent. Intended for cheap
  test isolation; production code uses `close()`.
- `factory.close()` — close every bundle the factory produced.
  Idempotent and rerunnable: a fresh `initialize(...)` after
  `close()` opens a new lifecycle.

Periodic maintenance — the key-expiry sweep and compaction — is
scheduled by the consumer, not by this package (see below).

## Compaction

Every store that accumulates entries — the commit log, access log,
and notification keystore — implements the `Compactable` interface;
`AtKeyValueStore` does too, delegating to its commit log (a no-op on
a commit-log-free keystore):

```dart
abstract interface class Compactable {
  Stream<Object> compact(bool dryRun);
}
```

`compact(false)` performs the compaction and yields each item
removed; `compact(true)` is a dry run that yields what *would* be
removed without mutating anything. Each Hive impl carries its own
`compactionPercentage` and decides what "compact" means — the commit
log drops its oldest entries; a future SQL backend would
`DELETE ... WHERE` and `VACUUM`.

**Scheduling is not this package's job.** The persistence layer
exposes `compact(...)` as a primitive; deciding *when* to run it
belongs to the consumer. `at_secondary_server` runs three
`Timer.periodic` ticks (commit log, access log, notification
keystore) with overlap guards, plus a periodic key-expiry sweep that
calls `keyValueStore.deleteExpiredKeys()` — see `at_secondary_impl.dart`.

## Migration / iteration primitives

These methods exist on the abstract surfaces for the
persistence-backend migrator and for any tool that needs full-store
traversal. Most consumers won't call them directly:

- `AtCommitLog.replay(CommitEntry entry)` — write an entry under its
  supplied `commitId` without firing change-event listeners.
  Idempotent on `(commitId, atKey, op)`.
- `AtCommitLog.iterate({int? fromCommitId, bool Function(CommitEntry)? where})`
  — lazy `Stream<CommitEntry>` in `commitId` order; `where` carries
  any caller-side filtering.
- `AtAccessLog.iterate()` — `Stream<AccessLogEntry>` in insertion
  order.
- `AtNotificationKeystore.iterate()` — `Stream<AtNotification>` of
  every pending entry.

## Testing

Tests in this package open Hive boxes keyed by atSign sha — Hive's
box registry is process-global, so parallel test runs across the
same atSign collide. Always run with `--concurrency=1`:

```bash
dart test --concurrency=1
```

The recommended test setup uses a file-scoped factory +
`tearDownAll` close + per-test `bundle.clear()` for isolation:

```dart
late HiveAtPersistenceFactory factory;
late AtPersistenceBundle bundle;

setUpAll(() async {
  factory = HiveAtPersistenceFactory();
  bundle = await factory.initialize(
    '@alice',
    HivePersistenceConfig.serverDefaults(/* paths */),
  );
});

setUp(() async => await bundle.clear());

tearDownAll(() => factory.close());
```

If tests in the same file rely on cross-test data leak (e.g. a
`setUp` seeds shared baseline data and tests assume it persists),
omit the per-test `clear()` — but document that decision at the top
of the file.

## Worked examples

Concrete sources that exercise the API, rather than copy-paste
snippets that drift:

- **Factory bootstrap end-to-end:**
  [`test/at_persistence_factory_test.dart`](./test/at_persistence_factory_test.dart)
  — init / close / two-atSign isolation, using `serverDefaults(...)`.
- **Commit-log-free keystore (`clientDefaults`):**
  [`test/commit_log_free_test.dart`](./test/commit_log_free_test.dart)
  — every write succeeds with a `null` commit log; `compact()` is a
  no-op.
- **Bundle slimming + `serverDefaults` / `clientDefaults`:**
  [`test/iterate_replay_test.dart`](./test/iterate_replay_test.dart)
  ("Bundle slimming" group) — both factory shapes side by side.
- **`replay` / `iterate` migration primitives, and `bundle.clear()`:**
  [`test/iterate_replay_test.dart`](./test/iterate_replay_test.dart).
- **Server-side compaction + expiry scheduling:**
  `packages/at_secondary_server/lib/src/server/at_secondary_impl.dart`
  — the `Timer.periodic` ticks that drive `compact(...)` and
  `deleteExpiredKeys()`.
- **Minimal example program:** [`example/main.dart`](./example/main.dart).

## Migrating from 4.x

5.0.0 is a clean major release — deprecated singletons removed,
class renames, a slim factory-built bundle, abstract interfaces, and
a commit-log-free option for client consumers. No shims; consumers
move directly from 4.3.5 to 5.0.0.

**Read [`MIGRATION.md`](./MIGRATION.md).** It has three sections:

1. What changed in this package (5.0.0 vs 4.3.5), and why.
2. How `at_secondary_server` was reworked to consume the new
   persistence package.
3. A step-by-step guide for migrating `at_client` onto 5.0.0 and a
   commit-log-free local keystore.

## License

See [`LICENSE`](./LICENSE).
