# 3.16.4
- docs/test: the proof of possession on `at_pkam_publickey` says why its
  signable is a constant, and the framing is pinned by a raw literal.

  The signable is `primary|<value>|<signingAlgo>` — no challenge, no session,
  no atSign — so an identical `update:json` document is replayable byte for
  byte, on this atSign and on any other. That is deliberate and is now stated
  as such: the signature is not an authenticator and never stood between
  anyone and this key. `update` requires authentication, and the only
  connections authorised to write this key are an owner or CRAM connection,
  which carries no enrollment id, and a connection authenticated as the
  housekeeping enrollment. A replayer is therefore already entitled to install
  a key of its own choosing and can sign a fresh document with any key it
  holds; the one thing a captured document buys it is installing a key it does
  NOT hold, which is defeating this guard against itself.

  `enroll:update`'s equivalent differs only in that its signable names a
  server-issued enrollment id, unique to the atSign that issued it, so that
  document is incidentally bound to one atSign. Nothing rests on the binding
  in either case, so the legacy framing is kept byte-identical rather than
  hardened with an atSign or a nonce: a client implements one rule for both
  rotations, and `EnrollParams.apkamPublicKeySignature` publishes that rule.

  The framing was built in tests from the constant that defines it, which pins
  nothing. It now has a raw-literal pin, whose negative control is the
  atSign-bound spelling — so the server accepting that spelling is a failure
  rather than an improvement nobody notices.

- docs: `EnrollmentManager.isUsableRootEnrollment` says what its bar is and
  what it does not cover.

  It read as "fully privileged AND holding a credential something can
  authenticate with", which claims more than the server can test. What the
  method actually tests is that the record is fully privileged and that a
  non-empty public key is recorded for it — in the record, or at
  `at_pkam_publickey` for `primary` — which is exactly the bar authentication
  applies before it looks at a signature. It says nothing about whether anyone
  holds the private half, and nothing can: the server never sees a private key,
  so a key nobody holds is indistinguishable here from a live one.

  The doc now names where that gap IS closed — at the write, where a proof can
  be demanded: `enroll:update` refuses a new `apkamPublicKey` without a
  signature by the private half being installed, an `update` of
  `at_pkam_publickey` refuses one on the same terms once the housekeeping
  record exists, and the housekeeping record is minted only by a legacy
  authentication that has already verified a signature against the key it
  stands over. And what remains uncovered: `enroll:request` installs an
  `apkamPublicKey` with no proof, so an enrollment approved but never yet
  authenticated with passes this bar holding a key whose possession is proved
  on its first `pkam:` and not before.

  No behaviour change. The same correction is made in the two other places the
  claim was stated: `hasUnexpiringRootEnrollment` and the last-root refusal in
  `enroll_verb_handler`.

- fix: the enrollment key builders fold the id they are handed, so a
  non-canonical spelling of an id builds the key of the record it addresses
  rather than one naming no record at all.

  `buildEnrollmentKey`, `keyForPEK` and `keyForSEK` folded the COMPOSED key
  and nothing else, and composition moves whatever trails the id into the
  middle of that key, past the reach of the fold's trim; the fold's
  space-strip catches a plain space and nothing else. A trailing tab, no-break
  space or ideographic space therefore survived, and the key built from it
  named no record — while `canonicalEnrollmentId` folds all three away, so the
  id everything else on the path is comparing against had already lost them.
  Leading whitespace was never the half that got through, which is why every
  spelling the tests carried was leading.

  Folded inside the builder rather than declared a precondition on the
  caller: that is the posture `canonicalEnrollmentId` already takes, and it
  makes the builders' claim to be byte-identical to an enumerated key true
  unconditionally instead of true for ids somebody else folded first.

- fix: `pkam` decides the connection's identity inside the atSign's
  enrollment-mutation critical section, so an `enroll:revoke` landing while an
  authentication is in flight is not answered `success`.

  Admitting a connection is a read-decide-write whose write is the
  connection's IDENTITY: the enrollment state is read, and the connection is
  then marked authenticated and given an enrollment id. Both halves ran
  outside the section every enrollment mutation holds, so a revoke could land
  between them — and the revoke sweeps open connections by the enrollment id
  each one CARRIES, so a connection still being authenticated has not been
  given one and the sweep passes over it. The marking then happened on a state
  the revoke had already replaced.

  Both branches are covered. Legacy PKAM reads the housekeeping enrollment;
  APKAM reads its own record before the signature is verified, because that
  read is where the public key comes from, so the state it decides on is the
  state from before the longest step on the path. The APKAM branch now asks
  again inside the section, and refuses code for code as the first ask would
  have.

  It is the store-wide section rather than an understanding with the revoke
  path because revocation is not the only way an enrollment stops serving:
  `enroll:delete` and an elapsed ttl sweep no connections at all, and only a
  read taken inside the section is ordered against them. The cost is that an
  authentication waits for an enrollment mutation in flight, which is exactly
  the mutation that decides the answer it is about to give.

  This is not what stands between a revoked credential and a live session —
  `AbstractVerbHandler` re-reads the enrollment before every command and
  closes a connection whose enrollment has left `approved`, so the exposure
  was one `success` answer rather than a usable session. What is fixed is that
  answer.

- fix: an enrollment record removed from the keystore is no longer served
  from the enrollment cache, and a read in flight across an enrollment write
  no longer puts the superseded value back.

  The cache was invalidated by `EnrollmentManager.put` and by
  `EnrollmentManager.remove`, and by nothing else. Every other way an
  enrollment key leaves the keystore — `delete` from an owner connection, the
  scheduled expired-keys sweep — went straight to the keystore's own `remove`,
  which fires the pre-remove hook that keeps per-enrollment data consistent
  but touched no cache. The record went from disk while the cache went on
  serving it as approved, and on authorising every verb its grants covered,
  for the life of the process. Invalidation now lives in a POST-remove hook,
  which every removal path fires and which runs when there is no longer
  anything on disk to read back; `EnrollmentManager.remove` refuses to run at
  all unless that hook is registered.

  Separately, `getEnrollmentByFullKey` filled the cache AFTER awaiting the
  store, so a read that overlapped a write reinstated the pre-write record
  once the writer had already invalidated it — and nothing invalidated it
  again. Measured as a PKAM that succeeded for an enrollment the store said
  was revoked. The fill is now skipped when the enrollment generation moved
  while the read was in flight. The generation is global to all enrollments,
  so a write to any enrollment costs a concurrent read its cache fill; that is
  the deliberate price of holding the invariant with no new state, and the
  next read makes the fill again.

- fix: `scan` re-checks the enrollment's approval state on the wildcard fast
  path, and a connection whose enrollment has left `approved` is closed.

  An enrollment holding `*` was filtered by a branch that removed `__manage`
  keys and other enrollments' per-enrollment keys and then returned the rest
  without ever reading `approval.state`. The per-key branch, which every
  narrower enrollment takes, asks `isAuthorized` about each key and so refuses
  a revoked one — so revocation worked for a `wavi:rw` enrollment and did not
  for a `*:rw` one. A revoked wildcard enrollment went on enumerating the
  whole keystore for as long as it held the connection open.

  The wider fix is one level up: `pkam` admits an APKAM connection on
  `approved` and refuses every other state, so an enrollment that has left
  `approved` is one its connection could not be opened with now, and the
  connection is closed rather than merely denied. Denial is per-verb, which
  makes it only ever as complete as the least careful handler — the scan gap
  above is what that costs. Expiry has always closed the connection; revoked,
  denied and pending now do too, each reported with the error code `pkam`
  refuses that state with (AT0027, AT0025, AT0026), so a client cut off
  mid-session reads the same reason it would have been given had it connected
  a moment later.

- fix: every enrollment mutation now runs inside ONE store-wide critical
  section, and it covers the whole read-decide-write rather than the write:
  `enroll:request` (past the throttle and the OTP gate), `enroll:approve`,
  `deny`, `revoke`, `unrevoke`, `update` and `delete`, the housekeeping
  enrollment's creation, the retrofit cap's arming, and the adoption of a
  capped approver's children.

  The keystore has no compare-and-set, and the decision each write rests on
  is a question about the WHOLE store — "would any unexpiring root survive
  this act?" above all — so two mutations of two DIFFERENT records each
  passed an individually correct check and stranded the atSign between them.
  A per-record lock cannot see that; only a store-wide section holds it.

  Measured on this tree before the change: two concurrent `enroll:revoke`
  commands each counted the root the other was about to remove and left the
  atSign with none; a retrofit cap arming alongside an `enroll:revoke` did
  the same, while both serial orderings are safe; and a revoke and a cap
  arming writing the same record lost one of the two whole-record snapshots
  — the verb answering `{"status":"revoked"}` over a record the store held
  `approved`, with that credential's published `_apsk` back at the live
  address. The adoption of a capped approver's children is the sharpest of
  them, because its lost update is permanent and silent: nothing re-parents
  twice, so a child left naming its old approver is outside every later
  revocation cascade for the rest of its life.

  The section replaces the arming-only lock, whose docstring claimed it made
  the liveness answer safe to act on — true only against another arming.

  ⚠️ Throughput: an enrollment mutation arriving while another is in flight
  now waits for it. Measured at 100 enrollments, a retrofit cap arming takes
  9-10ms with nothing to adopt and 36-39ms adopting 50 children, each adopted
  child being a record write that walks the keystore.

  AUTHENTICATION is not affected. The retrofit cap's early exits sit outside
  the section, so an APKAM authentication with nothing to arm — every
  authentication except a retrofit successor's first — costs 2-8us whether or
  not a mutation is in flight. With those exits inside the section, twenty
  such authentications took as long as the arming they queued behind: 9.8ms,
  21ms and 37-38ms at 0, 25 and 50 adopted children respectively. Reads are
  outside the section entirely, so no verb queues behind an enrollment write
  to read one.
- fix: an enrollment id is canonicalised to the keystore's own fold wherever
  it enters the server or is used to build a keystore key, so handler-side
  identity and stored identity agree by construction. The keystore normalises
  every key it is given — trimmed, lowercased, spaces stripped — while
  comparisons above it are exact `String ==`, so a non-canonical spelling
  read and wrote the right record while comparing unequal to it, and every
  guard phrased as "is this the enrollment we are acting on?" answered no
  about the enrollment being acted on.

  ⚠️ The worst of them was the last-root refusal. It excludes the enrollments
  an act is about to remove BY KEY, and a key built from an unfolded id
  excluded nothing — so the enrollment being revoked counted as the root that
  survives its own revocation. Measured on this tree: `enroll:revoke` naming
  an atSign's only permanent root with a leading U+3000 answered
  `{"status":"revoked"}` and the record really was revoked, while the
  identical command spelled canonically was refused. Space, tab and U+00A0
  never got that far — the write-path key validator refuses them — but
  U+3000, U+2000 and U+2028 all fold and all pass validation.

  Also fixed by the same fold: a revocation cascade that swept nothing,
  because the approver walk compares against ids taken from keystore keys and
  an unfolded target matched no link; per-enrollment data (a published
  `_apsk` among it) that stayed in the approved location through a revoke;
  and an enrollment's own reserved keys reading as another enrollment's.

  The fold has ONE definition, `canonicalAtKey`, which the keystore itself
  now calls — every other copy in the tree, the SQLite backend's included,
  routes through it, because two spellings of one fold drift with nothing
  going red.

  ⚠️ Behaviour a deployed client could notice, all of it previously reachable
  only with a non-canonical id: a self-`enroll:revoke` spelled around is now
  refused; an `enroll:*` id of nothing but whitespace is now refused as a
  missing id rather than building a key that names no enrollment; and
  `enroll:fetch`, `enroll:update` and ownership of an enrollment's own
  reserved keys now treat a non-canonical spelling as the same enrollment,
  which is what the keystore has always done with it.
- fix: the housekeeping enrollment `primary` no longer holds a copy of the
  legacy PKAM credential. It snapshotted `at_pkam_publickey` into its
  `apkamPublicKey` once, at creation, and never refreshed it — so the record
  and the credential it stands for could diverge, and every divergence was
  either a stranding or an authentication bypass. Legacy PKAM verifies against
  the LIVE key and reads nothing off the record, so the copy served no reader.
  The record now carries an EMPTY key, and an APKAM authentication naming
  `primary` fails closed at the verifier's existing emptiness guard whatever
  the id spelling. That mattered because the identifier comparison which also
  refuses it was exact while the keystore folded ids on the way in, so a
  non-canonical spelling walked past the comparison, resolved to the record,
  and authenticated against the snapshot — as `primary`, over APKAM, with a
  key the atSign had rotated out. Incoming ids are now folded the keystore's
  own way (see below), so that comparison catches such a spelling by name;
  the empty key is what makes the refusal belt-and-braces rather than the
  only thing standing in the way.

  ⚠️ `enroll:list` and `enroll:fetch` now report an empty `apkamPubKey` for
  `primary`. That is the honest answer rather than a regression: it is an
  identity for a credential held elsewhere, and nothing can authenticate
  against it.
- fix: `enroll:update` refuses a target of `primary` outright. The self-only
  gate asks whether the connection is authenticated AS its target, and a
  legacy connection carries `primary` — so the one identity this verb must
  never be pointed at was the one identity that satisfied the check. A legacy
  connection could install an APKAM public key of its own choosing on the
  atSign's legacy identity and be answered
  `{"enrollmentId":"primary","status":"approved"}`. The refusal names the
  remedy: the legacy credential is rotated where it lives, with an update of
  `privatekey:at_pkam_publickey` over a connection authenticated with the
  credential it replaces, carrying the same proof of possession this verb
  demands (see below).
