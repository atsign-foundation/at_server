# Gatekeeper: decisions

The ledger of rulings. Each entry gives the ruling and the reason for it. A
ruling that is later changed is amended here in place, saying what it used to
say.

## D1 The gate governs every atSign-to-atSign exchange, in both directions

*2026-10-10, gkc.*

Inbound, it covers notify, lookup, scan, notify:list and stream on a
pol-authenticated connection. Outbound, @alice's atServer applies @alice's
rules to notification delivery (explicit notifies and auto-notify), remote
lookup and scan, and cache refresh. Public data (`plookup`) stays outside the
gate.

**Why:** a badly written application that shares a key with the wrong atSign
exposes it through lookup, not notify. Gating notifications alone would leave
that path open.

## D2 A namespace is open or closed, and an open one can deny

*2026-10-10, gkc.*

- An **open** namespace holds three sets of atSigns: admitted, quarantined and
  denied. An atSign in none of them is quarantined on first contact. A client
  reviewing a quarantined atSign admits it or denies it, in that namespace
  only.
- A **closed** namespace holds only an admitted set, and refuses every other
  atSign.
- The atSign-wide blocklist (`config:block`) stays as it is, checked at
  `from:`, and overrides every namespace.

**Why:** a refusal can then be confined to one namespace, where today the only
refusal is atSign-wide and needs a root connection. The blocklist stays because it
is the cheapest refusal there is: it comes before pol, and so before the
outbound connection that verifies the caller.

## D3 Sets are per namespace, plus one atSign-wide admitted set

*2026-10-10, gkc.*

- Each namespace's admitted, quarantined and denied sets are its own, so
  admitting @bob in `chat` admits nothing in `photos`.
- One atSign-wide admitted set sits beside them. An atSign in it is admitted in
  every **open** namespace, and in no closed one. Changing it needs a root
  connection.

**Why:** an application touches only the sets of the namespaces it holds,
while the owner can still admit a trusted atSign everywhere open with one
decision instead of one per application.

## D4 A short list of namespace-less exchanges follows admission anywhere

*2026-10-10, gkc; narrowed the same day under Q18.*

These exchanges with no namespace are permitted if and only if the other
atSign is admitted somewhere, in some namespace's admitted set or in the
atSign-wide admitted set:

- a lookup of `shared_key` in any form, in either direction, including
  `AtCacheRefreshJob`'s `lookup:all:shared_key@<them>`;
- update and delete notifications of the legacy copy `@<them>:shared_key@<me>`;
- text notifications, until they are retired.

Every other exchange with no namespace is refused once the gate applies. That
covers namespace-less keys other than `shared_key`, and streams with no
namespace. Being quarantined somewhere does not count as admitted. The
atSign-wide blocklist still overrides everything.

As first ruled, D4 permitted *every* exchange with no namespace on the same
condition. Q18 narrowed it, because under D5 an application holding only
`chat` could otherwise widen all of an atSign's namespace-less traffic by
admitting it in `chat`.

**Why:** these exchanges belong to no one namespace, so they follow the pair's
standing instead of a rule of their own, and there is nothing extra for the
owner to configure. The legacy shared-key notification is on the list because
refusing it between admitted atSigns would make a released sender retry it for
its 15-minute life on every first share, holding the pair's next notifications
behind it. Text notifications are being retired.

**Consequences, read from the code and not yet run:**

- A current client sharing with an atSign for the first time writes the legacy
  `@<them>:shared_key@<me>` copy with a `ttr`, and auto-notify queues it ahead
  of the data notification. When the recipient holds the sender in quarantine,
  that notification is refused. A sender that discards refusals at once (R4.4)
  loses nothing. A released sender retries it for its 15-minute life, and
  `PerAtSignNotifSender` holds the notification behind it until then (Q14).
- A quarantined atSign's notification without `sharedKeyEnc` cannot be
  decrypted, because the recipient's fallback `lookup:shared_key@<sender>` is
  refused on the way out. Current clients always send `sharedKeyEnc`.

## P1 Namespace matching follows enrollments

*By precedent; confirmed by gkc on 2026-10-10 when agreeing `features/rules.feature`.*

A rule on `chat` covers `x.chat` and `group.chat`, by the same suffix match
enrollments use: `.<key namespace>` ends with `.<rule namespace>`. Where rules
exist for both `chat` and `group.chat`, the more specific decides.

## D5 A namespace's holders manage its gate in full

*2026-10-10, gkc.*

An enrollment with `rw` on a namespace may set that namespace's mode (open or
closed) and its quarantine limits, and may admit or deny atSigns in it. One
with `r` may read its rule and sets. No enrollment may touch the gate of a
namespace it does not hold. The atSign-wide admitted set needs a root
connection (D3).

**Consequences:** by P1, `rw` on `chat` also manages a rule on `group.chat`,
and `rw` on `group.chat` does not manage `chat`. An enrollment holding `*`
manages every namespace's gate.

## D6 Sending never changes an atSign's standing

*2026-10-10, gkc.*

On the way out, @alice's atServer applies @alice's rules as follows:

- in an **open** namespace, it reaches any atSign not denied there, whether
  admitted, quarantined, or in none of the sets;
