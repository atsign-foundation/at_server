<a href="https://atsign.com#gh-light-mode-only"><img width=250px src="https://atsign.com/wp-content/uploads/2022/05/atsign-logo-horizontal-color2022.svg#gh-light-mode-only" alt="The Atsign Foundation"></a><a href="https://atsign.com#gh-dark-mode-only"><img width=250px src="https://atsign.com/wp-content/uploads/2023/08/atsign-logo-horizontal-reverse2022-Color.svg#gh-dark-mode-only" alt="The Atsign Foundation"></a>

[![Pub Package](https://img.shields.io/pub/v/at_persistence_secondary_server)](https://pub.dev/packages/at_persistence_secondary_server)

# at_persistence_secondary_server

The per-atSign persistence layer for the Atsign Protocol. Used by:

- **`at_secondary_server`** (this repo) — the full atSecondary
  implementation that runs as a per-atSign cloud service.
- **`at_client_sdk`** — uses this package as the local-first cache
  backing every client app's `LocalSecondary`.

The package owns four kinds of per-atSign storage (keystore,
commit log, access log, notification keystore) plus the lifecycle
machinery that opens, schedules, compacts, and closes them. The
public surface is **backend-pluggable**: today's only backend is
Hive, but the abstractions are designed so that future backends
(e.g. SQLite, Postgres) drop in without changing call sites.

> ## Migrating from 4.3.5 to 5.0.0?
>
> 5.0.0 is a major release with a clean break — no deprecation
> shims. **See [`MIGRATION.md`](./MIGRATION.md)** for a
> step-by-step playbook (separate tracks for `at_client_sdk`-shaped
> consumers and full-secondary consumers), removed-API tables,
> and verification gates.

## Contents

- [Quick start](#quick-start)
- [Architecture](#architecture)
- [Server vs client configuration](#server-vs-client-configuration)
- [Bundle capabilities](#bundle-capabilities)
- [Compaction](#compaction)
- [Migration / iteration primitives](#migration--iteration-primitives)
- [Testing](#testing)
- [Worked examples](#worked-examples)
- [Migrating from 4.x](#migrating-from-4x)
- [License](#license)

## Quick start

Bootstrap a per-atSign bundle via the factory, then read the
stores off it:

```dart
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

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
await bundle.keyStore.put('phone@alice', AtData()..data = '+1...');
final entry = await bundle.keyStore.get('phone@alice');

// Schedule the periodic key-expiry sweep.
bundle.scheduleKeyExpireTask(/* runFrequencyMins */ 3);

// ... later, on shutdown:
await factory.close();
```

For client-side consumers (e.g. `at_client_sdk`'s
`LocalSecondary`), use the slimmer config:

```dart
final bundle = await factory.initialize(
  '@alice',
  HivePersistenceConfig.clientDefaults(
    storagePath: '${appDocDir.path}/keys',
    commitLogPath: '${appDocDir.path}/commitLog',
  ),
);
```

`clientDefaults` opts into core capabilities only — keystore,
commit log (with `enableCommitId: false` so commit IDs are
assigned by the server during sync, not auto-incremented locally),
and the commit-log compactor. `bundle.accessLog` and
`bundle.notificationKeystore` are `null` under this config; the
client never used them anyway.

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

Records in this package's keystore are end-to-end encrypted
between atSigns. **The server never holds the decryption keys for
the data it stores.** This is why the keystore exposes
key-structure-based filtering (regex over atKey, used by sync) but
NOT value-level filtering — the server can't see plaintext to
filter on. Don't try to add value-level predicates here; they're
architecturally impossible for any consumer that respects the
trust model.

### Slim core + optional capabilities

`AtPersistenceBundle` is split into a *core* (always present) and
*optional capabilities* (nullable, populated based on config):

| Capability                   | Type                       | Core / optional | Server config | Client config |
|------------------------------|----------------------------|-----------------|---------------|---------------|
| `atSign`                     | `String`                   | core            | ✓             | ✓             |
| `backendId`                  | `AtPersistenceBackendId`   | core            | ✓             | ✓             |
| `keyStore`                   | `SecondaryKeyStore<…>`     | core            | ✓             | ✓             |
| `commitLog`                  | `AtCommitLog`              | core            | ✓             | ✓             |
| `scheduleKeyExpireTask(...)` | method                     | core            | ✓             | ✓             |
| `clear()` / `close()`        | method                     | core            | ✓             | ✓             |
| `accessLog`                  | `AtAccessLog?`             | optional        | ✓             | `null`        |
| `notificationKeystore`       | `AtNotificationKeystore?`  | optional        | ✓             | `null`        |
| `commitLogCompactor`         | `AtCompactionStrategy?`    | optional        | ✓             | ✓             |
| `accessLogCompactor`         | `AtCompactionStrategy?`    | optional        | ✓             | `null`        |
| `keyStoreCompactor`          | `AtCompactionStrategy?`    | optional        | ✓             | `null`        |

The `enableX` toggles on `AtPersistenceConfig` decide which
optionals get populated. `HivePersistenceConfig.serverDefaults()`
opts in to all; `clientDefaults()` opts in to core + commit-log
compactor only.

**Server-side pattern** for binding the optionals as non-null
without `!` litter at every call site — assert once at bootstrap,
then bind to non-nullable `late` fields:

```dart
final bundle = await persistenceFactory.initialize(atSign, config);
_assertServerCapabilities(bundle); // throws StateError if any null

late AtAccessLog accessLog = bundle.accessLog!;
late AtNotificationKeystore notificationKeystore =
    bundle.notificationKeystore!;
```

`_assertServerCapabilities` is a small helper on the consumer
side; see
`packages/at_secondary_server/lib/src/server/at_secondary_impl.dart`
for the reference implementation.

### Concrete classes (Hive)

Each abstract is paired with a Hive-backed concrete that the
factory wires up internally. Consumers normally interact with the
abstract via the bundle and don't construct the concretes
directly:

| Abstract                 | Hive concrete                | Notes                                                                |
|--------------------------|------------------------------|----------------------------------------------------------------------|
| `SecondaryKeyStore<…>`   | `HiveSecondaryKeyStore`      | Defined in `at_persistence_spec`; this package supplies the impl.    |
| `AtCommitLog`            | `HiveAtCommitLog`            | Server-flavour: auto-assigns `commitId` on `commit(...)`.            |
| `AtCommitLog`            | `HiveClientAtCommitLog`      | Client-flavour: `commitId` set by `update(...)` from sync responses. |
| `AtAccessLog`            | `HiveAtAccessLog`            | Server-only audit trail.                                             |
| `AtNotificationKeystore` | `HiveAtNotificationKeystore` | Server-side notification queue.                                      |

## Server vs client configuration

The two `HivePersistenceConfig` factories cover the common shapes:

| Config                | `enableCommitId` | `enableAccessLog` | `enableNotificationKeystore` | `enableCommitLogCompactor` | `enableAccessLogCompactor` | `enableKeyStoreCompactor` |
|-----------------------|:----------------:|:-----------------:|:----------------------------:|:--------------------------:|:--------------------------:|:-------------------------:|
| `serverDefaults(...)` | ✓                | ✓                 | ✓                            | ✓                          | ✓                          | ✓                         |
| `clientDefaults(...)` | ✗                | ✗                 | ✗                            | ✓                          | ✗                          | ✗                         |

Custom mixes are also supported via the full
`HivePersistenceConfig(...)` constructor — every flag has a named
parameter.

## Bundle capabilities

The bundle's lifecycle methods, in the order you'd typically use
them:

- `factory.initialize(atSign, config)` — open every store the
  config requested. Idempotent per atSign within a factory.
- `bundle.scheduleKeyExpireTask(runFrequencyMins, runTimeInterval,
  skipCommits)` — start the cron that sweeps expired keys.
- `bundle.clear()` — drop every entry from the bundle's stores
  while keeping the underlying boxes open. Idempotent. Intended
  for cheap test isolation; production code uses `close()`.
- `factory.close()` — close every bundle the factory produced.
  Idempotent and rerunnable: a fresh `initialize(...)` after
  `close()` opens a new lifecycle.

## Compaction

This package owns the **strategy** side of compaction — what
"compact" means for a given backend. The bundle exposes one
strategy per log/store (`commitLogCompactor`,
`accessLogCompactor`, `keyStoreCompactor`), each implementing
the backend-agnostic `AtCompactionStrategy` contract:

```dart
abstract class AtCompactionStrategy {
  void setConfig(AtCompactionConfig config);
  Future<AtCompactionStats> compact();
}
```

On Hive, the supplied `HiveCompactionStrategy` reaches the
underlying `getKeysToDeleteOnCompaction()` /
`deleteKeyForCompaction(...)` primitives on each `AtLogType`. A
future SQLite or Postgres backend would implement the same
interface with `DELETE WHERE` plus `VACUUM`, and consumer code
would not change.

`AtCompactionStatsService` is the interface for the *sink* that
records each pass's metrics. Ship your own impl — or reuse one.

Scheduling — running a strategy on a cron, threading stats into
a sink — is the consumer's concern, not this package's. For
atSecondary, both the cron (`AtCompactionJob`) and the keystore-
backed stats sink (`AtCompactionStatsServiceImpl`) live in
`at_secondary_server/lib/src/compaction/`. A different consumer
might run compaction on demand, or push stats to Prometheus
instead of the keystore.

## Migration / iteration primitives

These methods exist on the abstract surfaces from 5.0.0 onwards.
Most consumers won't call them directly — they're for the
persistence-backend migrator (Phase 3) and for any tool that needs
full-store traversal:

- `AtCommitLog.replay(CommitEntry entry)` — write an entry under
  its supplied `commitId` without firing change-event listeners.
  Idempotent on `(commitId, atKey, op)`.
- `AtCommitLog.iterate({int? fromCommitId})` — `Stream<CommitEntry>`
  in `commitId` order.
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

The recommended test setup pattern uses a file-scoped factory +
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
setUp seeds shared baseline data and tests assume it persists),
omit the per-test `clear()` — but document that decision at the
top of the file.

`at_secondary_server`'s `test/test_utils.dart` documents the
recommended setup conventions in detail.

## Worked examples

When a worked example would help, point at concrete sources that
exercise the new API rather than copy-paste snippets that drift:

- **Factory bootstrap end-to-end:**
  [`test/at_persistence_factory_test.dart`](./test/at_persistence_factory_test.dart)
  — exhaustive tests of init / close / two-atSign isolation,
  using `HivePersistenceConfig.serverDefaults(...)`.
- **Bundle slimming + serverDefaults / clientDefaults:**
  [`test/iterate_replay_test.dart`](./test/iterate_replay_test.dart)
  ("Bundle slimming" group) — exercises both factory shapes side
  by side.
- **`replay` and `iterate` migration primitives:**
  [`test/iterate_replay_test.dart`](./test/iterate_replay_test.dart)
  — yield-order, idempotency, no-listener-fire on replay.
- **`bundle.clear()` test isolation:**
  [`test/iterate_replay_test.dart`](./test/iterate_replay_test.dart)
  ("Bundle clear" group) — populate every store, clear, verify
  the bundle is reusable.
- **Server-side compaction wiring:**
  `packages/at_secondary_server/lib/src/server/at_secondary_impl.dart`
  (search for `commitLogCompactionJobInstance`) — three jobs
  constructed against `bundle.commitLogCompactor` /
  `accessLogCompactor` / `keyStoreCompactor`.
- **Minimal example program:** [`example/main.dart`](./example/main.dart).

## Migrating from 4.x

5.0.0 is a clean major release: deprecated singletons removed,
class renames, slim bundle, abstract interfaces. There are no
shims; consumers move directly from 4.3.5 to 5.0.0.

**Read [`MIGRATION.md`](./MIGRATION.md).** It contains:

- A 1-minute TL;DR.
- A "what NOT to worry about" section for client-track consumers
  (so you can skip the server-only churn).
- A 7-step playbook for migrating `at_client_sdk` (and similarly
  shaped clients).
- A server-track migration section.
- Reference tables: class renames, removed APIs, constructor
  changes, import-path changes.
- A worked-example appendix walking through three canonical
  client-track migrations end-to-end.
- A verification section listing six concrete exit criteria
  (greps + `dart analyze` + tests).

## License

See [`LICENSE`](./LICENSE).