- fix: `primary` counts as an unexpiring root only while `at_pkam_publickey` is
  in the keystore AND NON-EMPTY. (A special case of the general rule above:
  an enrollment nothing can authenticate as is not a root, whoever it is;
  `primary` is where the credential lives somewhere other than the record.) Alone among enrollments it holds no credential
  of its own, so a record standing over a key nobody can authenticate with is a
  PHANTOM root — approved, fully privileged, permanent and impossible to
  authenticate as. Counting it answered "this atSign can restore a root" for a
  record nobody holds a credential for, and the caller then revoked or capped
  the last root that actually worked. Presence alone was the wrong bar because
  authentication refuses an empty public key before it looks at a signature, so
  an empty value and a missing one are the same credential — none. Zero-length
  is reachable rather than theoretical: the `update` grammar demands a
  non-empty value, but `update:json` carries the value inside the JSON document
  instead, so an owner connection can store one.
- ⚠️ fix: the atSign's EXISTING legacy PKAM credential is adopted as `primary`
  at SERVER STARTUP, and the lazy first-authentication mint is now strict.
  ⚠️ Takes effect on the next RESTART of each atServer, once per atSign.

  Either path has to answer the same question: is the keypair at
  `at_pkam_publickey` this atSign's own legacy credential, or an app's APKAM
  key left there by an older server's CRAM auto-approve branch, which wrote
  the enrolling app's key there "for old clients"? At startup it is
  answerable, because no client has connected and the store is exactly what
  the previous run left. On a legacy authentication it is not, because the
  client has already had the run of the atSign and can reshape whatever the
  gate is about to read — a rule that declined only when `at_pkam_publickey`
  equalled some enrollment's own `apkamPublicKey` was defeated end to end in
  three wire commands: `enroll:revoke:force` on itself, since the force flag
  alone lifts the self-revoke refusal; `enroll:delete` on itself, since a
  caller may always delete its own enrollment and so demonstrates no
  `__manage`; and then a legacy authentication over the record's own grave,
  minting `primary` at `*:rw` + `__manage:rw` with no approver and no expiry.

  So the two paths now ask different questions:

  * STARTUP adoption mints `primary` for an atSign holding a usable
    `at_pkam_publickey` and no `primary` record, WHATEVER ELSE IT HOLDS —
    unless that key is some stored enrollment's own `apkamPublicKey`, which
    is exactly the shape the auto-approve left behind. That refusal is the
    only one it makes, and the evidence behind it cannot have been arranged.
    An enrollment record that cannot be read fails CLOSED, since it cannot be
    shown not to hold the key.
  * The LAZY mint keeps the strict rule: any enrollment record in the store
    refuses it. After startup adoption it is reached only by a genuinely fresh
    atSign, or by a key that appeared at `at_pkam_publickey` while the server
    was up on an atSign that has been enrolled — which is not a credential
    the atSign was onboarded with.

  Adoption runs after the pre-remove hook is registered and BEFORE the startup
  expired-keys sweep, because the sweep destroys the evidence the refusal
  reads: it removes an elapsed enrollment record while leaving the flat key
  behind, the hook taking `at_pkam_publickey` only for `primary`.

  ⚠️ WHAT AN OPERATOR SEES: an atSign upgrading to this release gains an
  approved, fully privileged, unexpiring `primary` enrollment on its first
  restart, logged at `shout`, and `enroll:list` shows one more row from then
  on. Its legacy keyfile authenticates as that enrollment. Before this
  change such an atSign — every atSign that has ever enrolled an app, which
  includes every atSign onboarded through `enroll:request` — had its valid
  legacy authentication refused with no route back, since `otp:get` needs an
  authenticated connection, a self-retrofit may not ask for `*`, and the CRAM
  secret is gone. Adoption happens once: a later restart neither re-mints it
  nor restores one that has been revoked or retired.

  ⚠️ What adoption does NOT close: an app that rotated its own APKAM key
  through `enroll:update` during an EARLIER run leaves the superseded keypair
  at `at_pkam_publickey` with no record naming it, so no comparison can
  recognise it. Startup removes the ability to arrange the evidence now; it
  cannot un-arrange evidence persisted before the process existed. The residue
  costs such an app permanence rather than access — it already holds an
  approved APKAM enrollment — and the price of closing it by refusing
  populated stores is stranding every upgrading atSign.

  Nothing is deleted on a refusal. The server cannot tell a vestigial key from
  one an owner provisioned on purpose, so removing it would lock an owner out
  rather than tidy up after an app; the atSign is left exactly as it was, with
  legacy authentication refused.

  ⚠️ The refusal a legacy client sees when the record is absent and must not
  be created reads `this atSign has no usable legacy PKAM credential. A legacy
  credential is adopted at server startup, from the keystore the previous run
  left; a key installed at this atSign afterwards is not adopted.`, followed
  by the remedy. It replaces `the legacy credential for this atSign has been
  retired`. Which of the two reasons it was is in the server log, not on the
  wire.
- ⚠️ fix: every decision that asks what enrollments an atSign HOLDS now reads
  the STORED roster, expired records included. Only the answers that merely
  REPORT a roster read the visible one.

  `AtKeyValueStore.getKeys` skips a record whose ttl has elapsed while `get`
  and `exists` do not, so between a ttl elapsing and the scheduled
  expired-keys pass removing the record — tens of seconds — the enumerated
  roster is a smaller set than the atSign holds. Every decision keyed on that
  enumeration had a window in which it saw an atSign it did not have, and an
  enrollment's ttl is its APKAM key-expiry posture: the roster empties on a
  schedule its holder chose.

  Measured on one enrollment, one variable: with the record live, a legacy
  authentication's mint of `primary` was refused; with the same record's ttl
  one minute in the past and the record still on disk, it minted — an
  unexpiring, no-approver root at `*:rw` + `__manage:rw` for whoever held the
  flat key. Nothing clears that key on the way past, either: the pre-remove
  hook takes `at_pkam_publickey` only for `primary`.

  `EnrollmentManager.getAllEnrollmentKeys` now takes a REQUIRED
  `includeExpired`, so every call site states which roster it means:

  * STORED — the housekeeping mint's gate and startup adoption's vestigial
    check; `removeOrphanedApkamEncryptionKeys`, so ORPHANED means no record
    holds it rather than no VISIBLE record holds it; `removeLegacyApkamPublicKeys`,
    which is the only repair for the app/device name an older server
    published and which nothing else ever revisits; `descendantsOf`, so a
    revocation cascade follows every status as its contract says;
    `_adoptApprovalChildren`, the one pass whose omissions are permanent
    because nothing ever re-parents twice; and `hasUnexpiringRootEnrollment`.
  * VISIBLE — `enroll:list` and `enroll:listns`, which report a roster and
    decide nothing. Listing a record the keystore has stopped serving would
    make the response depend on how recently the sweep happened to run.

  ⚠️ WHAT AN OPERATOR SEES: a startup pass now deletes app/device public
  keys belonging to enrollments whose ttl had elapsed, which it used to skip
  and nothing else would ever have removed; and it no longer deletes the
  encryption keys of an enrollment whose record is still on disk, leaving
  those to the expiry sweep that removes the record. `enroll:list` and
  `enroll:listns` are unchanged.
- ⚠️ fix: rotating `privatekey:at_pkam_publickey` now requires proof that the
  sender holds the private half of the key it is installing — the same
  self-signature `enroll:update` has always demanded of every other
  credential, in the same framing, verified through the same path `pkam:`
  uses.

  Without it the legacy credential was the one key on the atSign that could be
  replaced with no proof of anything. Measured on this tree in three arms
  differing only in the bytes stored at that key: rotated to a WELL-FORMED key
  whose private half was never persisted, `primary` went on being counted as
  the atSign's surviving unexpiring root — the bar is a credential something
  can authenticate with, and a well-formed orphan passes it — while nothing
  could authenticate as it, so revoking the last root that really worked was
  permitted. Stored EMPTY it was not counted and the revoke was refused; left
  alone it was counted and authentication worked. The server cannot tell an
  orphan from a live key after the fact, so the demand is made at the write.

  ⚠️ THE CLIENT CONTRACT. The proof travels in an `update:json` document as
  `apkamPublicKeySignature` alongside `signingAlgo`, spelled exactly as
  `enroll:update` spells them, over
  `primary|<new public key>|<signingAlgo>`:

  ```
  update:json:{"atKey":"privatekey:at_pkam_publickey",
               "value":"<new public key>","metadata":{...},
               "signingAlgo":"rsa2048",
               "apkamPublicKeySignature":"<base64>"}
  ```

  A client builds it from `UpdateParams.toJson()` and adds the two fields.
  Nothing is added to the `update` grammar, deliberately: a wire parameter
  this server read and no published builder could produce would be a fork of
  the protocol that only looks like an extension. The plain
  `update:privatekey:at_pkam_publickey <value>` form has no parameter that
  could carry a signature, so a ROTATION must use the JSON form.
  `signingAlgo` is required rather than defaulted, because the legacy
  credential records its algorithm nowhere — a legacy `pkam:` names it on the
  wire per connection — so there is nothing to fall back on and a wrong guess
  installs a key that cannot authenticate.

  ⚠️ BOOTSTRAP is exempt and onboarding is untouched: when the atSign holds no
  `primary` record, nothing stands over the key, an unusable value counts as
  nothing and mints nothing, and possession is proved later by construction —
  the record is minted only by a legacy authentication that has already
  verified a signature against that key. `install_PKAM_Keys` and CRAM
  onboarding plant the first key in the plain form exactly as before. Every
  other write is a rotation over a live identity and must prove itself,
  whoever is asking: an owner or CRAM connection included, since it can strand
  the atSign the same way.

  ⚠️ WHAT BREAKS: a client that rotates the legacy credential with the plain
  `update:` form on an atSign that has minted `primary`. In this tree that is
  `tests/at_functional_test/test/pkam_verb_test.dart`'s ECC round trip, ported
  in the same commit.

- fix: reading an enrollment no longer WRITES. `getEnrollmentByFullKey`
  removed a record whose ttl had elapsed as it read it, and enrollments are
  read on every verb command and every authorisation check — all of it
  deliberately outside the atSign's one enrollment-mutation critical section.
  So a reader that had decided nothing mutated the store while a mutation of
  another record was in flight, and for `primary` it was worse than untidy:
  `remove` fires the pre-remove hook, which takes `at_pkam_publickey` with it,
  so an authorisation check could retire the atSign's legacy credential.

  The read now reports the elapsed ttl as an `expired` approval state and
  leaves the record alone, which is the value every caller already decided on.
  Nothing is leaked: the server's scheduled `deleteExpiredKeys()` pass removes
  expired records through the same `AtKeyValueStore.remove`, so the same hooks
  fire and the ancillary per-enrollment keys still go.

  ⚠️ `enroll:list` and `enroll:fetch` therefore keep reporting an expired
  enrollment, with `"status":"expired"`, until that pass runs — where before,
  the first read made it vanish.

- ⚠️ fix: an enrollment nothing can authenticate as is not counted as a root,
  WHOEVER it is. The credential check was special-cased to `primary`, so an
  ordinary enrollment holding an empty `apkamPublicKey` — approved, fully
  privileged and permanent — still answered "this atSign can restore a root",
  and counting it licensed revoking the last root that actually works.
  Measured on this tree: with one keyless root standing, a forced self-revoke
  of the atSign's only real root answered `{"status":"revoked"}`; the same
  record with a public key in it is what the refusal is supposed to allow, and
  still does.

  Fully privileged, approved and permanent describes the GRANT and says
  nothing about whether any keypair can present it. The bar is now one
  predicate applied on both sides of every stranding decision — what an act
  REMOVES and what SURVIVES it, plus the retrofit cap's decline — so "root"
  means one thing in all of them. The credential is the record's own
  `apkamPublicKey` for every enrollment except `primary`, whose credential is
  the live `at_pkam_publickey`.

  It is NOT the question asked of an already-authenticated connection: a
  legacy connection is authenticated as `primary`, whose record holds an
  empty key by construction, and what that connection may do is still decided
  by its grants.

- ⚠️ fix: `enroll:unrevoke` is refused on `primary`. Revoking that record is
  how an atSign withdraws its legacy keyfile — nothing else can, because the
  credential is a flat key the delete verb refuses on grammar and the record
  holds no copy of it to overwrite. The revoke leaves `at_pkam_publickey`
  exactly where it was, so the record's revoked state is the only thing
  standing between that keyfile and full privilege, and an un-revoke handed it
  back working to every holder of a copy. The guard that stops this everywhere
  else does not reach it: an un-revoke is refused while the enrollment that
  ADMITTED the target is not approved, and `primary` carries no approver — the
  server created it for itself — so that gate was vacuous for the one record
  whose revocation is a decision about a credential nothing else governs.
  `enroll:revoke` and `enroll:delete` on `primary` are unchanged; getting a
  working credential back is a fresh enrollment, not an undo.
- ⚠️ fix: `update:privatekey:at_pkam_publickey` is no longer writable by any
  root enrollment. It is the one key an enrollment can write that MINTS AN
  IDENTITY rather than serving one: legacy PKAM authenticates against it and
  carries no enrollment id, so an app root that planted a key it held gained a
  second identity its own revocation could not reach — a compromised root
  surviving its own revocation, permanently, with nothing on the roster to
  show for it. It is now writable by an owner or CRAM connection (which
  carries no enrollment id at all, and is what onboarding uses to plant the
  first key) and by a LEGACY-PKAM connection rotating its OWN credential,
  which has already proved possession of the key it is replacing by
  authenticating with it. Every other `privatekey:` key is unchanged and still
  decided by root privilege alone.

  ⚠️ Being ALLOWED to write it is no longer the whole of the check — see the
  proof-of-possession entry below.
