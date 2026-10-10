# Gatekeeper: design

The agreed behaviour is in [features/](features/), and the rulings behind it
are in [decisions.md](decisions.md). This document says how the atServer
delivers that behaviour. A section marked **proposed** is not yet agreed;
[open-questions.md](open-questions.md) lists the forks still to settle.

## 1. One gatekeeper, consulted by every exchange

**Proposed.** A single `Gatekeeper` in `at_secondary_server` (`lib/src/gate/`)
owns the gate's state and answers one question for every exchange: given this
atSign, this key or namespace, this direction and this kind of exchange, is it
admitted, quarantined (and so counted and capped), or refused, and with which
refusal? Handlers never read gate state themselves. That keeps D2 to D16 in one
place, where one set of unit tests covers them, and leaves each call site one
line to get wrong.

The decision is taken from the atSign that pol authenticated
(`InboundConnectionMetadata.fromAtSign`) and never from an atSign named in the
command (`rules.feature`, `@replay`).

## 2. Where the gatekeeper is consulted

Inbound, on a pol-authenticated connection:

| Path | What it asks |
|---|---|
| `NotifyVerbHandler._handlePolAuthenticatedConnection` | admit, count and cap the notification, and suppress ttr effects when quarantined (D7.6) |
| `LookupVerbHandler._handlePolAuthConnection` | admit or count the lookup (D8), and apply D4 to `shared_key` |
| `ScanVerbHandler`, pol branch | filter entries to namespaces where the atSign is admitted (D14) |
| `NotifyListVerbHandler`, pol branch | the same filter (D14) |
| `StreamVerbHandler`, `init` | refuse a stream from an atSign not admitted (D8), or with no namespace (D4) |

Outbound, on @alice's own behalf:

