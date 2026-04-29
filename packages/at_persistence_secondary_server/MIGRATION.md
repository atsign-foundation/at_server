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

## Constructor changes

(To be filled in as later commits land.)

## Removed APIs

(To be filled in as later commits land.)

## New APIs

(To be filled in as later commits land.)
