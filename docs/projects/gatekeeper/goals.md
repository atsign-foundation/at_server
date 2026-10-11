# Gatekeeper: goals

The rulings are in [decisions.md](decisions.md), the agreed scenarios in
[features/](features/), and what is still open in
[open-questions.md](open-questions.md).

## The goal

An atSign's owner controls, at the atServer, which other atSigns may
communicate with that atSign. The control is per namespace and applies in both
directions: it governs what @bob and @chuck may exchange with @alice, and what
@alice may exchange with them.

Once it works, the default becomes fail-closed, so that a badly written
application can reach only the atSigns its owner has admitted. The gate is
there to limit how far such an application's mistakes can spread.

## Requirements as stated

- **R1 Per-namespace rules.** For a set of namespaces an owner can say either
  "anyone may communicate here" or "only these atSigns may communicate here".
- **R2 Both directions.** A rule binds @alice's own outbound traffic as well as
  inbound traffic from other atSigns.
- **R3 Quarantine.** In a namespace open to anyone, an atSign that has not been
  seen before is marked as quarantined, and stays so until a client takes it
  out of quarantine.
- **R4 Quarantined notifications.** Notifications from a quarantined atSign are
  accepted, with four limits:
  1. nothing is stored on the recipient's atServer through `ttr`; only the
     notification itself is kept;
  2. after a client-settable number of notifications (default 10), further
     ones are refused;
  3. a notification's payload is capped at a client-settable size (default
     15 KB);
  4. a sending atServer whose notification is refused for a quarantine reason
     discards it at once and never retries it.
- **R5 Owner control.** The atSign's owner sets the rules, through clients.
- **R6 Fail-closed default.** The end state refuses by default.

## Out of scope

- **Public data.** `plookup` reads of `public:` keys stay outside the gate
  (decision D1).
- **Values.** The gate decides on what the atServer can see in plaintext: the
  other atSign and the atKey's namespace. Values are end-to-end encrypted, and
  the atServer never holds the keys to read them.

## How the atServer behaves now

What follows was read at at_server trunk `7f003a6a` on 2026-10-10.

- **The only control is atSign-wide.** `config:block:add`, `config:block:remove`
  and `config:block:show` maintain a set of atSigns stored at
  `private:blocklist@<atSign>`, which is written with `skipCommit`, so it is not
  synced to clients. Only a root-privileged connection may use them. The set is
  consulted in one place, `FromVerbHandler`: a listed atSign's `from:` is
  refused with `BlockedConnectionException` (AT0013) and the connection is
  closed. Nothing consults it on the way out, so @alice's atServer still
  delivers notifications to a blocked atSign and looks up its keys.
- **Inbound exchanges.** The verb handlers that branch on a pol-authenticated
  connection are lookup, scan, notify, notify:list and stream. Stream cannot be
  reached on any wire connection: `ConnectionUtil.validate` refuses it as an
  invalid verb, since `at_server_spec`'s `AtVerb` does not list it.
- **Outbound exchanges.** For its own clients, @alice's atServer delivers
  notifications, looks up and scans another atSign's keys, and proxies
  `plookup` through `OutboundClientManager`. It also does work of its own:
  `AtCacheRefreshJob` refreshes cached keys by remote lookup, and
  `PolVerbHandler` connects out to the claimed atSign to check its signed
  challenge. That check is part of authentication and is never gated.
- **Auto-notify.** An update or delete of a key shared with another atSign
  sends that atSign a notification (`autoNotify`, on by default), from
  `AbstractUpdateVerbHandler` and `DeleteVerbHandler`.
- **Caching through ttr.** A notification that carries a `ttr` and a value
  makes the recipient store `cached:<notification key>`. A delete notification
  removes the cached key when `ccd` was set.
- **Delivery retries.** `PerAtSignNotifSender.send` delivers to one recipient
  atSign one notification at a time. It stops on `data:success`, on expiry, or
  when the recipient atSign is no longer in the directory, and retries
  everything else, an error response included. The backoff grows from 200 ms
  by a factor of φ up to 10 s. A notification lives 15 minutes by default
  (`notificationExpiryInMins`) and at most 8 days (`AtNotification.maxTtl`).
  So a refusal today brings a retry every 10 s until the notification expires,
  and the sender's later notifications to the same atSign wait behind it.
- **Notify is serialised.** There is one `NotifyVerbHandler`, and its
  `processNotificationMutex` serialises every notify the atServer processes.
- **Namespace matching for enrollments.** An enrolled namespace covers a key
  when `.<key namespace>` ends with `.<enrolled namespace>`, so `chat` covers
  `x.chat` and `group.chat`. Keys with no namespace are decided separately
  (`_decideRootKey`).
- **Error codes** live in at_commons' `error_codes` map, in at_client_sdk.

## Where the change lands

Every atServer implementation, at_commons (verb grammar and error codes),
at_client (the owner's API), and any SDK that sends notifications and needs to
recognise the new refusals.