- fix: the last-root refusal now asks whether the ACT removes a fully
  privileged enrollment, not whether the enrollment the command NAMES is one.
  A revoke cascades to every enrollment that descends from its target by
  approval, so a target holding no full privilege of its own could still carry
  a root away with it — and a guard reading only the target saw nothing to
  protect. Nothing else on that path noticed either: the caller was neither the
  target nor a descendant of it, so the self-revoke and descends-from refusals
  were both quiet, and an atSign lost its last permanent root to a command that
  reported success. The target is still asked about, because it is removed too
  and cannot appear in its own cascade. Only enrollments the cascade will
  actually rewrite count — one already revoked is not taken away again.
- ⚠️ fix: acting on an enrollment that holds `__manage:rw` now requires the
  caller to hold `__manage:rw` itself. Every other namespace was compared
  against the caller's own grant; `__manage` is decided on its own branch
  ahead of that comparison and was checked only for presence, so a read-only
  administrator could admit a read-write one — an enrollment able to approve,
  revoke and delete, including the approver that admitted it. The escalation
  never needed a bare `__manage` grant to work: an approver holding `*:rw`
  alongside `__manage:r` already covers every data namespace a full root asks
  for, leaving `__manage` the only entry between it and minting an enrollment
  strictly more privileged than itself.

  The comparison is made once per namespace the target holds, by every
  operation naming another enrollment, so it reaches the paths that confer
  nothing as well. ⚠️ `enroll:fetch` only READS the target, and a
  `__manage:r` administrator can no longer fetch a `__manage:rw` enrollment's
  record even where it covers every other namespace that enrollment holds.
  Deliberate: the bar is authority over the target's grants, and a caller with
  no claim to approve, revoke or delete an administrator has none to read its
  record either. This is not what keeps the enrollment's encrypted APKAM
  symmetric key from a read-only administrator, and should not be mistaken for
  it — `enroll:list` is unaffected and still returns that field, for every
  enrollment on the atSign, to any caller holding `__manage` at all.

  An approver holding `__manage:r` may still admit an enrollment asking for
  `__manage:r`, and reaching a `__manage` key is unaffected.
- fix: the retrofit cap's decline now NAMES the remedy. An atSign whose only
  root asks for a bounded key life declines on every authentication and has
  both revoke routes refused, so its legacy credential is un-retirable and
  nothing said what would change that. The warning now says: approve an
  enrollment holding `rw` on both `*` and `__manage` with no key expiry, then
  revoke or delete the predecessor.
- fix: a revocation could be partly undone by a retrofit cap running
  concurrently. `capEnrollmentExpiry` re-read the record but took the STATUS
  from the caller's snapshot, taken before a keystore walk and a write — so a
  revoke landing in that window was written back as approved, moving the
  revoked enrollment's per-enrollment data (its published `_apsk` signing key
  among it) back to the live address. The status is now read off the record it
  just read, and a record that is no longer approved is not written at all.
- fix: a revoke missed every descendant behind an EXPIRED link. Key
  enumeration hides records whose ttl has elapsed, so the expired enrollment's
  approver edge vanished with it while everything behind it survived approved —
  and the lifetime of that link is chosen by whoever mints it, since a
  never-expiring enrollment may admit a short-lived one that admits others in
  turn. The walk now climbs from each live candidate and fetches each link BY
  KEY, which returns an expired record.

  ⚠️ That closes the gap between a record EXPIRING and its removal, and no
  more. The server runs a periodic `deleteExpiredKeys()` sweep, so the record
  is gone within tens of seconds and the chain is severed for good — as it is
  by `enroll:delete` on a middle link. Nothing records ancestry beyond the
  immediate approver, so a revoke arriving after the sweep reaches the first
  live candidate and stops. This needs a MIDDLE link, so it reaches a chain of
  two or more — and approval is unbounded by design, so that is an ordinary
  shape on any atSign whose administrators admit administrators, not a
  remnant. Closing it needs ancestry that outlives the record.
- fix: an enrollment id is folded where `pkam` reads it off the wire, to
  EXACTLY the fold the keystore applies to a key — trimmed, lowercased,
  spaces stripped. A non-canonical spelling resolved to the same record while
  comparing unequal to the id held everywhere downstream, so a revoke would
  not drop that connection and the credential kept authenticating. Ids are
  server-issued and already canonical, so this rejects nothing.
- fix: a cascade no longer aborts when a descendant has already gone.
  `keyStore.get` throws rather than returning null, so a record reaped between
  the walk and the write took the whole verb with it, leaving the enrollments
  already revoked with their connections open. `enroll:listns` and
  `enroll:infons` gained the same guard.
- fix: connections are dropped for every enrollment the revoke intended,
  rather than only those this call changed — a retry after a partial failure
  found the descendants already revoked and so dropped nothing for them.
- fix: `enroll:delete` asks who is calling. It was the only enrollment
  operation naming a target that checked nothing beyond "is this connection
  authenticated" — so any APKAM connection, holding any single namespace and
  no `__manage`, could destroy any denied or revoked enrollment on the atSign.
  `enroll:fetch`, which only READS the target, has always required `__manage`
  and access to every namespace the target holds; delete, which is
  irreversible, asked for neither. The omission was an oversight rather than a
  decision, and delete now applies exactly the gate fetch does, with the same
  two exemptions: a caller may always delete its OWN enrollment, and a
  connection carrying no enrollment id (CRAM or legacy-PKAM — the atSign
  itself) may delete any.

  Asked BEFORE the status checks, so a caller that may not touch an enrollment
  does not learn from the refusal whether it is approved, denied or revoked.

  A target holding NO namespaces is refused rather than passed. The check
  decides by iterating the target's grants, so an empty map would pass it
  vacuously — zero iterations, no refusal, and the `__manage` requirement
  lives inside that loop too — making the most anomalous record on the atSign
  the one any enrolled caller could destroy. Such a record is reachable: an
  `enroll:request` on a LEGACY-PKAM connection writes one, because that path
  is neither of the two that fill the map in — it gets neither the CRAM
  branch's `__manage`+`*` nor the APKAM branch's copy of its predecessor's
  grants — while the "at least one namespace" check applies only to requests
  carrying an OTP, which an authenticated connection does not send.

  ⚠️ When this landed, every OTHER per-namespace loop passed such a record
  vacuously too — `approve`, `deny`, `revoke` and `unrevoke` share one loop,
  and `enroll:fetch` has its own — and only the delete gate refused. Both are
  closed later in this release; see the entry on an enrollment holding no
  namespaces below.

  Two things had come to rest on this. `EnrollmentManager.descendantsOf`
  fetches each `approvedByEnrollmentId` link BY KEY, so deleting a middle link
  puts everything behind it permanently beyond the reach of a later cascade.
  And the approver-not-approved refusal permits an enrollment whose approver no
  longer exists, so deleting that approver is what makes the orphan
  un-revokable.

  ⚠️ This NARROWS a shipped capability. An enrollment holding `__manage` but
  not the target's namespaces could delete it before and cannot now — the same
  asymmetry already closed on `revoke`. `at_onboarding_cli`'s `delete` command
  takes an arbitrary `--enrollment-id`, so it is affected whenever it runs as
  an enrollment rather than from an owner keyfile; an enrollment that could
  not have revoked the target can no longer destroy its record either.
- perf: a revoke moves per-enrollment data ONCE for the whole cascade.
  `getKeys` walks every key the atSign holds, and the move was made per
  enrollment, so revoking a chain of K descendants cost K+2 whole-store scans
  on an event loop nothing else can run on. K is chosen by whoever builds the
  chain, and an enrollment holding `__manage` may admit administrators who
  admit more, to any depth. The regex already exposes the owning enrollment
  id, so one walk now serves the whole set.
- feat: `enroll:infons:<namespace>` — facts about a namespace, as opposed to
  `enroll:listns`, which answers who holds it. Same authorisation as `listns`
  (APKAM-authenticated, caller approved, caller holds at least read access to
  the namespace), and the two now share one gate rather than restating it.

  It returns a JSON map, initially with one member: `lastRevokedAt`, the most
  recent moment any enrollment holding that namespace was revoked. The key is
  ALWAYS present, and null when nothing has been revoked — an absent key and a
  key a client failed to parse are the same thing to a careless reader.
  Revocations reach it through a cascaded descendant as readily as through the
  enrollment an operator named: the history records each revoked enrollment's
  OWN grants, so a descendant contributes the namespaces it held rather than
  its approver's.

  It is derived from the revocation history below, and it NETS OUT
  un-revocations — so it can move BACKWARDS. A client deciding whether to
  re-fetch must ask whether the value CHANGED, not whether it grew.

  A map rather than a field on the `listns` roster: a roster is a list of
  members and the last revocation affecting a namespace is not a fact about any
  member. `enroll:listns` is unchanged, which matters — a deployed client reads
  that response as "if this is not a list, the namespace has no members", so an
  unrecognised shape there would silently empty every roster rather than fail.

  ⚠️ The enroll operation alternation lives in at_commons, which does not yet
  list `infons`, so `at_server_spec`'s `Enroll` verb adds it locally by
  INSERTING into at_commons' pattern — not by copying it, so every other
  upstream change still reaches this server, and it throws rather than
  returning an unmodified pattern if the insertion point ever moves. This is a
  temporary divergence between what the server accepts and what at_commons
  describes; `enroll_verb_syntax_test.dart` fails deliberately once a published
  at_commons defines `infons`, which is the signal to delete the override.
- feat: a revocation history. Every moment an enrollment's revocation state
  changes is written as a record of its OWN, carrying the enrollment id, the
  moment, the namespace grants it held, the enrollment that issued the command
  and — for one a cascade swept up — the enrollment whose revocation took it.
  An un-revoke writes its own counter-event rather than erasing anything, so
  the history keeps both facts and an audit can see a revocation that was
  withdrawn.

  A field on the enrollment could not do this. An enrollment record carries the
  APKAM key-expiry posture as its ttl, so a revoked enrollment is reaped on the
  schedule its own credential was issued under — and a stamp living there goes
  with it, taking `enroll:infons`' answer backwards, or to null, on a timetable
  chosen by whoever set that posture. To a client polling for a reason to
  re-fetch, that reads exactly like "nothing has changed". The grants go the
  same way, and they are the only evidence of which namespaces a revocation
  touched.

  The enrollment an operator named and every enrollment its cascade takes share
  ONE timestamp: they are revoked by a single act, and stamping each with the
  instant its own write happened would invite a reader to order them against
  one another as separate decisions — in an order that is an artefact of the
  retry-safe write sequence.

  A revoke records BEFORE its write and an un-revoke AFTER it, so a crash in
  between always errs towards reporting the namespace as revoked. Over-stating
  a revocation costs a client a re-fetch; under-stating one tells it nothing
  has changed when a credential has just stopped working.

  The records live in `__manage`, which is what already hides enrollment
  records from `scan`, and deliberately NOT under the `new.enrollments` key
  pattern: the enrollment enumeration regex is an unanchored substring, so a
  key carrying that pattern anywhere would be walked as an enrollment by every
  roster, liveness check and cascade in the server.

  ⚠️ They have no ttl — that is the point of the log, and it is also unbounded
  growth. One record per revocation for the life of the atSign, and a cascade
  writes one per enrollment it takes. No retention policy has been decided.

  The `revokedAt` field this replaces has been removed from the enrollment
  value. A record stored with one still decodes; re-encoding drops it.
- feat: revoking an enrollment revokes everything it APPROVED, to any depth.
  An enrollment holding `__manage` admits others, and one that is revoked as
  compromised must not leave everything it admitted authenticating. The
  cascade is TRANSITIVE — an enrollment it admitted may have admitted more —
  and walks enrollments of every status, so a revoked enrollment part-way down
  cannot conceal the approved one behind it; only those currently approved are
  revoked. Depth costs nothing: one keystore pass builds the whole map and the
  walk is then in memory. Connections held by cascaded enrollments are dropped
  with the target's.

  ⚠️ It follows the APPROVAL edge and NOT the replacement edge. Revoking an
  enrollment does not revoke what RETROFITTED from it: a retrofit produces a
  peer, the same principal re-keyed, so retiring a superseded credential must
  not kill the one that superseded it — an operator tidying up an old key
  would otherwise take the device's current credential with it. A stolen
  keyfile that has retrofitted is revoked by naming the successor, which is
  the live credential.

  ⚠️ A retrofit's successor INHERITS its predecessor's approver rather than
  naming the predecessor, so it stands where its predecessor stood and remains
  reachable from whoever admitted it. Without that a retrofit would be an
  escape hatch: revoking the approver would reach the predecessor and stop.

  ⚠️ Forward-only. The approver is recorded from this release, so every
  enrollment already on disk carries none and can never be cascaded to —
  nothing recorded who approved it. Enrollments approved over an OWNER
  connection (CRAM or legacy-PKAM) carry none either, deliberately: there is
  no enrollment there to revoke.

  A revoke response now carries `cascadedEnrollmentIds` — the ids the cascade
  took — and only when the cascade took something, so an ordinary revoke
  response keeps the shape it has always had.
- feat: three refusals that stop an atSign stranding itself, all decided before
  anything is written.

  A revoke whose cascade would remove the CALLER is refused. The revoke path
  only asks whether the caller covers the target's namespaces, and a fully
  privileged enrollment admits administrators holding exactly the grants it
  holds — so an enrollment the target admitted passes that check against the
  very enrollment that admitted it, while descending from it by approval. The
  cascade would take the caller with it. On a two-enrollment atSign that is
  stranding reached with nobody self-revoking, so neither of the other two
  refusals sees it. The refusal names the approval chain, and tells the
  operator to revoke from outside it.

  A self-revocation by the last fully privileged enrollment is refused even
  with `force`, and the question is asked over what SURVIVES the cascade rather
  than over what is stored — the descendants are still approved while the check
  runs, so counting them would report the atSign safe at the moment it is being
  stranded.

  `enroll:unrevoke` is refused on an enrollment whose APPROVER exists and is
  not approved: without it the cascade is one-way, and un-revoking a descendant
  while its approver stayed revoked would restore exactly the orphan the
  cascade removed. Only an enrollment carrying no approver is unaffected — one
  admitted over an owner connection, or written before the field existed — and
  that is a much narrower exemption than it reads: on a managed atSign most
  enrollments were admitted by another. `enroll:approve` carries the same test
  so the invariant holds at every transition into an active state. The approver
  is written from the connection during the approve itself, AFTER this check
  has run, so a first approval reads none and passes vacuously; the check bites
  on `unrevoke`, and on any later transition of a record that already names
  one.