| Path | What it asks |
|---|---|
| `NotifyVerbHandler._handleAuthenticatedConnection` | refuse before queueing (D9.4) |
| `AbstractUpdateVerbHandler` and `DeleteVerbHandler` auto-notify | refuse locally, so nothing is queued (D13) |
| `NotifyAllVerbHandler`, and the stream's notification | the same, per recipient |
| `PerAtSignNotifSender.send` | check again at each delivery attempt (D12), and on a gate refusal from the recipient, mark the notification `refused` and stop (D9.1) |
| `LookupVerbHandler`, remote branch, and `ScanVerbHandler`, remote branch | refuse before connecting, and filter a remote scan's answer (`outbound.feature`) |
| `AtCacheManager.remoteLookUp` | refuse a refresh before connecting, delete the cached copy on refusal (D12), and skip the write if admission was lost while the refresh was in flight ([section 4](#4-concurrency)) |

Never consulted: `PolVerbHandler`'s verification lookups (D1), `plookup` and
other public reads (D1), and notifications whose type is `self`.

To the owner's own clients, quarantined notifications are filtered by
`MonitorVerbHandler`, `NotifyListVerbHandler` and `NotifyFetchVerbHandler`
unless the client asks for them (D10, [section 5.4](#54-asking-for-quarantined-notifications)).

## 3. State and its records

Gate state is held in memory and written through to `local:` records in the
keystore (D17). Both commit-log backends skip `local:` keys
(`hive_at_commit_log.dart`, `sqlite_at_commit_log.dart`), so the records never
sync.

**Proposed** record layout, one record per namespace with a rule, plus three
atSign-wide records:

| Record | Holds |
|---|---|
| `local:<ns>.rule.gate@<atSign>` | mode, the admitted and denied sets, the limits (*N*, *W*, size cap) and bounds, as set by the holders |
| `local:<ns>.quarantine.gate@<atSign>` | the quarantined set, each atSign with the times of its counted exchanges in the current window, and the bytes of quarantined notifications held |
| `local:admitted.gate@<atSign>` | the atSign-wide admitted set (D3) |
| `local:default.gate@<atSign>` | `ungated` or `closed` (D11) |

The rule and its counters live in separate records, so a counted exchange
rewrites only the quarantine record, which is small because D15 bounds it.

**Guards.** On the atServer, every client verb that names a `local:` key is
refused, beside `refuseTelemetryKeyMutation` in `AbstractVerbHandler`, and
`_isPrivateKeyForAtSign` hides `local:` from scan. The verbs whose grammar
admits a `local:` key are `llookup` and `notify`, since their `atKey` allows a
colon, and `update:json`, which takes its key from the document. The plain
`update`, `update:meta` and `delete` patterns exclude a colon from the key.
`batch` hands each of its commands to that verb's own handler
(`verbHandlerManager.getVerbHandler`), so it meets the same guard. The guard
tests the key the handler finally resolves, so `update:json` meets it too.

## 4. Concurrency

Decided in D21.

- Every write to gate state, whether a counted exchange, an admission or
  denial, or a rule change, runs under one gate-wide `Mutex` in the
  `Gatekeeper` (`package:mutex`, which `NotifyVerbHandler` already uses). The
  in-memory state and its `local:` record are updated together inside it. That
  serialises the two `@race` scenarios in `quarantine.feature` and the
  concurrent admissions in `rules.feature`. No lock is held across a network
  call.
- A check that only reads takes no lock. In the atServer's single isolate, a
  synchronous read of the in-memory state cannot interleave with a write, and it
  sees the state as of the last completed one.
- A rule or set change applies from the next exchange, because every exchange
  asks the gatekeeper and nothing caches a verdict per connection
  (`rules.feature`, `@race`).
- **A cache refresh in flight** (`refusals.feature`, `@race`): each
  (namespace, atSign) pair carries a generation that a loss of admission
  increments. `AtCacheManager.remoteLookUp` reads the generation before it
  connects, and writes the refreshed copy only if the generation is unchanged,
  checking and writing under the mutex.
- **A queued notification** is checked again by `PerAtSignNotifSender.send` at
  each attempt (D12). An admission lost between the check and the write to the
  socket can let one notification through. That window is the length of one
  send, and it is accepted.
- Whether the mutex should split per namespace is for the bench ([section 9](#9-performance)) to show.

## 5. Wire changes

### 5.1 The gate verb

A new verb, `gate:` (D19), with the grammar `rules.feature` gives. The verb is accepted only on a connection the owner
authenticated (PKAM or CRAM), and its authorisation is D5's: `rw` on the
namespace to change it, `r` to read it, and a root enrollment for the default
and the atSign-wide admitted set.

### 5.2 Error codes

**Proposed**, as three exceptions in at_commons' `error_codes`, after AT0032,
the highest code in use:

| Code | Exception | Meaning |
|---|---|---|
| AT0033 | `NotAcceptedException` | closed namespace, not admitted, denied, or namespace-less off D4's list |
| AT0034 | `QuarantineLimitException` | the window's *N*, or either D15 bound, is reached |
| AT0035 | `QuarantineSizeException` | the command exceeds the size cap |

A sending atServer treats exactly these three as final (D9.1). Every other error
keeps today's retry.

### 5.3 Notification status

`NotificationStatus` gains `refused` (D9.1), which `notify:status` answers.

### 5.4 Asking for quarantined notifications

**Proposed**, by the precedent of monitor's `strict`, `selfNotifications` and
`multiplexed` flags. `monitor` gains a `:quarantined` flag, and so do
`notify:list` and `notify:fetch`. Without it, a quarantined notification is
left out, or for `notify:fetch` answered as for no such notification
(`quarantine.feature`). The flag widens what is returned only within the
namespaces the enrollment may already read.

### 5.5 Advertising the gate

**Proposed**, by the precedent of `InfoFeature.notifyEph` and
`InfoFeature.notifyEAtn`. `info` lists a `gate` feature, so a client can tell
whether its atServer enforces the gate before it sets rules.

### 5.6 The notification mark

Monitor, `notify:list` and `notify:fetch` carry `"quarantined": true` on a
marked notification (D10), through `mapForClient` and `AtNotification.toJson`.
An unmarked notification carries no new field.

## 6. At-rest changes

| Store | Change | An older atServer reading it |
|---|---|---|
| Hive `AtNotificationAdapter` | field 18, `quarantined`, written only when true | ignores field 18, so a marked notification reads as unmarked |
| Hive `NotificationStatusAdapter` | byte 4, `refused`, in `read` and in `write` | its `read` answers `null` for byte 4 |
| SQLite notification codec | `quarantined` in the JSON payload; `refused` in the `status` column by name | its `_enum` decoder answers `null` for a name it does not know |
| keystore | the `local:` gate records ([section 3](#3-state-and-its-records)) | never reads them, so a downgrade drops the gate and keeps the records |

**Note:** `NotificationStatusAdapter.write` writes nothing at all for a status
it has no case for. Adding `refused` without a `write` case would corrupt every
record holding it, so the change pins the byte with a raw-literal test.

## 7. Compatibility and rollout

- **Senders** (D18): every atServer implementation ships [section 5.2](#52-error-codes)'s final
  refusals, and D9.1's `refused` status, no later than it enforces the gate.
- **The default** (D11): `ungated` for existing atSigns. The operator's setting
  for new atSigns is a new configuration item, `ungated` at first.
- **Clients**: at_client gains the gate API, the `:quarantined` flag and the
  `refused` status. A released client sees no change until a rule binds it.
  Then its notify can be answered with AT0033. `AtExceptionUtils.get`
  turns a code it does not know into a plain `AtException` carrying the
  description (read on at_commons trunk, not on each released version).
- **Every atServer implementation** carries the same verb, codes, status and
  flags. at_commons carries the grammar and the error codes.

## 8. Bounds

D7 and D15 settle what is bounded and how, and D20 the operator's defaults and
limits, the cap on open namespaces per atSign and the atSign-wide total of
quarantined bytes. The operator's values are configuration items beside the
existing notification settings in `AtSecondaryConfig`.

## 9. Performance

**Proposed.** The gatekeeper adds a check to every exchange between atSigns.
The claim that it costs no storage read ([section 3](#3-state-and-its-records)) is a hypothesis until it is
measured. Before the gate is built, a bench measures notify and lookup
throughput between two atServers, and it runs again with the gate in place.

## 10. Tests

Decided in D22. Each scenario's proving test takes the scenario's title,
character for character; each row of an outline is one test under the
outline's title.

| Layer | Proves |
|---|---|
| Unit, `at_secondary_server/test/gate/` | the `Gatekeeper` decision table, and every scenario whose observable is one atServer's answers, with doubles for the other side: all of `rules.feature`; `namespace_less.feature` except "Authentication is never gated"; all of `quarantine.feature`, the restart scenario by reopening the store; `outbound.feature`'s refusals before connecting, through a recording outbound-client double; `refusals.feature`'s recipient side, D12's deletions, the queued re-check, the refresh race and the `@dos` retry |
| Unit, `at_persistence_secondary_server/test` | raw-literal pins for Hive field 18 and status byte 4, and for the SQLite payload key and status name; the commit-log skip of `local:` on both backends; a downgrade read of each |
| Functional pack, `tests/at_functional_test` | the scenarios that need two real atServers: the sender's discard and `refused` status, the invitation flow, D10's marking through monitor, D13, D12's refused refresh deleting the holder's copy, and "Authentication is never gated" |
| e2e pack, `tests/at_end2end_test` | the same cross-atServer subset, across separate hosts in CI |
| Onboarding-CLI pack | no scenario of its own; it runs before the PR, because the keystore and notification storage change |

D18's tail, an older atServer retrying a refusal, is proven on the
recipient's side only, by a unit test with a retrying double. No pack runs a
released atServer against the branch.
