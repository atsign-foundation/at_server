# Gatekeeper: decisions

The ledger of rulings. Each entry gives the ruling and the reason for it. A
ruling that is later changed is amended here in place, saying what it used to
say.

## D1 The gate governs every atSign-to-atSign exchange, in both directions

*2026-10-10, gkc.*

Inbound, it covers notify, lookup, scan and notify:list on a
pol-authenticated connection. (As first ruled, this included stream. No wire
connection can reach the stream verb, which `ConnectionUtil.validate` refuses
as an invalid verb, and stream is being deprecated, so gkc took it out of scope
on 2026-10-10.) Outbound, @alice's atServer applies @alice's
rules to notification delivery (explicit notifies and auto-notify), remote
lookup and scan, and cache refresh. Public data (`plookup`) stays outside the
gate.

**Why:** a badly written application that shares a key with the wrong atSign
exposes it through lookup, not notify. Gating notifications alone would leave
that path open.

## D2 A namespace is open or closed, and an open one can deny

*2026-10-10, gkc; amended 2026-10-11 under Q24.*

- An **open** namespace holds three sets of atSigns: admitted, quarantined and
  denied. An atSign in none of them is quarantined on first contact. A client
  reviewing a quarantined atSign admits it or denies it, in that namespace
  only.
- A **closed** namespace admits only its admitted set, and refuses every other
  atSign. It keeps the denied set it had while open, ignored while it is closed
  and back in force when it reopens (D24). As first ruled, a closed namespace
  held only an admitted set, and closing dropped the denied set.
- The atSign-wide blocklist (`config:block`) stays as it is, checked at
  `from:`, and overrides every namespace.

**Why:** a refusal can then be confined to one namespace, where today the only
refusal is atSign-wide and needs a root connection. The blocklist stays because it
is the cheapest refusal there is: it comes before pol, and so before the
outbound connection that verifies the caller.

## D3 Sets are per namespace, plus one atSign-wide admitted set

*2026-10-10, gkc; amended 2026-10-11 (D26).*

- Each namespace's admitted, quarantined and denied sets are its own, so
  admitting @bob in `chat` admits nothing in `photos`.
- One atSign-wide admitted set sits beside them. An atSign in it is admitted in
  every **open** namespace and wherever the closed default decides, and in no
  closed one. Changing it needs a root connection. As first ruled, it reached
  open namespaces only.

**Why:** an application touches only the sets of the namespaces it holds,
while the owner can still admit a trusted atSign everywhere open with one
decision instead of one per application.

## D4 A short list of namespace-less exchanges follows admission anywhere

*2026-10-10, gkc; narrowed the same day under Q18; amended 2026-10-11 (D26).*

These exchanges with no namespace are permitted if and only if the other
atSign is admitted somewhere the admission takes effect: in the admitted set
of a namespace with a rule, among the admissions recorded on a namespace no
rule covers, or in the atSign-wide admitted set. Admissions recorded beneath a
rule, which the rule overrides, do not count:

- a lookup of `shared_key` in any form, in either direction, including
  `AtCacheRefreshJob`'s `lookup:all:shared_key@<them>`;
- update and delete notifications of the legacy copy `@<them>:shared_key@<me>`;
- text notifications, until they are retired.