- in a **closed** namespace, it reaches only atSigns admitted there;
- nothing @alice sends, looks up or scans moves an atSign between sets. An
  atSign @alice contacts first, and whose replies should arrive unquarantined,
  is admitted explicitly by the application (D5).

**Why:** it is the simpler model, and it leaves admission to the application
as a deliberate act. Making a send admit the recipient was considered and
dropped. It would have needed three guards: admit only an atSign in none of the
sets, so that declining a quarantined invitation does not admit its sender;
admit only on delivery, so that a refused send admits nothing; and admit only
on a notification, never on a lookup. Even with the guards, it would have
widened D4 with no admit call at all.

**Example:** with `chat` closed and `invitations.chat` open on both atServers,
@alice invites @dave in `invitations.chat`, @dave's reply arrives in
quarantine, and accepting means the chat application admits @dave in `chat`.

## D7 Quarantine limits

*2026-10-10, gkc.*

1. Limits are counted per namespace and atSign. An atSign quarantined in two
   open namespaces has two counters.
2. The count is over a rolling window: at most *N* notifications accepted in
   any window of *W*. The defaults are *N* = 10 (R4.2) and *W* = 24 hours.
   Removing notifications does not free a place in the window. Admitting or
   denying the atSign ends the counting.
3. Each notification the atServer accepts counts, whether it is stored or, with
   `eph`, held in memory, and so does each read the gate lets through (D8). A
   refused exchange does not count, and neither does a repeated notification id
   or a notification already expired on arrival, both of which the atServer
   answers `data:success` without storing. (As first ruled, only notifications
   counted. D8 added reads.)
4. The size cap measures the whole notify command as received: key, value and
   metadata. The default is 15 KB = 15,360 bytes (R4.3).
5. *N*, *W* and the size cap are set per open namespace by its holders (D5).
   Whether the operator bounds them is Q13.
6. A quarantined notification never creates a cached key, and a quarantined
   delete never removes one (R4.1).

**Why:** a rolling window lets a quarantined atSign that keeps to the limit
keep reaching @alice, slowly, without its earlier notifications counting
against it for ever. Measuring the whole command stops metadata such as
`appMetadata` carrying what the value may not. *W* = 24 hours was the example
the question gave; gkc confirmed it on 2026-10-10 when agreeing
`features/quarantine.feature`.

## D8 An atSign not admitted may read in an open namespace, and each read counts

*2026-10-10, gkc.*

- In an open namespace, an atSign that is not admitted, whether quarantined or
  in none of the sets, may look up what @alice shares with it there. Each such
  lookup that the gate lets through counts toward D7's window, as a
  notification does, whatever the answer: a value, or key not found. (As first
  ruled, scan and notify:list were allowed and counted too. D14 narrowed them
  to admitted namespaces.)
- So the first inbound exchange of any kind from an atSign in none of the sets
  makes it quarantined in that namespace, because counting needs a counter.
- A stream from an atSign that is not admitted is refused.

**Why:** reads are what a badly written application's mistaken shares are
exposed through (D1), so a sender that is not admitted pays for them out of the
same small allowance as its notifications.

That a lookup quarantines an atSign in none of the sets follows from the
ruling. That streams are refused came from the recommended option the ruling
did not pick. gkc confirmed both on 2026-10-10 when agreeing
`features/quarantine.feature`.

## D9 Every gate refusal is final, and says which of three it is

*2026-10-10, gkc.*

1. A sending atServer whose exchange the gate refuses stops at once and never
   retries it. A refused notification takes a new status, `refused`, beside
   `delivered`, `errored`, `queued` and `expired`, and the sending client reads
   it with `notify:status`. A refusal does not hold back the sender's next
   notification to the same atSign.
2. There are three refusals, each with its own error code:
   - **not accepted:** a closed namespace, an atSign not admitted or denied, or
     a namespace-less exchange outside D4. One code covers all of these, so a
     sender cannot tell being denied from a namespace being closed;
   - **quarantine limit reached** (D7);
   - **too large for quarantine** (D7).
3. A refusal answers the one command and leaves the connection open, unlike
   the blocklist's AT0013, which closes it.
4. When @alice's atServer refuses @alice's own outbound notify, it answers the
   client's notify command with *not accepted* and queues nothing.

**Why:** R4.4 names only quarantine refusals, but retrying any gate refusal
achieves something only if the recipient changes its rules during the
notification's life. Meanwhile it costs a retry every 10 seconds, and holds
back every later notification to the same atSign.

## D10 Quarantined notifications are marked, and reach only clients that ask

*2026-10-10, gkc.*

- A notification accepted from an atSign quarantined in its namespace is stored
  marked `"quarantined": true`. The mark records the sender's standing at
  acceptance, so admitting the sender later does not rewrite it.
- Monitor, `notify:list` and `notify:fetch` return a marked notification only
  to a client that asks for quarantined notifications. A client that does not
  ask, released clients included, never sees one.

**Why:** a client that knows nothing of quarantine treats whatever it is given
as ordinary, so delivering quarantined notifications to it would let unknown
senders straight into the application the gate exists to protect. How a client
asks is a design question.

