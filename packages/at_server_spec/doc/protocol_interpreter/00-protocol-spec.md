# atProtocol specification — stripped for grammar/AST work

**Primary source: `at_commons/lib/src/verb/syntax.dart`** (resolved version
in this repo: `at_commons-5.19.0`, per `pubspec.lock`), not the upstream
[`atsign-foundation/at_protocol`](https://github.com/atsign-foundation/at_protocol)
specification doc. The upstream doc was used as a starting point for a first
draft of this file, but **it's stale** — cross-checking every verb against
the actual `VerbSyntax` regex source (the thing the legacy `RegExp`-based
parsing path in `at_secondary_server` actually implements) turned up several
real protocol features the upstream doc doesn't mention at all. See
"Corrections vs. the upstream spec" below. Treat `syntax.dart` as the
authority going forward; re-derive this file from it again if at_commons is
upgraded.

This is Stage 1 of `03-implementation-plan.md`: the source of truth the AST
node shapes (Stage 2) and conformance fixtures (Stage 3) are derived from
and checked against.

It deliberately drops deployment topology, connection-lifecycle narrative,
cryptographic walkthroughs, and worked end-to-end flows — none of those
change what a parser or AST needs to represent. For that material, see the
upstream spec (keeping its staleness on verb syntax in mind).

## Corrections vs. the upstream spec

Found by reading `at_commons-5.19.0/lib/src/verb/syntax.dart` and
`enroll_params.dart`/`operation_enum.dart` directly, and
`at_secondary_server`'s `stats_verb_handler.dart` for the stat ID table
(which lives server-side, not in at_commons at all — the upstream doc's
table was never sourced from an authoritative location):

- **`pkam` has a third signing algorithm**, `mldsa65` (post-quantum,
  ML-DSA), alongside `rsa2048`/`ecc_secp256r1` — not in the upstream doc at
  all (`syntax.dart:9-10`).
- **`enroll` has more operations than documented**: `listns`, `infons`, and
  `update` exist alongside `request|approve|deny|revoke|list|fetch|unrevoke|delete`
  (`syntax.dart:157-159`, `operation_enum.dart`'s `EnrollOperationEnum`).
  `enroll:update` is a self-only operation letting an *approved* enrollment
  rotate its own `apkamPublicKey`/`signingAlgo`/`apsk`/`metadata` — it
  cannot touch `namespaces` or approval state (`operation_enum.dart`
  doc comment). `EnrollParams` also carries PQ-migration fields entirely
  absent from the upstream doc: `signingAlgo`, `apsk` (structured signing-key
  package), `apskLegacy` (bare RSA key, for pre-PQ consumers),
  `apkamPublicKeySignature` (proof of possession, required on a key-rotating
  `enroll:update`), and `metadata` (opaque, carries `keyPackage` for secret
  sharing) — see `enroll_params.dart:30-119`.
- **`notify` carries two fields the upstream doc omits**: `eAtn`
  (`notificationExpiresAt`, same ISO-8601 shape as the metadata fragment's
  timestamps) and a bare `eph` flag (ephemeral), both positioned between
  `ttln` and the metadata fragment (`syntax.dart:117-132`,
  `_notificationExpiryAndPersistence` at `:150-152`).
- **`stats` has 17 metrics, not 6.** The upstream doc's 6-row table doesn't
  match any authoritative source — the real list lives in
  `at_secondary_server/lib/src/verb/handler/stats_verb_handler.dart:19-57`
  (`Metric` enum + `statsMap`), not in at_commons at all. Full corrected
  list is below.
- **`update:meta`'s field order differs from `update`'s.** In `update`, the
  metadata fragment comes *before* the public/forAtSign scope and atKey
  (`syntax.dart:62-73`). In `update:meta`, the atKey and atSign come
  *first*, and the metadata fragment comes *after* and is itself the tail
  of the pattern (`syntax.dart:76-82`). The upstream doc's "same metadata
  fragment + atKey addressing as `update`" phrasing obscures this — the
  shapes are structurally different, not just a renamed copy.
- **`lookup`, `plookup`, and `llookup` have three different atKey character
  classes**, not one shared shape as the upstream doc implies:
  - `lookup`: `(?:[^:]).+` — first char non-colon, then anything (loosest).
  - `plookup`: `[^@\s]+` — no `@` or whitespace, colons freely allowed.
  - `llookup`: `[^:]((?!:{2})[^@])+` — first char non-colon, rest excludes
    `@` and a literal `::`.
  A real parser/AST cannot treat these three as interchangeable.
- **`delete`'s atKey alternation includes a reserved-key literal**,
  `privatekey:at_secret`, parallel to (but different from) `update`'s own
  special-cased `privatekey:at_pkam_publickey` literal (`syntax.dart:90`
  vs. `:69`). The upstream doc doesn't mention either special case for
  `delete`.
- **`notify`'s public/forAtSign scope is required, not optional** — no `?`
  wraps that group in the regex (`syntax.dart:128`), unlike `update`'s and
  `llookup`'s, where it's optional. The upstream doc's bracket notation
  (`[public|@<forAtSign>]`) reads as optional for all of them.
- **`notify:all`'s `ccd` pattern is `true|false+`** (literally `false`
  followed by one-or-more trailing `e`s — i.e. `fals` + `e+`), a real regex
  quirk, not `true|false` like everywhere else (`syntax.dart:143`). A real
  lexer/parser needs to special-case this exact pattern rather than reusing
  the plain `bool` rule used for every other boolean field.
- **`config`'s actual shape is narrower and differently-grouped** than the
  upstream doc's bullet list suggests: it's one regex with two top-level
  alternatives — `block:<add|remove|show>` (with atSigns only for
  add/remove) OR `<set|reset|print>:<configNew>` where `configNew` is
  undifferentiated free text (`syntax.dart:28`) — not five independently
  documented sub-commands.
- **The `stream` verb still exists in `syntax.dart`** (`:114-115`) and is
  not flagged deprecated there, even though its regex is loose/ambiguous
  enough that it's a reasonable candidate to deprioritize when building a
  real grammar for it. The upstream doc marks it legacy (Appendix B.5);
  at_commons itself does not.
- **One error code the upstream doc's table omits**: `AT0030`, "Invalid
  Enrollment Status" (`at_commons-5.19.0/lib/src/exception/error_message.dart:58`).

## Shared wire rules

- **Framing:** one verb per line, `\n`-terminated. Responses are
  `data:<payload>\n@<atSign>@` (authenticated) or `data:<payload>\n@`
  (unauthenticated) — except `pol`, `monitor`, and `stream`, which frame
  differently (Quirks, D.3).
- **Case:** verb names and literal tags/flags are matched
  case-insensitively; captured free values (atKeys, JSON, free text) are
  case-preserving.
- **Newline escaping:** `~NL~` escapes a literal `\n` inside a value, but
  only for plaintext public values — encrypted/binary values are already
  base64 and never contain a raw newline (D.9).
- **Error framing:** `error:<code>-<message>` or `error:<code>:<message>`
  — both separator forms are live; a parser/client must accept either (D.1).

## The atKey model

(Not sourced from `syntax.dart` — this is at_commons' `AtKey` shape, a
separate concern from verb grammar. Carried over from the upstream doc,
not independently re-verified in this pass; re-check against
`at_commons/lib/src/key/at_key.dart` before relying on it for Stage 2 node
shapes.)

| Shape   | Wire format                                | Visibility                                        |
|---------|---------------------------------------------|----------------------------------------------------|
| Public  | `public:<key>[.<namespace>]@<owner>`       | Any atSign, no auth needed (`plookup`)             |
| Self    | `<key>[.<namespace>]@<owner>`              | Owner only                                         |
| Shared  | `@<recipient>:<key>[.<namespace>]@<owner>` | Owner and `<recipient>` only                       |
| Local   | `local:<key>[.<namespace>]@<owner>`        | Owner only; never synced                           |
| Private | `privatekey:<key>[.<namespace>]@<owner>`   | Owner only; not enumerated by `scan`               |

- **Hidden**: `<key>` part starts with `_`; omitted from `scan` unless
  `:showhidden:true`.
- **Cached**: `cached:public:<key>@<owner>` or `cached:@<recipient>:<key>@<owner>`.
- **Namespace**: trailing `.<namespace>`; part of the APKAM authorization
  surface. May be omitted for infrastructural keys.
- **Max length**: 255 characters on the wire.

Reserved keys: `public:publickey@<atSign>`, `public:signing_publickey@<atSign>`,
`privatekey:at_pkam_publickey`, `privatekey:at_pkam_privatekey`,
`privatekey:privatekey`, `privatekey:self_encryption_key`,
`privatekey:at_secret`, `<atSign>:shared_key@<atSign>`,
`private:blocklist@<atSign>`.

## The metadata fragment

Source: `at_commons-5.19.0/lib/src/verb/syntax.dart:37-60`
(`VerbSyntax.metadataFragment`). A sequence of `:tag:value` segments
embedded in `update`, `notify`, and (in a different position — see
Corrections above) `update:meta`. **Order is fixed and enforced** (D.11).

| Wire tag | Type | Notes |
|---|---|---|
| `ttl` | int, `(-?)\d+` | Time-to-live (ms); `0`/omitted = never expires. Negative values are accepted by the regex but mostly meaningless (D.14). |
| `ttb` | int, `(-?)\d+` | Time-to-birth (ms). |
| `ttr` | int, `(-?)\d+` | Cache refresh interval (ms); `-1` = cache forever (the one negative value that's meaningful). |
| `ccd` | bool, `true\|false` | Cascade-delete cached copies on original delete. |
| `cAt` | ISO 8601 | `createdAt`. `\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z` |
| `uAt` | ISO 8601 | `updatedAt`. |
| `eAt` | ISO 8601 | `expiresAt`. |
| `aAt` | ISO 8601 | `availableAt`. |
| `dataSignature` | `[^:@\s]+` | Signature over a public value. |
| `sharedKeyStatus` | `[^:@\s]+` | Lifecycle status string. |
| `isBinary` | bool | Value is base64-encoded binary. |
| `isEncrypted` | bool | Value is ciphertext. |
| `sharedKeyEnc` | `[^:@\s]+` | RSA-wrapped shared symmetric key. |
| `pubKeyCS` | `[^:@\s]+` | **Deprecated**, predecessor of `pubKeyHash` (D.16). Note: appears *before* `pubKeyHash` in the regex's own field order, despite being the newer field's predecessor. |
| `pubKeyHash` | `[^:@\s]+` | Hash of the recipient public key that encrypted `sharedKeyEnc`. |
| `hashingAlgo` | `[^:@\s]+` | Algorithm for `pubKeyHash` (not a closed enum at the grammar level — any non-colon/at/space token matches; `sha256`/`sha512` is an application-level convention). |
| `encoding` | `[^:@\s]+` | e.g. `base64`. |
| `encKeyName` | `[^:@\s]+` | Symmetric key name used to encrypt the value. |
| `encAlgo` | `[^:@\s]+` | Symmetric algorithm. |
| `ivNonce` | `[^:@\s]+` | Base64 IV/nonce. |
| `skeEncKeyName` | `[^:@\s]+` | Public key name that wrapped `sharedKeyEnc`. |
| `skeEncAlgo` | `[^:@\s]+` | Algorithm used to wrap `sharedKeyEnc`. |
| `immutable` | bool | If true, delete requires `:force:`. |
| `appMetadata` | `[^:@\s]+` | Opaque app-level metadata. |

Canonical (regex-declared) order: `ttl, ttb, ttr, ccd, cAt, uAt, eAt, aAt,
dataSignature, sharedKeyStatus, isBinary, isEncrypted, sharedKeyEnc,
pubKeyCS, pubKeyHash, hashingAlgo, encoding, encKeyName, encAlgo, ivNonce,
skeEncKeyName, skeEncAlgo, immutable, appMetadata`.

## Verbs: syntax, fields, response

Each entry cites its `syntax.dart` line(s) directly rather than
paraphrasing, since paraphrasing is exactly what let the upstream doc drift.

### Authentication

**`from`** (`:5-6`) — `from:<atSign>[:clientConfig:<json>]`. `clientConfig`
free-form JSON; only `version`, `clientId`, `appName`, `appVersion`,
`platform` are read server-side, rest discarded (D.12). Response shape
differs self vs. cross-atSign (D.6).

**`pol`** (`:7`) — `pol`, no arguments. Server-emitted inter-atServer
handshake only. Response has no `data:` prefix, no trailing prompt (D.3).

**`cram`** (`:8`) — `cram:<digest>`. Bootstrap-only.

**`pkam`** (`:9-10`) — `pkam:[signingAlgo:<rsa2048|ecc_secp256r1|mldsa65>:][hashingAlgo:<sha256|sha512>:][enrollmentId:<id>:]<signature>`.
Defaults: `signingAlgo:rsa2048`, `hashingAlgo:sha256`. `mldsa65` is the
post-quantum option (see Corrections).

### APKAM

**`enroll`** (`:157-159`) — `enroll:<request|approve|deny|revoke|listns|infons|list|fetch|unrevoke|delete|update>[:force][:<listNamespace>][:<enrollParams-json>]`.
`EnrollParams` fields (`enroll_params.dart`): `enrollmentId`, `appName`,
`deviceName`, `namespaces` (map `namespace → r|w|rw|rwx`), `otp`,
`apkamPublicKey`, `encryptedAPKAMSymmetricKey`,
`encryptedDefaultEncryptionPrivateKey`, `encPrivateKeyIV`,
`encryptedDefaultSelfEncryptionKey`, `selfEncKeyIV`, `signingAlgo`,
`apsk`, `apskLegacy`, `apkamPublicKeySignature`, `metadata`,
`enrollmentStatusFilter`, `apkamKeysExpiryDuration`. `enroll:request` is
the one mutating verb that doesn't require auth (D.8) — the OTP is the
credential surrogate. `enroll:update` is self-only (see Corrections).

**`otp`** (`:160-161`) — `otp:get[:ttl:<ms>]` or `otp:put:<otp>[:ttl:<ms>]`,
`<otp>` is `\w{6,}`, owner-auth.

**`keys`** (`:162-170`) — being deprecated.
`keys:<put|get|delete>[:public|private|self]?[:namespace:<ns>]?[:appName:<n>]?[:deviceName:<n>]?[:keyType:<t>]?[:encryptionKeyName:<n>]?[:keyName:<n> ]?<keyValue>`.
Note the trailing `keyValue` is `.*` — always matches, even empty.
`keys:put` returns the sentinel `data:-1` (D.7).

### CRUD

**`update`** (`:62-73`) — positional:
`update[:nc]<metadataFragment>[:(public|@<forAtSign>)]:<atKey>[@<atSign>] <value>`;
JSON: `update[:nc]:json:<json>`. atKey alternation:
`[^:@\s]+` OR the literal `privatekey:at_pkam_publickey`. `:nc` suppresses
the commit-log entry. Response: `data:<commitId>`.

**`update:meta`** (`:76-82`) — `update:meta[:nc]:[(public|@<forAtSign>)]:<atKey>@<atSign><metadataFragment>`.
**Field order differs from `update`** — atKey/atSign come before the
metadata fragment here, not after (see Corrections). atKey class:
`[^:@]((?!:{2})[^:@])+` (excludes both `:` and `@` throughout, not just
`:`).

**`delete`** (`:83-92`) — `delete[:dAt:<ISO8601>][:nc][:force][:priority:<low|medium|high>][:cached][:(public|@<forAtSign>)]:<atKey>[@<atSign>]`.
atKey alternation: `[^:@\s]+` OR the literal `privatekey:at_secret`.
`:force` required for `immutable:true`. Idempotent (D.13): always
`data:<commitId>`, even for a missing key.

**`lookup`** (`:19-20`) — `lookup[:bypassCache:<true|false>]:[(meta|all):]<atKey>@<atSign>`.
atKey class: `(?:[^:]).+` (loosest of the three lookup variants — see
Corrections). Cross-atSign, authenticated.

**`plookup`** (`:17-18`) — `plookup[:bypassCache:<true|false>]:[(meta|all):]<atKey>@<atSign>`.
atKey class: `[^@\s]+` (allows colons). Unauthenticated, public keys only.

**`llookup`** (`:11-16`) — `llookup[:(meta|all)][:cached][:(public|@<forAtSign>)]:<atKey>@<atSign>`.
atKey class: `[^:]((?!:{2})[^@])+` (excludes `@` and a literal `::`, not
just the first char). Local-server-only.

**`scan`** (`:21-26`) — `scan` OR
`scan[:cl][:showhidden:<true|false>][:@<forAtSign>][:page:<n>][ <regex>]`.
Response: `data:[<atKey>, ...]`.

### Notifications

**`notify`** (`:117-132`) — `notify[:id:<id>][:(update|delete)][:messageType:key][:priority:<low|medium|high>][:strategy:<all|latest>][:latestN:<n>][:notifier:<n>][:ttln:<ms>][:eAtn:<ISO8601>][:eph]<metadataFragment>:(public|@<forAtSign>):<atKey>[@<atSign>][:<value>]`.
The scope segment (`public`/`@<forAtSign>`) is **required**, not optional
(see Corrections). atKey class: `[^:@]((?!:{2})[^@])+`. `eAtn`/`eph` are
undocumented upstream (see Corrections). Response: `data:<notificationId>`.

**`notify:all`** (`:137-145`) — `notify:all:[(update|delete):][messageType:(key|text):][ttl:<\d+>:][ttb:<\d+>:][ttr:<-?\d+>:][ccd:<true|false+>:]<forAtSign-list>:<atKey>[@<atSign>][:<value>]`.
Uses its own numeric/bool classes, **not** the shared `metadataFragment`
(`ttl`/`ttb` here are unsigned, `ttr` signed, `ccd` is the `true|false+`
quirk — see Corrections). `forAtSign-list` is comma-separated, no `@`
prefix per recipient. Response: `data:{"<recipient>":"<notificationId>", ...}`.

**`notify:list`** (`:133-134`) — `notify:list[:<fromDate>][:<toDate>][:<regex>]`,
dates loosely `\d{4}-[01]?\d?-[0123]?\d?` (not a strict calendar-date
check). Not end-anchored in the regex. Semantics flip on auth mode (D.5).

**`notify:status`** (`:135`) — `notify:status:<notificationId>` (`\S+`).

**`notify:fetch`** (`:136`) — `notify:fetch:<notificationId>` (`\S+`).

**`notify:remove`** (`:156`) — `notify:remove:<id>`, id class
`[\w\d\-\_]+`. Not start-anchored in the regex (no leading `^`). Log
housekeeping only.

**`monitor`** (`:107-113`) — `monitor[:strict][:selfNotifications][:multiplexed][:<epochMillis>][ <regex>]`.
Streaming response, no `data:` prefix per line (D.3).

**`stream`** (`:114-115`) — regex is loose/ambiguous enough that it's a
reasonable candidate to leave for last when building out the real grammar.
Still present in `at_commons`, not flagged deprecated there (see
Corrections). `stream:[(init|send|receive|done|resume)][@<receiver>][ namespace:<ns>][ startByte:<n>][ <streamId>][ <fileName> ][<length>]`.

### Sync

**`sync:from`** (`:33-34`) — `sync:from:<from_commit_seq>[:limit:<n>][:skipDeletesUntil:<n>][:<regex>]`,
`from_commit_seq` is `[0-9]+|-1`. Legacy `sync:<seq>[:<regex>]`
(`:32`, `@Deprecated`) still present for compatibility.

### Server-admin / utility

**`config`** (`:28`) — one regex, two shapes (see Corrections):
`config:block:(add|remove):<@atSign>[ @<atSign>...]` or `config:block:show`,
OR `config:(set|reset|print):<configNew>` where `configNew` is
undifferentiated free text (e.g. `key=value` for `set`, just `key` for
`reset`/`print`, but the grammar itself doesn't distinguish — that split is
application-level).

**`stats`** (`:29-30`) — `stats[:<id>[,<id>...]][:<regex>]`, regex only
meaningful after specific IDs (`(?<=:3:|:15:)` lookbehind in the regex).
Corrected 17-entry metric table (`at_secondary_server`'s
`stats_verb_handler.dart:19-57`):

| ID | Metric |
|----|--------|
| 1 | `INBOUND` (active inbound connections) |
| 2 | `OUTBOUND` (active outbound connections) |
| 3 | `LASTCOMMIT` |
| 4 | `SECONDARY_STORAGE_SIZE` |
| 5 | `MOST_VISITED_ATSIGN` |
| 6 | `MOST_VISITED_ATKEYS` |
| 7 | `SECONDARY_SERVER_VERSION` |
| 8 | `LAST_LOGGEDIN_DATETIME` |
| 9 | `DISK_SIZE` |
| 10 | `LAST_AUTH_TIME` |
| 11 | `NOTIFICATION_COUNT` |
| 12 | `COMMIT_LOG_COMPACTION` |
| 13 | `ACCESS_lOG_COMPACTION` |
| 14 | `NOTIFICATION_COMPACTION` |
| 15 | `LATEST_COMMIT_ENTRY_OF_EACH_KEY` |
| 16 | `INBOUND_SUMMARY` |
| 17 | `INBOUND_DETAILED` |

**`info`** (`:154`) — `info[:(brief|mtls|mtlsbrief)]`. Auth requirement is
a per-deployment toggle (D.15).

**`noop`** (`:155`) — `noop:<delayMillis>` (`\d+`, app-level cap of 5000).

**`batch`** (`:153`) — `batch:<json>`, array of `{"id":<n>,"command":"<verb>"}`.

## Error taxonomy

Source: `at_commons-5.19.0/lib/src/exception/error_message.dart` (code ↔
class/message) and `at_exception_utils.dart` (code → exception instance,
a strict subset — several codes below have no entry there and fall through
to a generic `AtException`, which is itself worth knowing for Stage 6).

| Code | Message | Relevant to |
|---|---|---|
| `AT0001` | Server exception | execution |
| `AT0002` | DataStore exception | execution (no entry in `at_exception_utils`'s switch) |
| `AT0003` | Invalid syntax | lexical/syntax |
| `AT0004` | Socket error | execution (no entry in the switch) |
| `AT0005` | Buffer limit exceeded | lexical (oversized input) |
| `AT0006` | Outbound connection limit exceeded | execution |
| `AT0007` | atServer/Secondary server not found | execution |
| `AT0008` | Handshake failure | execution |
| `AT0009` | UnAuthorized client (authenticated, lacks permission) | semantic/authorization |
| `AT0010`/`AT0011` | Internal server error/exception | execution |
| `AT0012` | Inbound connection limit exceeded | execution |
| `AT0013` | Connection Exception (blocked) | execution |
| `AT0014` | Unknown AtClient exception | client-only (no entry in the switch) |
| `AT0015` | Key not found | execution |
| `AT0016` | Invalid key | semantic (atKey shape) (no entry in the switch) |
| `AT0021` | Unable to connect | execution |
| `AT0022` | Illegal arguments | semantic (value-range checks, e.g. TTR) |
| `AT0023` | Timeout waiting for response | execution |
| `AT0024` | Server is paused | execution |
| `AT0025` | Apkam Auth Denied | semantic/authentication (no entry in the switch) |
| `AT0026` | Apkam Auth Failed | semantic/authentication (no entry in the switch) |
| `AT0027` | Apkam Access Revoked | semantic/authentication (no entry in the switch) |
| `AT0028` | Too Many Requests | execution (throttle) |
| `AT0029` | Apkam Enrollment Expired | semantic/authentication |
| `AT0030` | Invalid Enrollment Status | semantic — **missing from the upstream doc's table entirely** |
| `AT0031` | Cannot revoke self enrollment | semantic |
| `AT0032` | Illegal state | execution |
| `AT0401` | Client authentication failed | semantic/authentication |

Maps onto Stage 6's proposed `LexicalError`/`SyntaxError`/`SemanticError`/
`ExecutionError` taxonomy per the "Relevant to" column above. `AT0009` vs.
`AT0401`/`AT0025`-`AT0027`/`AT0029` is the authorization-vs-authentication
split a correct taxonomy must preserve — see upstream §17.2.

## Quirks that affect grammar/parser correctness

The subset of the upstream spec's Appendix D that's still accurate and
actually constrains a grammar or AST (cross-checked against `syntax.dart`
while rewriting this file):

- **D.11 — Metadata fragment is order-sensitive.** Enforced by regex
  position; a real grammar/parser must enforce order too, not just accept
  all tags and sort afterward.
- **D.9 — Newline escaping is value-class-specific.**
- **D.14 — Negative metadata integers are mostly meaningless.** Syntax
  accepts them (`(-?)\d+`); only semantic validation decides `ttr:-1` is
  useful and `ttl:-1`/`ttb:-1` aren't.
- **D.6 — `from` response shape differs self vs. cross.** Response
  serialization (Stage 6), not request parsing.
- **D.7 — `keys:put` returns `data:-1`.** A sentinel, not a real commit ID.
- **D.13 — `delete` is idempotent.**
- **D.3 — Per-verb response framing differs** (`pol`, `monitor`, `stream`),
  but this does **not** mean the encoder needs live connection access —
  see `02-architecture.md`'s "Package boundaries" and `04-decisions.md`
  D5 for the corrected breakdown: framing selection is a pure function of
  verb type, the one genuinely connection-dependent piece (the trailing
  prompt) is a single string passed in as a parameter, and `monitor`/
  `stream` bypass response encoding entirely rather than being framing
  variants of it.
- **D.12 — `clientConfig` JSON is unenforced free-form.**

## What this doc deliberately excludes

Deployment topology, transport/connection-lifecycle detail, the full
end-to-end-encryption model, worked multi-step flows, and the inter-atServer
protocol narrative — none of these change what a verb's syntax, fields, or
response shape are, which is the only thing Stages 1-7 of this migration
need. Consult `at_commons` source directly (not the upstream doc, per the
corrections above) for anything not covered here, and the upstream spec for
narrative/rationale once its verb-syntax claims are cross-checked.