- feat: the atSign's legacy PKAM credential has an enrollment of its own. It
  authenticates with no enrollment id, so it has never had a record: nothing
  stated its grants, no roster showed it, no verb could revoke it and nothing
  ever retired it. A legacy connection now authenticates AS a housekeeping
  enrollment, created idempotently on the first legacy authentication, holding
  `*:rw` and `__manage:rw` — the access it has always had, now stated.

  Its enrollment id is the literal **`primary`**. Deterministic, so finding it
  is one key read; and `primary` is already the atSign-wide sentinel for "no
  enrollment id", so a legacy client's signing key at
  `public:_apsk.primary.a.__e@<atSign>` becomes this enrollment's
  per-enrollment data the moment the record exists — revoking or expiring the
  legacy credential now parks that key like any other enrollment's. Nothing
  retired it before.

  It carries no approver: the server creates it for itself, so no revocation
  cascade can reach it. A cascade able to sweep it away would strand the very
  credential it exists to govern.

  ⚠️ Deployment-visible in three ways. A legacy connection now carries an
  enrollment id where it carried none, so authorisation checks that treated a
  null id as unrestricted access now see `*:rw` + `__manage:rw` instead — the
  same access, reached by a different route. A READ can mutate the atSign: the
  first `enroll:list` over a legacy connection creates the record. And a
  roster that was empty is no longer, so a client asserting on its size needs
  to expect the housekeeping enrollment.

- BREAKING: a legacy connection's `scan` is now FILTERED like any other
  enrollment's, so enrollment records drop out of its results. `scan` decides
  by whether the connection carries an enrollment id, not by auth type — a
  legacy connection used to fall through to the unfiltered owner view simply
  by having none, and now carries the housekeeping enrollment's id.

  It is consistent rather than incidental: `enroll:list` is the management
  path for enrollment records, an enrollment-scoped scan has always excluded
  them whatever its grants, and a legacy connection is an enrollment now.
  Ordinary keys are unaffected — the housekeeping enrollment holds `*:rw`.

  ⚠️ A legacy client that scanned for `<id>.new.enrollments.__manage@<atSign>`
  records will stop finding them and must use `enroll:list`. A CRAM connection
  still carries no enrollment id and still gets the unfiltered view.

- BREAKING: legacy PKAM authentication is refused unless that enrollment is
  APPROVED, and APKAM authentication NAMING it is refused outright. Revoking
  the record is what makes revoking the legacy keyfile possible at all —
  before it, no verb could — and an expired one is the retrofit cap having
  retired it. In both cases the signature is valid and the credential is not,
  which is the distinction the record exists to carry.

  The APKAM refusal returns AT0009 rather than an enrollment-status code,
  because it is not a statement about status: a credential reachable both with
  and without an enrollment id would have two lifecycles, and its retirement
  could be sidestepped by the very keyfile it retires.

  ⚠️ An atSign whose legacy credential has been retired refuses legacy
  authentication as an authentication failure naming the remedy, rather than
  surfacing a keystore exception. A retired credential cannot re-create
  itself: the record's absence means "never existed" only while a usable
  legacy key is still there, because removing the record always takes that key
  too. A usable key is necessary and not sufficient — see the entries above on
  emptiness and on minting only for an atSign that holds no enrollment.

- feat: the housekeeping enrollment appears in `enroll:list` like any other.
  The roster genuinely contains it, and hiding it would make the verb lie
  about what can authenticate against the atSign.