Every other exchange with no namespace is refused once the gate applies. That
covers namespace-less keys other than `shared_key`. (Streams with no
namespace were listed here too, until stream left the gate's scope; see D1.)
Being quarantined somewhere does not count as admitted. The
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
  `PerAtSignNotifSender` holds the notification behind it until then (D18).
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
   The operator's bounds on them are D20.
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
- (As first ruled, a stream from an atSign that is not admitted was refused
  here. Stream has since left the gate's scope; see D1.)

**Why:** reads are what a badly written application's mistaken shares are
exposed through (D1), so a sender that is not admitted pays for them out of the
same small allowance as its notifications.

That a lookup quarantines an atSign in none of the sets follows from the
ruling, and gkc confirmed it on 2026-10-10 when agreeing
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

*2026-10-10, gkc; amended 2026-10-11 under Q25 and Q31, and by D26.*

- An atSign's **default** decides every namespace that has no rule. It is
  either `ungated`, which is today's behaviour with namespace-less traffic
  included, or `closed`, which is the target: such namespaces are closed in
  both directions, admitting only the atSigns recorded on them or on a
  namespace above them (D25) and the atSign-wide admitted set (D26), and
  namespace-less traffic follows D4. As first ruled, they were closed to all.
- Any authenticated enrollment may read the default (D26).
- A rule binds from the moment an application sets it, whatever the default.
- Only a root connection switches its atSign's default, either way.
- The atServer operator configures the default a new atSign starts with:
  `ungated` at first, and `closed` once applications are ready.
- Setting a rule admits only the atSigns the application names, in the same
  command or recorded there before (D24). The atServer infers nobody from keys
  already shared.

**Why:** released applications keep working until their owners close their
atSigns, and each application claims its namespaces when it is ready. The
default reaches every namespace no application has claimed, so changing it is
atSign-wide, like the blocklist and the atSign-wide admitted set. Seeding the
admitted set from keys already shared was considered and dropped: a badly
written application that shared with the wrong atSigns would get them
admitted.

## D12 Losing admission removes cached copies; stored data stays

*2026-10-10, gkc; amended 2026-10-11 (D26).*

An atSign loses admission in a namespace when it is removed from the admitted
set or the atSign-wide admitted set, when it is denied, when an open namespace
is closed, when a rule set on a namespace or removed from one leaves it no
longer able to reach it, when the owner switches the default to `closed`, or
when it is added to the blocklist. Then:

- keys @alice shared with it, and notifications already stored from it, stay;
- @alice's atServer deletes its cached copies of that atSign's keys in the
  namespace, and stops refreshing them. Switching the default to `closed`
  therefore removes every cached key in a namespace no rule covers, except
  those of the atSigns recorded on it or above it (D25) and of the atSign-wide
  admitted set (D26), since such a namespace then admits only those, and every
  cached namespace-less key except the `shared_key` copies of atSigns admitted
  somewhere (D4). (As first written, this said "in every namespace without a
  rule, from atSigns admitted nowhere", which mixed up D4's condition with a
  closed namespace's. Until D24, it said such a namespace was closed to all.);
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

*2026-10-10, gkc; amended 2026-10-11 by D28.*

- Each open namespace has two bounds: how many atSigns it holds in quarantine,
  and how many bytes of quarantined notifications it has accepted in the last
  *W* (D28; as first ruled, the bytes it holds). Its holders set
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

That the operator also bounds D7's *N*, *W* and size cap (Q13 asked, and this
ruling implies it), and that a value set beyond its bound is refused rather
than clamped: gkc confirmed both on 2026-10-10 when agreeing
`features/quarantine.feature`. For *W* the protective bound is a floor, not a
ceiling, because a longer window is stricter. (As first written, this said
"operator ceilings also bound D7's *N*, *W* and size cap".)

## D16 A namespace's deny overrides the atSign-wide admitted set

*2026-10-10, gkc.*

An atSign denied in an open namespace is refused there, even when it is in the
atSign-wide admitted set.

**Why:** the namespace's deny is the more specific decision, as with P1, and it
lets an application refuse a trusted atSign in its own namespace. The owner can
still undo the deny from a root connection, which holds `*`.

## D17 Gate state is server-only, in `local:` records

*2026-10-10, gkc. Design.*

Rules, the admitted, denied and quarantined sets, the atSign-wide admitted set,
the default and the window counters are `local:` records in the atServer's
keystore. Both commit-log backends already skip `local:` keys, so these records
never enter the commit log and never sync, with no flag to remember. On the
atServer, `local:` means the atServer's own records: it refuses every client
verb that names a `local:` key, and scan hides them. The gate verb is the only
way to read or change gate state. The atServer holds it in memory and writes
through, so checking an exchange reads no storage, and a counted exchange costs
one write.

As first ruled, these were records in a reserved namespace, written with
`skipCommit` as the blocklist is. `local:` replaced that the same day.

**Why:** a record that synced could be edited in a client's local store and
pushed, and refusing that push leaves the client retrying it every sync round
(D13). No atServer code and no client writes `local:` keys on the atServer
today, so a blanket refusal breaks nothing, and the prefix already means "stays
in this store" on a client. The atServer's existing reserved namespace,
`__atserver`, was considered and not chosen: every enrollment reads it, and its
event records sync, which is the opposite of what this state needs.

**Gaps the change closes:** scan's hidden-key filter (`_isPrivateKeyForAtSign`)
does not hide `local:`, and `llookup`'s grammar accepts a `local:` key. [design.md,
section 3](design.md#3-state-and-its-records) lists the verbs that can name one.

## D18 Senders learn to discard refusals no later than the gate ships

*2026-10-10, gkc. Design.*

Every atServer implementation ships the sending side of D9, which discards a
refused notification and marks it `refused`, in a release no later than the
one that enforces the gate. An atServer still on an older release retries a
refusal every 10 seconds until the notification expires (15 minutes by
default, 8 days at most), holding back its own later notifications to that
recipient. The recipient answers each retry with one rule check and stores
nothing.

**Why:** nothing is refused until an application sets a rule or an owner
switches to `closed` (D11), and both need client releases, so by then senders
have had the change for at least one release. Answering older senders with
`data:success` and dropping the notification was considered and rejected: they
would record as delivered notifications that never were.

## D19 The gate verb is `gate:`

*2026-10-10, gkc. Design.*

The gate is managed through a new verb, `gate:`, with its own handler and its
grammar in at_commons. `config` is left as it is.

**Why:** the verb gets one authorisation regime, D5's, instead of a third one
inside `config`, which already mixes the blocklist with runtime settings and
answers `config:print` on any connection. The name is short, it matches the
project's vocabulary, and no protocol verb uses it. (at_client's
`PqStartupGates` is an unrelated identifier.)

## D20 Bound values, and two atSign-wide caps

*2026-10-10, gkc. Design. Amended 2026-10-11 by D28.*

Per open namespace, the operator's defaults and limits are:

| Setting | Default | Operator limit |
|---|---|---|
| *N*, exchanges per window | 10 | at most 100 |
| *W*, the window | 24 hours | at least 1 hour |
| size cap | 15,360 bytes | at most 65,536 bytes |
| quarantined atSigns | 100 | at most 1,000 |
| quarantined bytes accepted in the window | 1 MiB | at most 16 MiB |

Across namespaces, the operator also sets:

- a cap on how many open namespaces one atSign may have, 50 by default;
- an atSign-wide total of quarantined bytes accepted in the window (D28; as
  first ruled, held), 64 MiB by default, which
  refuses further quarantined notifications with the quarantine-limit error
  once reached.

**Why:** the per-namespace bounds alone multiply with every namespace an
application opens, and D5 lets it open as many as it holds. The namespace cap
stops that growth, and the total bounds storage outright. The total gives up
part of D15's isolation, because one namespace can fill it.

*Spec consequence:* both caps are new refusals, so their scenarios are added to
the spec; gkc agreed them the same day.

## D21 One gate-wide mutex for writes; reads take no lock

*2026-10-10, gkc. Design.*

Every write to gate state runs under one mutex in the gatekeeper, which updates
the in-memory state and its `local:` record together. Checks that only read take
no lock. No lock is held across a network call.

**Why:** in the atServer's single isolate a synchronous read cannot interleave
with a write, so only writes need serialising, and notify, the bulk of
quarantined traffic, is already serialised by `NotifyVerbHandler`. One mutex
per namespace was considered. Whether to split is for the bench to show, rather
than a guess about performance made before anything is measured.

## D22 Which layer proves which scenario

*2026-10-10, gkc. Design.*

Unit tests in `at_secondary_server` prove every scenario whose observable is
one atServer's answers, with doubles for the other side. Unit tests in
`at_persistence_secondary_server` pin the at-rest changes as raw literals. The
functional and e2e packs prove the scenarios that need two real atServers. All
three live packs run before the PR. The table is in [design.md, section 10](design.md#10-tests).

**Why:** most of the spec is one atServer's answer to one command, which a unit
test proves fastest and most precisely.

*Correction, the same day:* the ruling also said that D18's tail, an older
atServer retrying a refusal, is proven on the recipient's side only, since no
pack runs a released atServer against the branch. That premise was false. In
CI, `end2end_test_34` pairs @cicd3 on the branch's image with @cicd4 on
`atsigncompany/secondary:prod`, and `end2end_test_56` pairs @cicd5 on `:prod`
with @cicd6 on the branch (`tools/cicd1x64/update_image.sh`,
`tools/cicd2x64/update_image.sh`). Asked again with that corrected, gkc kept the
unit test only: an e2e test of the tail would stop meaning anything once
`:prod` itself carries D18.

## D23 A value reference resolves only into an admitted namespace

*2026-10-10, gkc.*

When a lookup from another atSign answers a value holding an `atsign://`
reference, the reference resolves only to a key in a namespace where that
atSign is admitted. A reference into any other namespace is treated as a key
that is not there, so an unresolved reference is answered null, as it is today.
Nothing is counted across namespaces (as D14). References to `public:` keys are
unchanged, since public data is outside the gate (D1).

**Why:** `resolveValueReference` looks a reference up in any namespace, so
without this an atSign admitted in one namespace could read a key shared with
it in another.

## D24 The gate verb's answers, reads and bounds

*2026-10-11, gkc. Agreed in design section 5.1, then re-opened the same day from
a review on the client API's side as Q24 to Q30, and ruled as below; amended
the same day under Q32 (D25) and by D26.*

- `gate:show:<ns>` answers `data:` and a JSON object, every key of its mode
  always present and an empty set as `[]`:
  - a namespace with a rule: its mode (`open` or `closed`), its settings in
    force (defaults included, `window` in seconds), and its sorted admitted
    and denied sets; an open one also its quarantined set, each entry with the
    exchanges `counted` in the current window, the quarantined notification
    `bytes` accepted in the window (D28) and its `firstContact` (UTC, ISO 8601, to the millisecond),
    ordered by first contact;
  - a namespace with no rule: the mode `none`, the default, and its sorted
    recorded admissions, with no settings;
  - either, when a rule on a broader namespace decides it, `governedBy` naming
    that namespace (D26).

  As first ruled, only an open namespace answered its denied set.
  `gate:default` answers the mode to any authenticated enrollment (D26), and a
  change answers `success`.
- Re-issuing `gate:rule:<ns>:open[:<setting>:<value>]` keeps the rule's sets and
  settings and changes only the setting given; `:<setting>:default` returns a
  setting to the operator's default. Closing a namespace keeps its denied set,
  ignored while it is closed and back in force when it reopens, and drops its
  quarantined set and counts. Quarantined notifications already held stay,
  marked (D10, D12).
- `admit` and `remove` record into a namespace's admitted set whether it has a
  rule or not, without creating one. The default decides how a namespace with
  no rule behaves, so under `closed` it lets in that set, the sets recorded
  above it and the atSign-wide set (D25, D26), and a rule set later starts
  from it. `deny` needs an open namespace. `gate:rule:<ns>:none` removes a rule
  (D26).
- Reads: `gate:check:<ns>:<atSign>` answers the standing that atSign has in
  that namespace now (`admitted`, `quarantined` or `notAccepted`): the gate's
  verdict alone, before the blocklist and without the quarantine limits, and
  `admitted` for the owner's own atSign (D26). It takes `r` on the namespace.
  `gate:show:*` answers the
  atSign-wide admitted set to a root connection. `gate:list` answers the
  namespaces with a rule or recorded admissions: all of them to a root
  connection, and those it holds to any other.
- Bounds, set by the operator and refused with AT0022, each with its own
  message (design section 5.2): 10,000 admitted and 10,000 denied atSigns per
  namespace, 10,000 in the atSign-wide admitted set, and 1,000 namespaces with
  a rule or recorded admissions.

**Why:** a reopened namespace must not let back in what it denied; an
application must be able to record an admission before it claims a namespace,
or switching the default to closed cuts off its contacts; an application can ask
whether an atSign reaches it in a namespace without seeing the owner's
atSign-wide trusted list; and every answer, record and set the gate keeps is
bounded.

## D25 Admissions recorded without a rule, and the closed answer

*2026-10-11, gkc. Q31 and Q32, raised while writing D24's scenarios; amended
the same day by D26.*

- Rules decide first, matched by P1 among rules alone, and an admission
  recorded in a namespace with no rule never overrides a rule covering it.
  Where no rule covers a key, the default decides: `ungated` admits as today,
  and `closed` admits an atSign recorded on any namespace that covers the key,
  by P1's suffix match, and the atSign-wide admitted set (D26). As first ruled,
  only the set recorded on the most specific such namespace counted, so that
  it behaved as the closed rule it would become.
- A closed namespace's `gate:show` answer includes its sorted denied set, kept
  for when it reopens (D24). `deny` still needs an open namespace.
- Admissions recorded in a namespace with no rule are kept in its
  `local:<ns>.rule.gate` record with the mode `none`, and the record goes when
  the last of them is removed.

**Why:** letting the most specific namespace decide, whether it holds a rule
or only admissions, would make one recorded admission ungate everything beneath
a closed rule under the ungated default. A set that comes back into force when
a namespace reopens should be readable before then.

## D26 A second review on the client API's side

*2026-10-11, gkc, taking each recommendation from a second review of D24 and
D25 on the client API's side.*

- **Recorded admissions add up.** Where no rule covers a key, the closed
  default admits an atSign recorded on any namespace covering it (D25). An
  admission only ever adds, and setting a rule is the one act that narrows: a
  rule on `invitations.chat` starts from that namespace's own recorded set, so
  an atSign recorded only on `chat` loses `invitations.chat`.
- **The atSign-wide admitted set reaches namespaces no rule covers.** It admits
  wherever the closed default decides, as well as in every open namespace, and
  never in a closed one (D3).
- **`gate:rule:<ns>:none` removes a namespace's rule**, and takes `rw` on it.
  Its admitted set stays as recorded admissions; its denied set, settings,
  quarantined set and counts go. With nothing admitted, nothing is recorded.
- **`gate:show` names what governs.** When a rule on a broader namespace
  decides `<ns>`, the answer carries `"governedBy":"<that namespace>"`, and
  nothing else of that rule.
- **`gate:check` answers standing.** The verdict is the gate's alone, never the
  quarantine limits and never the blocklist, so a holder of `r` learns nothing
  of the blocklist. The owner's own atSign answers `admitted`.
- **Any authenticated enrollment reads the default.** Only a root connection
  switches it (D11).
- **D4 counts admissions that take effect**, not those recorded beneath a rule
  that overrides them.
- **AT0022 stays the one code for every gate refusal of a change, and each kind
  has its own message**, listed in design section 5.2.
- **A namespace is dot-separated labels of word characters and hyphens, none
  empty**, as at_commons' grammar parses it; anything else fails to parse
  (AT0003). The atServer lower-cases it, as it does a key.
- **The client API's `GateVerbBuilder` is written on the client side**, from the
  final grammar, with raw-literal pins of the commands it builds.

**Why:** an admission that took away another atSign's access would make every
admit a loss of admission to act on (D12). An application holding only a
narrow namespace must be able to see that a broader rule governs it. A rule
needs an undo, for an application that is removed and under the cap on
namespaces. A check that answered the blocklist would disclose it, and one
that answered a passing limit would be stale at once. Switching the default to
closed should cut off strangers, not the owner's trusted contacts. And a
namespace written two ways must not become two rules.

## D27 The value-reference resolver is fixed with the gate

*2026-10-11, gkc. Q33, raised when D23's second scenario failed against the
resolver.*

A lookup resolving an `atsign://` reference takes the copy shared with the
asker, falls back to the public copy only when the shared one is missing, and
answers `data:null` when neither is held. Before, it always went on to the
public copy, so it failed when that was missing and preferred it when both
were held, and D23's "resolves as today" scenario could not hold. The fix
ships with the gate rather than as a change of its own.

**Why:** the agreed scenario says what a reference should do, and the
resolver did not do it.

## D28 Quarantined bytes count while they are in the window

*2026-10-11, gkc. Q34, raised when building the quarantine.*

A namespace's quarantined bytes, and the atSign-wide total, are the sizes of
the quarantined notifications accepted in each atSign's current window *W*.
Each counted notification's size is kept beside its time in the quarantine
record, and leaves the total when its time leaves the window, as its count
does. Removing or expiring a notification frees nothing. D15, D20 and D24 said
"held", which nothing defined.

**Why:** it follows D7's "removing notifications does not free a place", needs
no hooks into the paths that remove or expire notifications, and survives a
restart because the record already holds it.

## D29 An atSign is new until it is activated, judged when its gate first loads

*2026-10-11, gkc. Q35, raised when building the operator's starting default.*

The first time an atServer loads its gate and finds no default recorded, it
records one: `ungated` when the atSign has been activated, and the operator's
starting default when it has not. An atSign has been activated when it has
deleted its CRAM secret, or holds the flat PKAM key or any enrollment, expired
ones included. A brand-new atServer, a reset atSign and one provisioned but not
yet activated therefore start with the operator's default. A recorded default
changes only through `gate:default` on a root connection, so a later change to
the operator's setting reaches only atServers that have not yet loaded their
gate. The operator's setting is `startingDefault` in the `gate` section of the
atServer's config, `ungated` when unset.

Deciding at activation, in the CRAM paths that install the first key, and at
the atServer's first start, when it plants its CRAM secret, were considered.

**Why:** the decision is made once, in one place, before the atSign is
activated. Every way of activating leaves one of those marks, and an atSign
provisioned but not yet activated is new to its owner. Before this, a gate with
no default recorded used the starting default in memory and recorded nothing,
so an existing atSign would have followed any later change to the operator's
setting.

*Spec consequence:* rules.feature gains a scenario for an atSign activated
before its atServer had the gate, and one for a change to the operator's
setting.