## D11 A per-atSign default, ungated until the owner closes it

*2026-10-10, gkc.*

- An atSign's **default** decides every namespace that has no rule. It is
  either `ungated`, which is today's behaviour with namespace-less traffic
  included, or `closed`, which is the target: such namespaces are closed in
  both directions, and namespace-less traffic follows D4.
- A rule binds from the moment an application sets it, whatever the default.
- Only a root connection switches its atSign's default, either way.
- The atServer operator configures the default a new atSign starts with:
  `ungated` at first, and `closed` once applications are ready.
- Setting a rule admits only the atSigns the application names, in the same
  command. The atServer infers nobody from keys already shared.

**Why:** released applications keep working until their owners close their
atSigns, and each application claims its namespaces when it is ready. The
default reaches every namespace no application has claimed, so changing it is
atSign-wide, like the blocklist and the atSign-wide admitted set. Seeding the
admitted set from keys already shared was considered and dropped: a badly
written application that shared with the wrong atSigns would get them
admitted.

## D12 Losing admission removes cached copies; stored data stays

*2026-10-10, gkc.*

An atSign loses admission in a namespace when it is removed from the admitted
set, when it is denied, when an open namespace is closed, when the owner
switches the default to `closed`, or when it is added to the blocklist. Then:

- keys @alice shared with it, and notifications already stored from it, stay;
- @alice's atServer deletes its cached copies of that atSign's keys in the
  namespace, and stops refreshing them. Switching the default to `closed`
  therefore removes every cached key in a namespace without a rule, whoever it
  came from, since such a namespace is then closed to all, and every cached
  namespace-less key except the `shared_key` copies of atSigns admitted
  somewhere (D4). (As first written, this said "in every namespace without a
  rule, from atSigns admitted nowhere", which mixed up D4's condition with a
  closed namespace's.);
- a notification already queued for that atSign is checked again at delivery,
  and refused (`refused`, D9) if the atSign is no longer admitted;
- a gated atServer whose cache refresh gets *not accepted* deletes its cached
  copy, as it does today for *key not found*.

**Why:** a cache is a standing exchange, so it ends when the exchange is no
longer allowed, and a copy can be fetched again on readmission. A refused
refresh is the only way @alice's withdrawal reaches the other side's copy,
since @alice's atServer can no longer send to that atSign. Keys and
notifications already held are @alice's own data and history, which the gate
does not govern.

## D13 A key shared with a refused atSign is stored; only its exchanges are refused

*2026-10-10, gkc.*

When @alice's client writes a key shared with an atSign that the key's
namespace would refuse, @alice's atServer stores it and answers with a commit
id as usual. Its auto-notify is refused locally and never queued (D9). The key
becomes reachable if the atSign is admitted later.

**Why:** the gate governs exchanges, not what @alice stores (D12). Clients are
local-first, so such a write reaches the atServer by sync, and on at_client_sdk
trunk `_pushFromSyncQueue` leaves a refused entry in the sync queue and retries
it every round. Refusing the write would leave every such client retrying it
for ever. Released client versions have not been checked.

## D14 Scan and notify:list answer only admitted namespaces

*2026-10-10, gkc.*

A `scan` or `notify:list` from another atSign answers only entries in
namespaces where that atSign is admitted, and counts toward no window. An
atSign that is not admitted reads an open namespace by lookup only (D8). A scan
from an atSign admitted nowhere answers `[]`.

**Why:** an atSign that is not admitted has no need to discover anything, since
its application already knows the key names it was invited to read. It also
means one command never has to be counted across several namespaces' windows.

## D15 Quarantine bounds, set by the namespace's holders under operator ceilings

*2026-10-10, gkc.*

- Each open namespace has two bounds: how many atSigns it holds in quarantine,
  and how many bytes of quarantined notifications it holds. Its holders set
  them (D5), up to a ceiling the atServer operator sets, and the operator also
  sets the default for a namespace whose holders set none.
- At either bound, a further quarantined notification is refused with the
  quarantine-limit error. Nothing already held is evicted.
- A quarantined atSign with nothing counted in the last *W* (D7) drops back to
  none, freeing its place.
- Bounds are per namespace, so filling one namespace's quarantine leaves the
  others alone.

**Why:** D7 bounds each atSign, but not how many atSigns there are. Refusing,
rather than evicting, means nothing already held is lost silently, and the
sender learns of it (D9). The holders know their application's traffic, and the
operator's ceilings keep any one application from claiming the atServer.

That operator ceilings also bound D7's *N*, *W* and size cap (Q13 asked, and
this ruling implies it), and that a value set above its ceiling is refused
rather than clamped: gkc confirmed both on 2026-10-10 when agreeing
`features/quarantine.feature`.

## D16 A namespace's deny overrides the atSign-wide admitted set

*2026-10-10, gkc.*

An atSign denied in an open namespace is refused there, even when it is in the
atSign-wide admitted set.

**Why:** the namespace's deny is the more specific decision, as with P1, and it
lets an application refuse a trusted atSign in its own namespace. The owner can
still undo the deny from a root connection, which holds `*`.