- BREAKING: an `enroll:request` auto-approved on a CRAM connection no longer
  writes `at_pkam_publickey`. It used to copy the enrolling app's APKAM public
  key there "for old clients". `at_pkam_publickey` is the credential for
  LEGACY PKAM authentication, which by definition supplies no enrollment id;
  an `enroll:request` produces an APKAM credential, which always authenticates
  with one. A key minted for the second has no business becoming the first.

  ⚠️ It was an UNCONDITIONAL write, so it also destroyed any legacy credential
  the atSign already had — and `enroll:request` is deliberately repeatable on
  a CRAM connection (#2208), so every repeat clobbered it again. That is the
  sharper of the two effects and it predates this release.

  ⚠️ Deployment-visible: an atSign onboarded by CRAM plus `enroll:request` now
  has no `at_pkam_publickey` at all, so legacy PKAM authentication is
  impossible for it. That is the intent — such an atSign is APKAM-only — but a
  client that expected to authenticate without an enrollment id after
  onboarding will not be able to.

- fix: capping a retrofitted approver moves the enrollments it admitted onto
  its successor. Nothing records ancestry beyond an enrollment's immediate
  approver, so a severed link orphans everything behind it — a later revoke of
  the chain above reaches the first live candidate and stops, and the
  reactivation refusal then permits un-revoking exactly what a cascade had
  swept. `enroll:delete` and the expiry sweep could already sever a link; the
  retrofit cap would have made it routine, putting a thirty-day deadline on an
  administrator without asking what sat behind it. The successor is where those
  enrollments belong: it is the same principal re-keyed, it already inherits
  its predecessor's approver, and this is that substitution seen from the other
  side. It also stops retiring a superseded credential taking down everything
  that credential ever admitted.

- fix: two enrollments authenticating for the first time at once no longer cap
  BOTH of an atSign's roots. Arming a retrofit's cap asks whether any
  unexpiring root would survive capping this predecessor and then caps, which
  is read-modify-write across the whole keystore. Run twice concurrently, both
  walks finished before either write, so each saw the other's root still
  uncapped and both were capped — leaving the atSign with no root it could
  restore itself from. Two devices reconnecting together was enough. The walk
  and the cap that follows it are now one critical section.

- feat: retiring the housekeeping enrollment removes the legacy PKAM public
  key with it, which is what makes the atSign's oldest credential retirable at
  all. That key is what legacy authentication verifies against, and it cannot
  be deleted over the wire — the delete verb refuses `privatekey:` keys on
  grammar — so the pre-remove hook is the only path that removes it.

  Deliberately without a discriminator: both ways the record can go should
  take the key — expiry, once a retrofit's successor has proved itself, and
  `enroll:delete` on a revoked one — so the hook not being able to tell them
  apart stops mattering. It is also what lets absence be READ: with the key
  always going at the same moment, a missing record alongside a present key
  can only mean the record never existed, which is how a bootstrap is told
  from a retirement.

  ⚠️ Legacy authentication against an absent key now refuses as an
  authentication failure rather than surfacing a keystore exception.
  `keyStore.get` throws for a missing key rather than returning null, so the
  handler's own "pkam publickey not found" guard never saw that case. It did
  not matter while an absent key meant a broken atSign; it matters now that it
  means a retired credential.

- BREAKING: a legacy-PKAM connection's own `enroll:request` is a RETROFIT of
  the housekeeping enrollment, not a way to enrol a different app. It
  authenticates AS that enrollment, so the enrollment it authenticated as is
  the one it replaces: auto-approved, with no human step and no OTP, carrying
  exactly that enrollment's grants. This is what gives the atSign's oldest
  keyfile the no-approver upgrade path every other credential already had.

  ⚠️ It NARROWS what that request could do. A legacy connection asking for a
  different app's namespaces is now refused, because a retrofit may not choose
  its grants. Admitting a new app from a legacy connection goes through the
  OTP path — the legacy connection MINTS the otp and the new app sends its own
  request over its own unauthenticated connection — which is the path that
  exists for it.

  The once-off rule applies here too: several sibling clones of one legacy
  keyfile may each retrofit the housekeeping enrollment, which is the
  behaviour the cap re-arms for, but a successor of it may not retrofit again.

  ⚠️ Three sites, not one, and the two beyond the obvious gate are where this
  would have failed silently. The duplicate-request check runs hundreds of
  lines EARLIER and throws on a same-(appName, deviceName) approved
  enrollment — which a retrofit keeps — so widening only the gate would have
  looked like doing nothing at all. And the mandatory-namespace check exempts
  the paths that fill grants in on the request's behalf; a retrofit is one, so
  a legacy request omitting namespaces was refused for not stating any.

  The CRAM ordering is now PINNED rather than resting on statement order. A
  CRAM connection must never receive retrofit treatment — at_auth throws
  unless a first enrollment comes back `approved`, so onboarding would break
  for every new user — and it avoids the branch only because the auto-approve
  block returns first. The gate names its two auth types explicitly instead of
  negating CRAM, and a test asserts a CRAM enrollment is minted rather than
  replaced.

- fix: `update:meta` is authorised like `update` rather than refused to every
  enrollment (#2691). `UpdateMeta` extends `Verb` and not `Update`, and
  appeared in neither the read nor the write allow-list, so the per-namespace
  check returned false for every access level — `*:rw` included — and an app
  that could `update` a key could not set a ttl on it. A metadata write is a
  write: it now requires `rw` on the key's namespace, and read access does not
  carry it.

  It survived this long because a connection carrying no enrollment id skipped
  the enrollment check entirely, and that was every legacy-PKAM and CRAM
  connection — so the paths that exercise `update:meta` most never reached the
  gate. Giving the legacy credential an enrollment is what made it reachable,
  and four functional tests found it immediately.

- BREAKING: the enrollment that keeps an atSign recoverable must be
  PERMANENT. The refusals that stop an atSign stranding itself asked whether
  any other fully privileged enrollment would outlive a deadline computed from
  the caller's own record. A root with a finite life satisfied that and only
  deferred the stranding: the atSign kept the ability to restore a root until
  that date and lost it afterwards, with nothing at the time of the revoke to
  say so. Comparing one record's expiry against another's also made the answer
  depend on WHO was asking, so the same atSign read as safe or stranded
  according to which credential ran the verb. The question is now simply
  whether an approved, fully privileged enrollment exists with no expiry at
  all.

  ⚠️ A revoke that was permitted may now be refused: an atSign whose only
  other root carries an APKAM key-expiry posture no longer has a surviving
  root by this test. The refusal names what to do — approve a fully privileged
  enrollment that does not expire.

  The same question gates the retrofit cap's decline, so a predecessor is now
  spared in one case more than before.

  ⚠️ APPROVED is load-bearing rather than incidental, and the housekeeping
  enrollment below is why it is worth saying: it is a permanent root that
  would otherwise satisfy this on every atSign forever, and it can be revoked
  like any other. A revoked one stops counting the moment it is revoked.

- feat: a retrofit carries its predecessor's grants and may not choose them.
  An APKAM-authenticated `enroll:request` replaces the enrollment it
  authenticated as rather than descending from it, so the successor now holds
  exactly that enrollment's namespaces. `namespaces` is optional on this path:
  omit it — or send an empty map, which states nothing — and the predecessor's
  grants are inherited; name grants and they must be exactly the predecessor's,
  or the request is refused. Previously a retrofit held whatever
  it asked for, bounded only from above, so it could mint a successor unable to
  do what the credential it replaced could — a loss that surfaces at the next
  thing the app does rather than at the request that caused it. Asking for MORE
  than the predecessor holds is still refused, with its own message, so the two
  mistakes stay distinguishable.
- feat: the retrofit expiry cap is armed by the successor's first
  authentication rather than by storing it. Storing a successor proves only
  that the atServer wrote a record: the successor's APKAM private half is
  persisted client-side, so a keyfile write that fails, a read-only file, or a
  process that dies before the flush each leave the successor existing on the
  server and nowhere else — with a clock already started on the predecessor,
  which is by then the only credential that still works. The cap now fires when
  the successor first authenticates over a connection it opened, which is what
  proves the private half survived and is usable. It still re-arms once per
  successor, so a predecessor retires one grace period after the last sibling
  upgrades, and a successor's own repeated connections never extend it.

  Two conditions stop the cap, and neither is remembered: both are judgements
  about state that can change, so they are re-made on the successor's next
  authentication rather than frozen into the record. A predecessor that is not
  approved is left alone — it is already retired, and capping it would hand it
  a fresh expiry it has no business carrying; an unrevoke restores an ordinary
  predecessor and must not find it permanently exempt. And a predecessor
  holding `__manage:rw` is left alone when no OTHER enrollment would still be
  alive to approve a replacement once the cap fired — the case that would leave
  an atSign unable to admit one. Every other predecessor is capped regardless
  of how long its successor lives: declining more widely than that would switch
  retirement off for any fleet whose APKAM keys are shorter-lived than the
  grace, and would make the grace setting work backwards, a longer grace
  declining more often.

  The expiry the cap measures against is taken from APPROVAL rather than from
  the request. A record that carries no expiry does not expire, whatever
  posture its stored value states, so nothing but the grace bounds the cap
  there. The two differ by the approval latency, and a request-anchored
  measurement went negative for an enrollment retrofitted between them —
  capping it to one millisecond, killing a credential with hours of legitimate
  life left and locking out every sibling clone that had still to upgrade.
- fix: a published APKAM signing key is world-READABLE, not world-writable.
  The only cross-enrollment denial in the authorisation path short-circuited on
  the `public:` prefix, and its own comment justified that on read grounds —
  but the same predicate gated writes and deletes. A caller holding `*` and no
  `__manage` therefore reached another enrollment's
  `public:_apsk.<id>.a.__e@`: the namespace resolves to one nothing in its map
  matches, the wildcard fallback supplies `rw`, and the `__manage` guard is
  skipped because the namespace is not `__manage`.

  That record is what a verifier resolves to check a signature, so whoever can
  write it controls both the algorithm set and the key ids the victim is
  trusted under — signing AS the victim, and withdrawing a key unverifies
  everything it had signed. The exemption is now gated on the handler's
  existing mutating-verb predicate: reads are unchanged, and writes, deletes
  and `update:meta` are refused. An enrollment's access to its OWN
  per-enrollment namespace is unaffected, public or not.

- fix: a retrofit successor may not outlive the credential it replaced. The
  mint-time check compared TERMS, and a term restarts its clock at the
  successor's own write — so an inherited term always expired later in
  absolute time than its predecessor's deadline, by exactly the predecessor's
  age. It was also vacuous in the case that mattered most: it read the posture
  off the predecessor's stored VALUE, while a capped predecessor's real
  deadline lives only in its record metadata. A CRAM root carrying posture 0,
  capped to now+grace, could therefore mint a successor asking for 0 — written
  as "never expires", by a credential due to die inside the grace.

  The successor's posture is now bounded by what is LEFT of the predecessor's
  stored deadline, carried to the write as an ABSOLUTE so it lands exactly
  rather than being re-anchored past the bound.

  ⚠️ A successor inheriting a one-hour posture now carries slightly LESS than
  an hour rather than exactly an hour.

- BREAKING: a retrofit is a ONCE-OFF. `enroll:request` on an authenticated
  connection now refuses when the enrollment it would replace is itself a
  replacement, so a device gets one no-approver migration rather than a series;
  a second algorithm change needs an approver again. Nothing else enforced it
  before: the request branch checked that the connection was APKAM-
  authenticated, that the named enrollment existed and was approved, and that
  grants did not escalate, but never asked whether that enrollment had itself
  replaced something.

  What made repetition costly is the key-expiry clock: each link restarts it,
  so an enrollment with a one-hour term could retrofit itself every
  fifty-five minutes indefinitely and the posture was not enforceable across a
  chain at all.

  ⚠️ The second reason this guard was written for no longer applies, and is
  recorded here so nobody restores it: a lost link used to sever the
  revocation cascade behind it. Revocation now travels the APPROVAL edge, and
  a successor inherits its predecessor's approver rather than naming the
  predecessor, so losing a replacement link orphans nothing.

  ⚠️ This bounds the REPLACEMENT edge only, and only its depth. Several
  sibling clones of one keyfile may still each retrofit the same enrollment —
  that is the behaviour the retrofit cap re-arms for — so the graph is one link
  deep and arbitrarily wide. Approval is a separate edge and is NOT bounded:
  an approver may admit an enrollment that admits another, to any depth, and
  the cascade is what governs that rather than any limit on minting.

  ⚠️ The transitive cascade is kept and is now the ordinary case rather than a
  concession to stored data: approval chains are unbounded, so depth is
  reachable through the verbs. Over the wire the functional pack exercises a
  cascade one link deep; transitivity beyond that is pinned by unit tests over
  hand-written store records, the retrofit chain that used to prove it having
  become unbuildable against a real server.
- fix: an enrollment holding no namespaces is refused by `enroll:fetch` and by
  the shared approve/deny/revoke/unrevoke path, not passed vacuously. Each
  decides authority by iterating the TARGET's grants, so a target holding none
  passed with zero iterations — and the `__manage` requirement lives inside
  those loops, so it was not asked either. `enroll:delete` already refused it;
  the other five operations did not. Gated on caller-vs-target exactly as
  delete is, so an owner connection (CRAM or legacy-PKAM, carrying no
  enrollment id) can still act on such a record, and an enrollment can still
  force-revoke itself.
- fix: the "at least one namespace" check no longer sits inside the branch for
  requests carrying an OTP. An authenticated connection sends none, so a
  request naming no namespaces wrote an enrollment with an empty grant map and
  nothing refused it — the producer for the vacuous pass above. The check now
  applies wherever the request's own grants are what gets written, exempting
  only the two paths that fill them in on its behalf: CRAM, which grants
  `__manage` and `*`, and a retrofit, which inherits its predecessor's exactly.

  ⚠️ The refusal message changes from 'At least one namespace must be specified
  for new client enroll:request' to 'At least one namespace must be specified
  for enroll:request', since it is no longer specific to a new client.
- fix: an `enroll:update` landing concurrently with a revoke no longer undoes
  it. The handler read the enrollment, checked it was approved, then awaited an
  APKAM signature verification and a metadata read before writing the record
  back with `approved` hardcoded — the status was never re-read. A revoke
  arriving in that window was silently reverted, and because the write moves
  per-enrollment data to match the status it is handed, the `_apsk` signing key
  the revocation had just parked was republished at the live address.
  `enroll:update` is self-only, so the caller IS the enrollment being revoked:
  the compromised-client case revocation exists for.

  The status is now read off the record immediately before the write, and the
  update is REFUSED rather than adjusted once the record is no longer approved.
  Refusing is what makes it safe: `_publishApskSigningKey` writes the signing
  key straight to the approved address without going through the record write
  at all, so correcting the status alone would still have republished it for
  any update carrying one. The reply's status is likewise read rather than
  asserted.
- fix: `enroll:listns` and `enroll:infons` no longer admit a caller holding
  `*` to the `__manage` roster. The shared gate asks whether the caller has
  any access to the named namespace, and the matcher falls back to the
  wildcard for a namespace no explicit grant covers — `__manage` included. So
  a caller holding `*` and no `__manage` could read the `__manage` roster and,
  through `infons`, its revocation history. `*` does not imply `__manage`
  anywhere else in the server; it does not here either, and the namespace must
  now be held explicitly.
- fix: the namespace matcher prefers an EXPLICIT grant to the wildcard,
  matching the atServer's own rule. It tested `*` inside its loop and returned
  the first entry that matched, while the server looks for an explicit suffix
  match across every enrolled namespace and reaches for `*` only when none
  matched. The stored grants map is insertion-ordered, so an enrollment
  holding both `*` and a narrower grant at different access letters had its
  roster entry decided by which grant happened to be written first — and could
  report a letter the server itself would not act on.
- fix: the retrofit cap computes its ttl against the record it just read,
  rather than taking one the caller computed earlier. A ttl is a distance from
  the instant it was computed at and the store re-anchors it at the instant of
  the write, so the value the caller had already decided on was stamped as the
  deadline it checked PLUS however long the intervening keystore walk took.
  The parameter is gone rather than corrected, which also removes the last way
  a caller's stale snapshot could reach the write.
- fix: the decline memo records the generation the cap decision was READ at,
  not the one it finished at. The memo exists so a declined cap is not
  re-decided on every authentication, and its contract is that any enrollment
  write re-opens the question. It was written after the decision's awaits from
  a counter read live at that point, which folds in every write that landed
  DURING the decision — so a change the decision never saw was reported as
  already accounted for, and the decline stood against state it had not read.
  The widest window is the site that follows a whole-keystore walk.
- fix: arming the cap no longer reverts a concurrent change to the successor.
  The successor's record is read immediately before it is written rather than
  before the predecessor lookup and the cap, so an `enroll:update` rotating its
  APKAM public key, or an `enroll:revoke` of it, is no longer overwritten from
  a stale snapshot. The keystore has no compare-and-set, so on its own this
  narrowed the window rather than closing it; the enrollment-mutation critical
  section described above is what closes it.
- `enroll:list` responses carry a new `predecessorCapArmedAt` field on an
  enrollment that has retired the one it replaced: the UTC instant it did so.
  Absent on every other enrollment, and on any record written before this
  release.
- `apkamSelfEnrollmentGraceHours` is now documented in `config.yaml` with its
  720-hour default. It was already read from there and from the environment;
  it governs every enrollment now that the first-enrollment exemption is gone,
  so it should not have been invisible.
- fix: approving an enrollment whose key-expiry posture is zero or negative no
  longer leaves it carrying the approval window as its deadline. The metadata
  builder derives an expiry only for a ttl of zero or more, so a negative one
  skipped the derivation and the PENDING record's expiry — the window the
  request had to be approved in, 48 hours by default — survived onto the
  approved enrollment. The credential then expired on a deadline nobody asked
  for, and a retrofit cap measured against that stale value appeared to EXTEND
  the enrollment rather than shorten it. A non-positive posture is now written
  as the keystore's "never expires", which is what it asks for.
- fix: amending or revoking an enrollment no longer restarts its expiry.
  `enroll:update`, `enroll:revoke`, `enroll:deny` and `enroll:unrevoke` each
  wrote the record with no statement about expiry, and the metadata builder
  re-derives `expiresAt` from the retained ttl on any such write — so every one
  of them silently moved the deadline to a grace period from the moment of the
  write. An enrollment could therefore postpone its own retirement indefinitely
  by amending itself once per period, which would have made the retrofit cap
  advisory rather than a deadline. These writes now carry the stored expiry
  forward as an assertion. `enroll:approve` still sets the expiry deliberately,
  which is where an enrollment's key-expiry clock is meant to start.
- BREAKING for operators: `preserveFirstEnrollmentOnRetrofit` is removed, from
  `config.yaml` and from the environment. It exempted the atSign's first
  enrollment from the retrofit cap, because capping it could leave an atSign
  with no enrollment able to approve a replacement. That case is now answered
  where it actually arises rather than by exempting one enrollment: the cap
  declines when a fully-privileged predecessor would be retired and no other
  fully-privileged enrollment WITHOUT AN EXPIRY would be left. The successor's
  own lifetime is not consulted — it stands in that same test like any other
  enrollment, so the unexpiring successor an ordinary retrofit produces is what
  lets the cap arm. "Fully privileged" —
  read-write on both `*` and `__manage` — rather than merely able to approve,
  because approving is checked per namespace against what the approver itself
  holds, so a `__manage`-only enrollment can admit new enrollments and can
  never admit one carrying `*`. The exemption asked whether an enrollment was
  the FIRST; the question that always mattered is whether it is the LAST. A
  deployment that still sets the key needs no change: config is read by
  explicit key lookup with no schema validation, so an unknown key is never
  read.

  This applies to enrollments that already exist. An atSign that retrofitted
  under the exemption has a root carrying no expiry and a successor carrying no
  record of having armed anything; on that successor's first connection after
  the upgrade the root is capped for the first time — unless one of the two
  conditions above applies — and retires one grace period later. Where a predecessor had already been capped by the previous
  server, that first connection re-arms it once, giving it a fresh grace period
  rather than folding into the deadline it already had. Operators who scheduled
  around the old deadlines should expect one such shift per already-retrofitted
  pair.
- fix: assemble outbound responses correctly however the network splits them.
  A peer writes a response and the prompt that follows it as one string, but
  it arrives in however many pieces the network chooses, and the atServer
  decided a response was complete by looking at the last byte of whichever
  piece had just arrived. Depending on where a split landed that could delete
  a payload byte that happened to be an atSign, drop everything after a
  chunk's last newline, weld two responses into one and lose the second, or
  queue an empty response that tore down the next request. Responses are now
  framed from the accumulated bytes, so where the splits fall no longer
  matters. A peer that answers and then hangs up without writing its usual
  trailing prompt is still heard: its response is delivered rather than
  reported as a closed connection, so the error code it sent survives.
- fix: never answer a request with a message left over from a previous one.
  A response that no caller claimed stayed queued and was handed to the next
  request as its answer: a well-formed record for a key nobody asked for,
  with no exception and no log. Anything outstanding is now discarded before
  a request is sent, and a partial response left by a failed read no longer
  prefixes the next one.
- fix: malformed bytes from a peer no longer take the connection down or
  corrupt every later response. Invalid UTF-8 threw out of the socket
  callback and stayed in the buffer; a zero-length read threw as well. Both
  are now dropped.
- fix: bound an outbound read by the gap between chunks as well as by the
  whole exchange. One budget could not tell a large response still arriving
  from a peer that had stopped answering. A peer that goes quiet is given up
  on after 10s; a response that keeps arriving now has up to 30s rather than
  being cut off at 5s. An outbound read also gives up promptly when the
  connection has gone stale, as it already did when it was closed.
- fix: close the outbound client evicted from the pool. The pool held the
  last reference and dropped it without closing, so every eviction leaked an
  open socket to another atServer. A client with an exchange in flight is
  skipped when choosing which to evict, since `lastUsed` is stamped when an
  exchange ends and the client that had just begun a long request was
  otherwise the one picked. When every pooled client is busy the pool refuses
  rather than evicting a live one; on the notification path that becomes a
  retry, so a notification can be delayed where it previously went out over a
  socket that was then leaked.
- fix: enforce the outbound pool size across pool keys. Creating a client
  awaits its connect, and callers for different remote atSigns hold different
  locks, so two that both found no client could each pass the capacity check
  and add one, taking the pool past its configured maximum without the limit
  exception ever being raised. A slot is now taken before connecting and
  given back if the connect fails.

# 3.16.3
- fix: answer each cross-atSign request with its own response. A pooled
  `OutboundClient` is shared by every caller that needs the same remote
  atServer, and its response queue is in arrival order with nothing pairing
  a response to the request that caused it, so two requests in flight on one
  socket could each be answered with the other's record — well formed, but
  not what was asked for. Each request/response pair now completes on the
  socket before the next request is written to it.
- fix: `OutboundClientManager.getClient` is now atomic per pool key, so two
  concurrent callers that both find no client for a key no longer each
  create and pool one. Locking is per key so that connecting to one atSign
  does not hold up connecting to another.
- feat: implement the at_commons 5.10.0 protocol enhancements on the
  update/update:meta/update:json/delete surface (#2678):
  - `:cAt`/`:uAt`/`:eAt`/`:aAt` — caller-asserted
    createdAt/updatedAt/expiresAt/availableAt are stored faithfully instead
    of rederived. An asserted cAt wins on create and update alike; an
    asserted eAt/aAt suppresses the ttl/ttb derivation for that write.
    Values are truncated to millisecond precision. An asserted updatedAt
    is also recorded as the commit entry's opTime.
  - a request that supplies an absolute without its relative gets the
    relative derived and stored: an `:eAt` with no ttl derives the ttl
    (measured from the stored updatedAt — from the asserted availableAt
    when that lies ahead — so every server derives the same value from the
    same assertions), and an `:aAt` with no ttb derives the ttb, in each
    case replacing any relative retained from the stored record. A 0
    counts as unsupplied only where an absent value genuinely arrives as
    one — the `update:json` path, where commons `Metadata.fromJson` turns
    an absent ttl/ttb into 0. Where a missing relative is a real null —
    the notify receiver, which keys on what the wire carried, and the
    lookup-driven cache, which keys on the origin's own stored value — a
    `ttb: 0` ("available with no delay") is cached as it stands rather
    than re-derived. A non-positive implied value clears the relative
    instead.
  - once set, expiresAt/availableAt move only when a request speaks about
    that axis: an asserted `:eAt`/`:aAt` stores faithfully, an explicit
    ttl/ttb re-derives from now (a ttl-only write on a record whose birth
    is pinned expires at exactly now + ttl — the record's retained ttb is
    no longer folded in), ttl:0 clears the expiry, and ttb:0 re-stamps
    availableAt to now. A write that says nothing about expiry no longer
    restarts the expiry clock from the record's retained ttl (and no
    longer re-opens a ttb record's not-yet-born window) — the update verbs
    carry the stored absolutes forward as assertions.
  - `:nc` (no-commit) — the operation runs as usual (auto-notification
    included) but writes no commit entry AND purges the key's existing
    entry; the response is `data:-1`.
  - `delete:dAt` — recorded as the DELETE commit entry's opTime. Works with
    `:nc` for commit-log cruft management: a `delete:nc` of a key that no
    longer exists still purges the key's leftover entry.
- feat: `scan:cl` — scan the commit log instead of the keystore (#2678),
  so a client can inspect its entries and `delete:nc` the cruft. Returns a
  JSON array in ascending commitId order of
  `{"atKey", "operation" (the CommitOp symbol sync uses), "commitId",
  "opTime" (ISO 8601 UTC)}`; DELETE entries included. Authenticated
  connections only; the same regex / hidden-key / enrollment-namespace
  filters as a keystore scan apply. `scan:cl:@other` is refused loudly —
  the outbound scan proxy cannot forward `:cl`, so it would silently
  degrade to a plain remote scan.
- feat: server-to-server faithfulness for the four timestamps (#2678):
  outbound notifications emit `:cAt`/`:uAt`/`:eAt`/`:aAt` from the
  notification's metadata — for update auto-notifications, the STORED
  record's values, so every update auto-notification now carries `:cAt`
  and `:uAt` on the wire. NOTE: an atServer built with at_commons older
  than 5.10.0 (before 2026-05-12; releases ≤ c3.12.0 built before then)
  rejects that shape outright — its notify grammar has no timestamp
  groups — so auto-notifications from an upgraded sender to such a server
  fail and retry until they expire; the receiver must upgrade. A delete
  auto-notification attaches metadata ONLY when the client asserted
  `:dAt` (emitted as `:uAt`); an ordinary delete's wire shape is
  byte-identical to before, and client-issued `notify:delete` /
  `notify:all:delete` metadata still goes on the wire exactly as it
  always has. The receiving side stores cached keys with the transmitted
  origin timestamps — on first cache and on every refresh — and records a
  transmitted deletion time as the cached key's DELETE commit entry
  opTime. The lookup-driven cache does the same for data keys;
  `cached:public:publickey@` keeps its own createdAt semantics (it
  records when THIS server learned of a changed key — the signal
  PK-change handling is built on).
- fix: the update/update:meta auto-notification is queued AFTER the
  keystore write, carrying the metadata that was actually stored — the old
  order transmitted pre-merge values (e.g. a freshly-fabricated createdAt
  for an existing record) and queued a notification even when the write
  then failed. If the record was deleted concurrently before the
  read-back, the update notification is skipped (at warning) rather than
  queued after the delete's own notification, which could have
  resurrected the receiver's cached copy; a transient read-back failure
  falls back to the written metadata instead. A notify-queueing failure
  after a successful write is logged at warning and does not fail the
  client's request.
- fix: the per-key update mutex is keyed on the lowercased record name.
  The keystore canonicalizes keys to lowercase, so two case-variants of
  one update command name the same stored record; keyed on the original
  case they took different mutexes and raced.
- fix: an `update:json` moves a record's ttl, ttb or ttr only when the
  request names one, matching the metadata-fragment form of the same
  request. commons `Metadata.fromJson` turns an absent — or explicitly
  null — ttl/ttb/ttr into 0 and `Metadata.toJson` always writes the
  three, so what a json request never mentioned arrived as an explicit
  `ttl:0` (clear the record's expiry), `ttb:0` (available with no delay)
  or `ttr:0` (do not cache): a value-only json update silently dropped a
  record's expiry and stopped it being cached at the receiver. The verb
  layer now reads the nulls back off the decoded map the DTO was built
  from. A future at_commons that preserves them makes this a no-op
  rather than a correction.

# 3.16.2
- fix(at_secondary_server): a closed `NotificationManager` now stops its
delivery retries.
  - `PerAtSignNotifSender.send()` retries until delivery succeeds or the
   atSign leaves the atDirectory, and did not consult `closed` - so every
   undelivered notification kept retrying past `AtSecondaryServerImpl.stop()`,
   against a keystore that `stop()` closes immediately afterwards.
- feat(at_secondary_server): the atSign's FIRST enrollment is no longer given
an expiry clock when a retrofit supersedes it.
  - A retrofit (APKAM self-enrollment) caps the parent it supersedes. The first
   enrollment - the CRAM-path root that approves every later enrollment, and
   the one credential the server cannot re-issue - is now exempt, so retiring
   it stays the owner's explicit act via `enroll:revoke`.
  - Identified by all three of: root grants (`*` and `__manage`, both `rw`), no
   expiry on its record, and no other existing enrollment created before it.
  - Driven by `preserveFirstEnrollmentOnRetrofit` (config.yaml `enrollment:`
   section, or the env var of the same name), default `true`. Set it false for
   the previous behaviour.
- fix(at_secondary_server): an expired immutable record no longer blocks 
creation of a new one until the delete-expired-keys sweep has run.
  - An update that finds an expired record now deletes it before proceeding,
  - so that the cache-metadata validation, the immutability check and the 
   keystore's own metadata merge all see the same absence.

# 3.16.1
- feat: honour `EnrollParams.apskLegacy` — the bare RSA `_apsk` string,
  published verbatim rather than JSON-encoded. A request carrying both it and
  `apsk` is refused.
- feat: one 500KB limit on the whole enrollment record, replacing the
  per-field `apsk` cap. `metadata` was uncapped, so the old bound sat on the
  one field nobody would use to make a record big.
- fix: fix race in enrollment manager

# 3.16.0
- feat: `enroll:update` — an approved enrollment amending its OWN record's
  `apkamPublicKey`, `signingAlgo`, `apsk` and `metadata`. Self-only: the
  connection's enrollment id must equal the target's, which is an explicit
  exception to `isAuthorized`'s "no enrollmentId means full permissions"
  default, so an owner or legacy-PKAM connection is refused rather than waved
  through.

  This is what lets an enrollment rotate its APKAM authentication keypair while
  keeping its id. Before it, the only route was a new enrollment, which strands
  every record addressed to the old one.

  `namespaces` and the approval state are permanently out of reach, and are
  refused by name rather than ignored: an enrollment amending itself must not
  be able to widen its own grant. `metadata` is a per-key set — keys the
  request does not name survive untouched — because a whole-map replace is
  read-mutate-write against shared durable state, so a client that does not
  know about a future sibling field would clobber it. The enrollment's state
  and TTL are untouched, and an update naming nothing to change is refused
  rather than accepted as a no-op.

- feat: `enroll:update` changing `apkamPublicKey` requires
  `EnrollParams.apkamPublicKeySignature` — a signature by the **new** private
  key over `<enrollmentId>|<apkamPublicKey>|<signingAlgo>`, verified against
  the new public key carried in the same request.

  The connection proves possession of the enrollment's *current* key, and
  nothing else proves possession of the new one. Without this check a
  compromised-but-authenticated client can install a public key whose private
  half is held by an attacker, locking out the legitimate holder while the
  record still looks entirely valid.

  Signed and verified with `AtSigningMode.pkam` and SHA-256. Not
  `AtSigningMode.data`, which signs with the encryption keypair and so cannot
  express possession of an APKAM signing key at all. No nonce: the operation is
  self-only and the old key stops authenticating the moment the rotation lands,
  so a replayed request can only be sent by the current holder, which makes a
  rollback self-harm rather than an attack.

- **behaviour change**: the atServer no longer composes an enrollment's `_apsk`
  signing key. It publishes `EnrollParams.apsk` — a value the CLIENT composes
  and sends on `enroll:request` — verbatim at
  `public:_apsk.<enrollmentId>.a.__e@<atSign>`, and publishes **nothing** when
  the request carries no such value. The old behaviour (bare `apkamPublicKey`
  for `rsa2048`, a `{v, signingAlgo, publicKey}` object composed from the
  record for anything else) is gone, along with the server's only opinion about
  how a signing key is spelled.

  PKAM verification reads the enrollment record's `apkamPublicKey` and
  `signingAlgo`, never `_apsk`, so this key is a client-side artefact the
  server had no use for. What it *was* doing is bootstrapping: `_apsk` accepts
  writes only from its own enrollment's connection, and at approval that
  connection has never existed, while the approver must verify the enrollee's
  key package against the record and sign signing-chain links over it
  immediately. The server still does that bootstrapping — it just no longer
  invents the payload, so a new signing-key shape needs no server release. The
  value is stored on the enrollment record (`EnrollDataStoreValue.apsk`) at
  request time and published from there at approval, so an approver cannot
  substitute a signing key for the enrollment it is approving.

  Requires at_commons with `EnrollParams.apsk`. Capped at
  `EnrollVerbHandler.maxApskLengthBytes` (20KB, measured on the JSON encoding);
  an oversized value is refused with `IllegalArgumentException` before the
  enrollment record is created, never truncated — a truncated signing key would
  be a key nothing can verify against, sitting at the address every verifier
  resolves.
- refactor: APKAM signature verification now goes through one place,
  `ApkamSignatureVerifier`, rather than being assembled separately by `pkam:`
  and by `enroll:update`'s proof-of-possession check. The two have to agree
  byte-for-byte about how a signature is framed — a key that can authenticate
  must be installable, and a key installed must then authenticate — and each
  previously carried its own copy of the `signingAlgo`-token mapping.

  The boundary returns `Future<bool>`. at_chops answers through
  `AtSigningResult.result`, a `dynamic` holding a `FutureOr<bool>`, and that
  `dynamic` is what let an unawaited ML-DSA `Future` reach a `bool` at both
  sites; a typed boundary makes the same promise in a form the analyzer
  enforces. `mldsa65` is verified through the stateless
  `MlDsa65PureDartAlgo.verifyBytes`, which is declared `Future<bool>`, so the
  one algorithm that verifies asynchronously never travels as a `dynamic` at
  all. A test pins that it answers exactly what the `AtChopsImpl` path it
  replaced answered, over a genuine signature, a wrong message and a wrong key.

  `rsa2048` and `ecc_secp256r1` deliberately keep the `AtChopsImpl` path.
  `RsaSignatureAlgo` refuses any modulus that is not exactly 2048 bits, which
  `PkamSigningAlgo` never checked, so adopting it would stop an enrollment
  holding an off-size RSA key from authenticating; and at_chops has no
  `AtSignatureAlgorithm` for ECC at all, its key being hex and its signature
  compact-hex code units. Both would change what verifies on the
  authentication path.

- fix: a malformed APKAM public key or signature now fails the verification
  instead of escaping the verb handler. `enroll:update` takes `apkamPublicKey`
  straight off the request, and `package:elliptic` rejects a bad
  `ecc_secp256r1` key by throwing a bare `String` — which `on Exception` does
  not catch — or a `RangeError` for a key under two characters. `base64Decode`
  of the signature also ran outside both call sites' guards. Verification is
  now total and fails closed; an `Error`, being a defect in this server rather
  than a bad signature, is logged at `severe` with its stack rather than at
  `finer`.
- fix: `await` the result of an `AtChops` signature verification. Published
  at_chops 3.5.0 verifies `rsa2048` and `ecc_secp256r1` synchronously but
  `mldsa65` asynchronously, while `AtChopsImpl.verify` is synchronous either
  way — so `AtSigningResult.result` carries a `FutureOr<bool>` and an ML-DSA
  verification handed the caller an unawaited `Future` where it read a `bool`.
  Every `mldsa65` PKAM authentication died on
  `type 'Future<bool>' is not a subtype of type 'bool'`, and an `enroll:update`
  rotating to an ML-DSA key would have died the same way. The at_chops git
  override this replaced pinned a spike tag whose ML-DSA verifier was
  synchronous, which is why the two verification sites read `.result` directly.
- fix: deny, not throw, on an unparseable atKey in authz
- fix: defensive code to properly handle a namespace named 'null'
- fix: scope namespace-less keys to the legacy shared_key forms
- fix: restrict config:block to root enrollments
- feat: PKAM verification accepts `signingAlgo:mldsa65`. Without the branch a
  post-quantum APKAM keypair fell through to the RSA default and could never
  authenticate at all — the signature was well formed, just interpreted under
  the wrong algorithm.
- feat: for an APKAM-authenticated connection, the signing algorithm is now
  read from the **enrollment record** rather than restated by the client on
  each connect. It is hardening rather than a fix: the signature is checked
  against the stored public key either way, so a client that misstates the
  algorithm only fails its own verification. What it closes off is
  cross-algorithm confusion, where one key blob parses under more than one
  algorithm. Legacy PKAM has no enrollment record to be authoritative about and
  may legitimately present `ecc_secp256r1`, so it continues to use the value on
  the wire; a legacy enrollment predating the field keeps the existing default.
- feat: augmented pol challenge
- perf: sync now pushes `skipDeletesUntil` into the commit-log query rather than
  filtering deletes out of the results. `SyncProgressiveVerbHandler` passed
  `skipDeletesUntil` to a Dart `where` predicate over a full `iterate()` walk, so
  below-watermark DELETE entries were still read from the store (for SQLite,
  every such row materialised) before being dropped. They are now excluded by
  the query itself, materially cutting sync work on atSigns with many deletes.

# 3.15.0

- fix: tighten enrollment-management authorization (defense-in-depth). `otp:get`
  (OTP issuance) now requires `__manage` access — a no-`enrollmentId` owner/CRAM
  connection still bootstraps the first enrollment. `enroll:fetch` (which returns
  the enrollment's `encryptedAPKAMSymmetricKey`) now permits fetching only your
  OWN enrollment, or another enrollment when you hold `__manage` AND access to
  every namespace the target holds — the same bar as approve/deny/revoke. Both
  were previously gated on authentication alone.
- fix: enrollment authorization no longer lets the `*` ("all namespaces")
  wildcard reach reserved namespaces it was never granted. A `*:rw` enrollment
  could previously read/write another enrollment's per-enrollment reserved
  namespace (`<id>.a|r|d.__e`), and a `*:rw` enrollment WITHOUT an explicit
  `__manage` grant could update / delete / lookup / scan another enrollment's
  `__manage` record and encrypted key material (PEK/SEK) — the per-namespace
  guards keyed on the matched namespace rather than the target key's own
  namespace, so `*` laundered the reserved namespace. Access to another
  enrollment's reserved namespaces is now denied (public keys exempt;
  own-enrollment access unchanged), and `scan`'s `*` fast path excludes them
  too. Legacy no-`enrollmentId` connections are unchanged.
- fix: a sync request no longer fails outright when a commit entry outlives its
  key. `SyncProgressiveVerbHandler` fetched each non-delete entry's value from
  the keystore with no guard, so one commit entry whose key is absent — an
  expired key whose commit entry was not purged — failed the WHOLE sync request
  with `AT0015 key not found`, leaving the client unable to sync at all. Such
  entries are now skipped and logged. Note the pre-existing `atData == null`
  guard below it is dead code against both real backends, which throw
  `KeyNotFoundException` rather than returning null.
- fix: `EnrollmentManager.movePerEnrollmentData` now scopes its key moves to the
  transitioning enrollment. It previously ignored its `enId` argument and moved
  EVERY enrollment's per-enrollment reserved-namespace (`<enId>.[ard].__e`) keys,
  so a state change (approve / revoke / unrevoke / delete / expiry) on one
  enrollment wrongly moved other enrollments' data between the a/r/d markers.
  Now scoped via the `EnId` named group of `regexForPerEnrollmentNamespaces`,
  with a two-enrollment regression test.
- feat: cross-server `to:@<atSign>` first-verb. On an outbound peer connection
  the atServer can name the target tenant with `to:` as the first verb — giving
  architectural flexibility for endpoints reached through proxies / gateways and
  for multi-tenant peers that resolve a connection's tenant from its first verb.
  Inbound understanding of `to:@x` is unconditional (unauthenticated, serving
  only data already publicly readable via `lookup`); outbound emission is gated
  by `toVerbOutboundEnabled` (default false), falling back to the legacy
  `lookup:all:publickey` (reconnecting first) when a peer rejects or closes on
  `to:`, so it is safe to enable against legacy and pre-c3.0.35 peers.
- feat: optional SQLite persistence backend, selected by `persistence.backend`
  (`hive` default, or `sqlite`). SQLite opens one `atsign.db` per atSign under
  `<storageRoot>/sqlite`. Changing the backend triggers a migrate-verify-flip at
  startup (abort-on-failure, with the source data retained for rollback and
  reclaimed later by `bin/cleanup_stale_persistence.dart`); a `dual` validation
  mode mirrors every write into both stores for comparison. The default `hive`
  image is unchanged and never loads libsqlite3.
- feat: `enroll:listns:<namespace>` verb for the WP-SS secret-sharing
  substrate (at_commons 5.12.0). Returns all approved enrollments that hold
  read-or-better access to the requested namespace, including their opaque
  `metadata` payload (key packages). Access is gated on the caller being
  APKAM-authenticated with an approved enrollment that itself holds ≥`r`
  access to that namespace; unauthenticated or under-privileged callers
  receive `UnAuthorized`.
- feat: `metadata` field on enrollment records — an opaque JSON map stored
  verbatim from `enroll:request`'s `EnrollParams.metadata`; surfaced in
  `enroll:fetch`, `enroll:list`, and `enroll:listns` responses.
- fix: resolve sqlite migration deadlocks and OOMs by enforcing TRUNCATE mode and disabling true MVCC snapshots
- fix: fix path overlap bug in `sweepStaleSource`


# 3.14.0

- feat: `appMetadata` support on `update`, `update:meta` and `notify`
  (at_commons 5.11.0). The base64(JSON)
  `:appMetadata:` fragment is parsed into
  `AtMetaData.appMetadata`, persisted, returned by
  `llookup:all` / `llookup:meta`, retained across updates that
  don't mention it (like other typed metadata fields), carried on
  stored notifications, forwarded in the server-to-server notify
  command body, delivered in the monitor payload
  (`metadata.appMetadata`), and emitted base64-encoded in sync
  responses (matching `Metadata.decodeAppMetadata` on the client).
  Malformed values are rejected as invalid syntax.
- feat: the key-expiry sweep is now scheduled from
  `AtKeyValueStore.nextExpiresAt()` — a one-shot timer that sleeps
  until the next key actually expires (clamped to
  `[10s, expiringRunFreqMins]`, plus 0-30s co-hosting jitter) and
  reschedules itself after every sweep, replacing the fixed-cadence
  `cron` schedule. Worst case matches the old cadence; common case
  is a sweep within seconds of the next expiry. `cron` is no longer
  imported by `at_secondary_impl.dart`.
- refactor: the persistence layer is now wired through the new
  `AtPersistenceFactory` injected into `AtSecondaryServerImpl`,
  replacing direct `*.getInstance()` calls in the bootstrap path
  (`_initializePersistentInstances`, `start`, `stop`).
- refactor: every `getInstance()` call onto the legacy persistence
  singletons has been removed from `lib/`. Verb handlers
  (`from`, `cram`, `lookup`, `pol`, `proxy_lookup`, `config`,
  `sync_progressive`) take their needed `AtCommitLog` and/or
  `AtAccessLog` via constructor; `DefaultVerbHandlerManager`
  threads them in. `metrics_impl` reads from `atServer.commitLog`,
  `atServer.accessLog`, `atServer.secondaryKeyStore`.
  `StatsNotificationService.schedule()` takes its `AtCommitLog`
  parameter rather than fetching it lazily.
  `SecondaryUtil.saveCookie` takes the `AtKeyValueStore` parameter.
- refactor: `AbstractVerbHandler.keyValueStore` and
  `DefaultVerbHandlerManager.keyValueStore` are now typed
  `AtKeyValueStore<String, AtData, AtMetaData?>` rather than a
  raw, un-parameterised keystore type. This surfaced and fixed
  a set of latent
  nullability gaps in the verb handlers that the raw type had been
  masking: unchecked `get()` results bound to a non-null `AtData`,
  `String?` keys passed into `get` / `remove` / `put`, and a
  `bool?` metadata field (`isCascade`) used directly as a condition.
- chore: `_accessLog` field on `AtSecondaryServerImpl` is now
  publicly named `accessLog`.
- chore: `DefaultVerbHandlerManager`'s constructor now takes
  `commitLog` and `accessLog` parameters (placed before the trailing
  `atSign` positional). External consumers that construct it
  directly will need to pass these.
- test: `test_utils.dart`'s `verbTestsSetUp` / `verbTestsTearDown`
  now drive a `HiveAtPersistenceFactory` instead of calling the
  per-singleton `getInstance()` paths. The `atServer.<field> = …`
  injection seam is preserved.
- refactor: `AtConfig` (block-list configuration) moves here from
  `at_persistence_secondary_server` and now lives at
  `package:at_secondary/src/config/at_config.dart`. The class is
  fully backend-agnostic — constructor takes an `AtKeyValueStore`
  (not an `AtCommitLog`), reads / writes go through the abstract
  keystore, and writes pass `skipCommit: true` so block-list state
  no longer bumps the local `commitId`. Callers in
  `from_verb_handler` and `config_verb_handler` updated; the
  construction signature is now `AtConfig(keyStore, atSign)`.

# 3.13.2

- fix: defer `InboundCommandValidator.validate` until the buffer ends
  with `\n` or has at least 16 bytes (the length of the longest
  verb+subcommand, `enroll:unrevoke`, plus 1). Previously, a command arriving
  in two TCP flows where the first carried fewer bytes than the verb
  name (e.g. `'loo'` then `'kup:publickey@alice\n'`) failed validation
  on the first flow, was sent an `error:` frame, had its buffer
  cleared, and was rejected again on the second flow — two error
  frames written to the client for one command
- fix: anchor `InboundCommandValidator`'s `scan`/`monitor`
  short-circuit to `startsWith` (was `contains`). A value containing
  the substring `scan ` or `monitor ` no longer skips the verb-parse
  + auth-check path; previously, an unauthenticated client could send
  e.g. `update:public:phone@alice scan some-text\n` and the validator
  would early-return without enforcing the `update` verb's auth
  requirement.

# 3.13.1

- fix: log the offending rawVerb and command when
  `InboundCommandValidator.validate` throws an InvalidSyntaxException

# 3.13.0

- feat(deps): Take up at_commons ^5.10.0 to pick up new command (verb) syntax

# 3.12.0

- perf: substantial reduction in per-request heap allocations on the
  inbound, verb-dispatch and update paths (regex literals hoisted to
  `static final`; `logger.info(...)` sites guarded by `isLoggable`;
  `Uint8List` per-chunk copy replaced with shared sentinel in
  `StreamableByteBuffer`; `DateTime.now().toUtc()` →
  `DateTime.timestamp()` / `.millisecondsSinceEpoch`;
  `InboundCommandValidator` decodes only a 256-byte prefix and uses
  `indexOf` instead of `split(':')`;
  `AbstractUpdateVerbHandler._unsetOrRetainMetadata` rewritten as a
  field-by-field in-place merge — drops three per-update Map
  allocations; `(Mutex,int)` record replaced with mutable
  `MutexRef` holder; unused `AtData()` allocation removed)
- fix: `MonitorVerbHandler.MapForClient` uses `?.` for `ttr`/`ttl`/`ttb`
  to match its neighbours, so notifications without `atMetadata` no
  longer blow up
- fix: auth-error message unified across the validator and
  `AbstractVerbHandler.processInternal` — both now report
  `Command cannot be executed without auth`
- fix: config-driven cert reload (`config:set:checkCertificateReload=true`)
  now uses a 3-second force-restart fast path instead of waiting up to
  30 s for graceful drain
- chore: `DART_VM_OPTIONS` switched to comma-separated form so the Dart
  AOT runtime parses multiple flags correctly

# 3.11.3

- feat: tweak the garbage collection runtime flags

# 3.11.2

- feat: log value of Platform.executableArguments on startup

# 3.11.1

- feat: http handling tweak for more consistent behaviour for access via proxy 
  and direct access
- feat: log the values of DART_VM_OPTIONS during startup

# 3.11.0

- feat: make presentation of client certificates configurable for 
  atServer-to-atServer communication
- feat: dart runtime flags for more aggressive heap management
- fix: tighten FromVerbHandler hostname checking
- fix: immediately delete challenge-response secrets upon success in cram,
  pkam & pol handlers
- refactor: improve readability of cram verb handler digest checking
- feat: remove expired notifications on startup

# 3.10.3

- chore: remove obsolete configuration
- fix: set `AtNotifcation.defaultTtl` to value of config 
  `notificationExpiryInMins`

# 3.10.2

- fix: enforce consistent handling of notification expirations

# 3.10.1

- Defensive code to handle bad data in some very old atServers

# 3.10.0

- Overhaul notification handling
  - Bug-fixes
    - Check if notification has expired before sending to remote atServer
    - Ignore notifications from another atServer if we've already got them
      stored
    - Ignore notifications from another atServer if they have already expired
  - Enhancements
    - Removed complicated old internal machinery, replaced with streams-based
      approach
    - Made MonitorVerbHandler consistent with other verb handlers by ensuring
      that only one is needed, and the connection-to-monitor-config state is
      held in a map
    - Did various refactoring and cleanup of other code encountered
    - Improved performance in various places, mostly related to fetching
      notifications

# 3.9.4

 - build(deps): Add pubspec.lock and use ^ in pubspec.yaml

# 3.9.3

- fix: only allow `enroll:deny` to operate on `pending` enrollments

# 3.9.2

- fix: remove call to `flush` from `BaseSocketConnection.write()` thus
  preventing a race which was triggering a `StreamSink is bound to a stream`
  StateError

# 3.9.1

- chore: deal with breaking changes introduced by at_commons 5.8.0

# 3.9.0

- feat: Add `info` subcommands `info:mtls` and `info:mtlsbrief`

# 3.8.0

- feat: When available, present mtls client certs to other atServers, rather
  than presenting the server's server certs, which we can no longer depend
  on to have the client bit.

# 3.7.2

- fix: improved memory usage and error handling in StatsNotificationService. 
  Fixes a minor bug in StatsNotificationService which would only occur when 
  running an atServer on a development machine which is put to "sleep" for a 
  while.
- refactor: Removed unnecessary instance variable from StatsNotificationService

# 3.7.1
- feat : added `stats:16` for a summary of number of inbound connections by 
  type (self, other, anon) and `stats:17` for a detailed report on all 
  inbound connections including atSigns, time established, last accessed time.
- fix: better idle time defaults for inbound and outbound connections, 
  authenticated and unauthenticated 
- refactor: removed a bunch of singletons

# 3.7.0
- fix: better idle time defaults for inbound and outbound connections, 
  authenticated and unauthenticated 

# 3.6.0
- feat: Expanded http support

# 3.5.3
- fix: Set the trusted cacert path for AtSecondaryFinder

# 3.5.2
- fix: Prevent OutboundClient from creating new socket connections unnecessarily

# 3.5.1
- build: update version number to 3.5.1

# 3.5.0
- fix: scan verb now using AbstractVerbHandler.isAuthorized for namespace
  access checks by @gkc in https://github.com/atsign-foundation/at_server/pull/2276
- feat: Created Docker ephemeral enviroment for standalone atPlatform by 
  @cconstab in https://github.com/atsign-foundation/at_server/pull/2288
- feat: Update Dart version to 3.8.0 for Ephemeral Environment Dockerfile by 
  @cconstab in https://github.com/atsign-foundation/at_server/pull/2294
- feat: per-enrollment data by @gkc in https://github.
  com/atsign-foundation/at_server/pull/22

# 3.4.1
- fix: potential bugs handling atSigns which end in `data`

# 3.4.0
- feat: immutable records
  - When `immutable` is set in metadata, then the record may not
    subsequently be changed via the `update` verb.
  - When `immutable` is set in metadata, then the record may not be deleted
    via the `delete` verb unless the new `force` parameter is set
    - However, data which has been cached by the recipient is always 
      deletable by that recipient
# 3.3.0
- feat: Add support for "atServer events" - starting with the 
  `AtSignPKChangedEvent`. atServer events are stored in a newly reserved 
  namespace called `__atserver` to which all clients will have read access 
  but not write access - creating new atServer events is solely an atServer 
  responsibility. Clients will typically fetch events when they initially 
  connect, and will then handle appropriately (for example: store the event 
  information locally; handle it; mark as processed locally.) 
  Clients should keep a marker for the latest event they have 
  fetched so that when they restart they do not re-process past events. 
  Newly-created clients should set their initial marker to
  microsecondsSinceEpoch so that they do not process past events unnecessarily.
# 3.2.0
- feat: Added WebSocket support for inbound connections
# 3.1.1
- fix: Store "publicKeyHash" value in the keystore
- fix: add limit param in SyncProgressiveVerbHandler
- build[deps]: Upgraded the following package:
  at_commons to v5.1.2
# 3.1.0
- feat: sync skip deletes until changes 
- fix: Enable persistence of the Initialization Vector for "defaultEncryptionPrivateKey" and "selfEncryptionKey" in
  the APKAM flow.
- build[deps]: Upgraded the following package:
  - at_commons to v5.1.0
  - at_persistence_secondary_server to v3.1.0
# 3.0.52
- build[deps]: Upgraded the following package:
  - at_commons to v5.0.2
  - at_chops to v2.2.0
  - meta to v1.16.0
  - test to v1.25.9
  - args to v2.6.0
  - at_persistence_secondary_server to v3.0.66 to consume publicKeyHash changes.
## 3.0.51
- feat: Introduce option to unrevoke revoked enrollments
- feat: Introduce option to delete enrollments that are denied/revoked
- fix: LatestCommitEntryOfEachKey metric fixed to return commit log entries till last commitID instead of default limit 25.
- feat: Implement an option to automatically expire APKAM keys after a specified duration
- build[deps]: Upgraded the following package:
  - at_commons to v5.0.0
  - at_utils to v3.0.19
  - at_chops to v2.0.1
  - at_lookup to v3.0.49
  - at_persistence_secondary_server to v3.0.64
  - at_server_spec to v5.0.2
## 3.0.50
- fix: Enhance namespace authorisation check to verify when namespace has a period in it
- feat: Enable expiration of APKAM keys based on the specified duration.

## 3.0.49
- feat: Enforce superset access check for approving apps
- fix: respect isEncrypted:false if supplied in the notify: command, and 
  ensure that the correct value is always transmitted onwards
- fix: info verb no longer lists "beta" features which are now live
- fix: in MonitorVerbHandler, add "sharedKeyEnc" to the metadata to propagate the sharedEncryptedKey in
  notifications from the server to the client.
- build[deps]: Upgraded the following package:
  - at_persistence_secondary_server to v3.0.63

## 3.0.48
- feat Add expiresAt and availableAt params to notify:list response

## 3.0.47
- feat: Introduced a dedicated namespace for storing OTPs
- feat: allow a ttl to be set for a semi-permanent passcode (spp)

## 3.0.46
- fix: Default OTP expiry value remains unchanged for the subsequent "otp:" requests
- fix: Fix the handling of enrollment self-notifications

## 3.0.45
- fix: Update the response format of the "enroll:fetch" to match with "enroll:list" for consistency
- feat: enroll:revoke now has an optional "force" flag to allow current 
  connection to revoke its own enrollment
- fix: Fixed bug in delivery of notifications to APKAM Monitors

## 3.0.44
- fix: otp authentication check
- build[deps]: Upgraded the following packages:
  - at_commons to v4.0.8
  - at_server_spec to v5.0.1
  - at_lookup to v3.0.47
- feat: Add enroll:fetch to fetch the enrollment details.
- fix: Added validation to ensure a new enrollment request does not contain a duplicate combination of appName and
  deviceName.

## 3.0.43
- fix: ensure all connection writes are awaited

## 3.0.42
- feat: allow filtering of requests in EnrollVerbHandler using enrollment
  approval status
- feat: authorization changes for keys with no namespace and for reserved keys
- build(deps): dependabot changes
- fix: Improve socket handling for better server resilience
- fix: Ensure cached keys like 'cached:public:publicKey' are not considered 
  protected keys and can thus be deleted

## 3.0.41
- fix: bug in access control for otp put
## 3.0.40
- build[deps]: Upgraded the following packages: 
   - at_chops to 2.0.0
   - at_server_spec: to 4.0.1
- feat: at_server_spec: BREAKING: make AtConnection generic; make it more Dart-idiomatic
- feat: Do NOT add delete entries in commit log when expired keys are deleted
- feat: Introduce config to trigger skip_commits_for_expired_keys
- fix: Add enrollment "appName", "deviceName" and "namespace" to notification for apps listening on enrollment requests 
- fix: Return encryptedAPKAMSymmetricKey in enroll list
## 3.0.39
- build[deps]: Upgraded the following packages:
  - at_commons to v4.0.0
  - at_utils to v3.0.16
  - at_lookup to v3.0.44
  - at_chops to v1.0.7
  - at_persistence_secondary_server to v3.0.60
  - at_server_spec to 3.0.16
- feat: Improve enrollment usability by adding ability to create multi-use 'semi-permanent' enrollment passcodes
## 3.0.38
- Introduce a new config key to store an atsign's blocklist
## 3.0.37
- fix: In the `SyncProgressiveVerbHandler.prepareResponse` method, gracefully 
  handle any malformed keys which happen to be in the commit log for
  historical reasons
- build: Take up at_persistence_secondary_server version 3.0.59 which
  includes a similar fix when checking namespace authorization in the
  `CommitLogKeyStore._isNamespaceAuthorised` method
## 3.0.36
- fix: Implement notify ephemeral changes - Send notification with value without caching the key on receiver's secondary server
- feat: Implement AtRateLimiter to limit the enrollment requests on a particular connection
- fix: Upgraded at_commons to 3.0.56
- fix: Enable client to set OTP expiry via OTP verb
- fix: Prevent reuse of OTP
- fix: Modify sync_progressive_verb_handler to filter responses on enrolled namespaces if authenticated via APKAM 
## 3.0.35
- chore: Upgraded at_persistence_secondary_server to 3.0.57 for memory optimization in commit log
- feat: APKAM keys verb implementation
- feat: Implementation changes for latest APKAM specification
- Allow lookup verb for only authorized namespaces when authenticated via APKAM
- feat: Use at_lookup's CacheableSecondaryAddressFinder
- feat: Use latest at_lookup 3.0.40 which does retries in the event of 
  transient atDirectory connection failures while looking up atServer addresses
## 3.0.34
- chore: Upgraded at_persistence_spec to 2.0.14
- chore: Upgraded at_persistence_secondary_server to 3.0.56
## 3.0.33
- feat: Modified monitor verb handler to process self notification for APKAM
- chore: Upgraded at_persistence_secondary_server to 3.0.55 for memory optimization
- chore: Upgraded at_server_spec to 3.0.13, at_commons to 3.0.50 and at_utils 3.0.14
- feat: APKAM enroll verb handler implementation
## 3.0.32
- fix: Enhance stats verb to return latest commitEntry of each key
- chore: Ignore melos files
- chore: Uptake at_commons v3.0.46 which fixes failure of server when atSign
  has emoji with variation selector
- chore: Uptake at_utils v3.0.13 which enables logging to StandardError
- feat: Retain current inbound pool management logic, but be a **LOT** less 
  aggressive when closing idle **authenticated** inbound connections
## 3.0.31
- feat: Introduce clientId, appName, appVersion and platform to distinguish requests from several clients in server logs.
## 3.0.30
- fix: When metadata attributes are not set, merge the existing metadata attributes
- fix: When metadata attributes are explicitly set to null, reset the metadata
## 3.0.29
- fix: Check if connected atSign is authorized to send notifications
- feat: support new pkam verb syntax allowing for authentication using multiple signing and hashing algorithms
- feat: Support additional encryption metadata for encryption future-proofing
## 3.0.28
- fix: Refactor notify_verb_handler.dart to increase readability of code
- refactor: Add AtCacheManager so that we can handle all caching operations in one place
- refactor: Move cache-related operations from LookupVerbHandler and ProxyLookupVerbHandler into AtCacheManager
- test: Added unit tests covering full behaviour of LookupVerbHandler and ProxyLookupVerbHandler including caching
- feat: Handle resets of other atSigns by detecting changes to their public encryption keys
- test: Added unit tests covering behaviour when public encryption keys changes detected
- test: Added unit tests covering behaviour of the CacheRefreshJob
- fix: Cleaned up exception handling in a few places
- fix: Ensure no commit entries are left behind un-synced
## 3.0.27
- Upgrade at_persistence_secondary_server version to 3.0.46 for at_compaction
## 3.0.26
- Upgrade at_persistence_secondary_server version to 3.0.43
- Upgrade at_lookup version to 3.0.33
- Upgrade at_commons version to 3.0.32
## 3.0.25
- Upgrade at_persistence_secondary_server version to 3.0.40
- Upgrade at_commons version to 3.0.28
## 3.0.24
- chore: upgrade version of persistence_secondary, at_commons and at_lookup
- feat: Introduce Notify fetch verb
## 3.0.23
- fix: fixes to optimize the memory usage
- feat: Return error codes and JSON encode the error response
## 3.0.22
- feat: Add key validations
- feat: Enhance from verb to have client config
- fix: Handle invalid AtKey exception on server
## 3.0.21
- fix: invalidate commit log cache on key deletion
- feat: remove malformed keys on server startup
- fix: inbound connection pool test flakiness
- feat: encode the new line characters in the public key data
## 3.0.20
- fix: Bypass cache rename fix
- feat: Set isEncrypted to true when notify text message is encrypted.
- Update the at_lookup version to 3.0.28
- Update the at_persistence_secondary_server version to 3.0.30
## 3.0.19
- Upgrade at_persistence_secondary_server version to 3.0.28 which replaces null commitId(s) with hive internal key(s) on server startup
- Enhance scan verb to display hidden keys when showHiddenKeys is set to true
## 3.0.18
- Fix compaction when null commitId
- Fix issues in notifications and add tests
- No-op change to trigger build run
- Fix HandshakeException handling
## 3.0.17
- FEAT: Support to bypass cache
## 3.0.16
- Significant decreases in inter-at-sign notification latency from 1 to 6 seconds to 5 to 100 milliseconds
## 3.0.15
- Info verb now supports 'info:brief' usage
## 3.0.14
- Notify verb handler changes for shared key and public key checksum in metadata
- Inbound connection management improvements
- Update persistence version for hive upgrade
## 3.0.13
- Changes to add responses to queue from last in outbound message listener
- Uptake at_lookup version change for increase timeout for outbound connection
- Added compaction statistics to stats verb handler
- update verb and update meta verb handler changes for shared key and public key checksum in metadata
## 3.0.12
- Throw AtTimeoutException when connection timeouts
- Throw AtConnectException for error responses and unexpected responses
## 3.0.11
- Changes to support reset of ttb and ttl
## 3.0.10
- Workaround for signing private key not found issue.
## 3.0.9
- Enhance commit log compaction service.
- Notification expiry feature
## 3.0.8
- reduce compaction interval to 12 hrs
- compaction delete bug fix
## 3.0.7
- Commit log compaction
- Commit log will use in memory hive box. Other keystores will use lazy boxes.
## 3.0.6
- Rollback hive lazy box
## 3.0.5
- Uptake latest persistence - remove compaction strategy
## 3.0.4
- Fix NPE in commit log keystore.
## 3.0.3
- Change Hive box type to lazy box
## 3.0.2
- Remove logging of binary data
## 3.0.1
- Fix null aware issue in sync verb handlers
## 3.0.0
- Sync Pagination feature
## 2.0.7
- Reinitialize hive boxes on certs reload
## 2.0.6
- Fix for hive box closed issue
## 2.0.5
- Logs for hive box closed issue
## 2.0.4
- Last notification time support in Monitor
## 2.0.3
- Support for stream verb resume
