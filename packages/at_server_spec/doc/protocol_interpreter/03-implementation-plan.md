# AST migration — implementation plan

Six stages, each independently shippable and low-risk on its own, each
aimed at the end architecture in `02-architecture.md`. See
`04-decisions.md` for the rationale behind the sequencing and the key
architectural calls.

## Stage 1 — Protocol specification (`00-protocol-spec.md`) — done

**What:** For each verb: name, purpose, syntax, required/optional fields,
valid values per field, response shape, error conditions — plus shared
rules (identifier format, escaping, atSign/atKey shape, case sensitivity)
defined once. Written as `00-protocol-spec.md`, sourced directly from
`at_commons/lib/src/verb/syntax.dart` (resolved version `5.19.0` in this
repo) rather than transcribed from the upstream
[atsign-foundation/at_protocol](https://github.com/atsign-foundation/at_protocol)
doc — the latter was used as an initial draft but turned out to be stale on
several real verb features (ML-DSA `pkam` signing, `enroll:listns`/
`infons`/`update`, `notify`'s `eAtn`/`eph`, the real 17-metric `stats` list,
`update:meta`'s field order, and more — full list in
`00-protocol-spec.md`'s "Corrections vs. the upstream spec"). Also includes
the error taxonomy (from `at_commons`' `error_message.dart`, not the
upstream table, which was missing a code) and the subset of quirks
(order-sensitivity, idempotency, framing differences) that constrain
grammar/parser correctness, feeding Stage 6 directly.

**Why safe:** pure documentation, zero code risk.

**Verify:** once Stage 3's grammar/parser exists, diff the spec's field
list per verb against that grammar's declared fields, so the spec and the
implementation can't silently drift apart.

## Stage 2 — AST / message model

**What:** Define one domain node class per verb (`UpdateCommand`,
`LookupCommand`, `DeleteCommand`, ...), shaped from Stage 1's spec. Nodes are new
immutable classes under a `sealed class Command` in `at_server_spec`
(`lib/src/ast/`), self-contained (no at_commons types; conversions to
`UpdateParams`/`Metadata` are added in Stage 5 where handlers need them) —
not a speculative generic `VerbNode`/`Statement`/`Expression` hierarchy
(see `04-decisions.md` D1, D2). **Done:** all 31 nodes (every verb in
`lib/src/verb/`, with `update`/`update:json` and `config:block`/`config`
each split into two nodes), plus `MetadataFragment`, `KeyScope`, and the
closed enums. Conventions are documented on `Command`: atSigns stored
without `@`; bare flags are `bool`, explicit-value tags nullable; free
text (JSON, regexes, loose dates) kept raw.

**Why safe:** plain data classes, no parsing logic, nothing consumes them
yet.

**Verify:** unit tests constructing each node directly and asserting
field access/equality — no parser involved.

## Stage 3 — Token model, lexer, and recursive-descent parser

**What:** Build the real parsing pipeline directly — a `Token`/`TokenType`
model with source offsets (for real error positions), a `ProtocolLexer`
turning a command string into a token stream (lexical concerns only:
whitespace, escaping, quoting, identifiers, numbers, punctuation, no
knowledge of which verb requires which arguments), and a hand-written
`ProtocolParser` with one method per grammar rule from Stage 1's spec,
producing Stage 2's AST nodes directly. Migrate one verb at a time,
starting with a structurally simple one (e.g. `delete` or `llookup`)
rather than `update`, which has the most branches and the metadata
fragment.

**Why sequenced after Stages 1-2, not first:** see `04-decisions.md` — the
token model + hand-written parser is the single largest, hardest-to-unwind
piece of new machinery in this migration, so it's built against an
already-settled target (spec, AST shape) rather than co-evolving with it.

**Verify:** build conformance fixtures — `(command string -> expected AST)`
pairs per verb, covering every branch in that verb's Stage 1 spec entry.
Check the new lexer/parser against these fixtures directly. Separately,
differentially test against the legacy `RegExp(VerbSyntax.*)` +
`processMatches` path for the same commands (matching `Groups`-shaped
output via a `AST -> Groups` projection) to catch any unintended behavior
drift from the regex baseline before a verb is considered migrated. Known
blind spot: `(:cached)?` in `VerbSyntax.delete` and `VerbSyntax.llookup` is
not a named group, so the legacy map can't observe `cached` — that field
must be checked by fixtures only and excluded from the projection.
The projection must also re-add `@` where the legacy regex captures it
(`from`'s optional `@`, `scan`'s `forAtSign`, `config:block`'s list), and
map `notify:all`'s `ccd:false+` quirk back to its raw spelling.

## Stage 4 — Semantic validation layer

**What:** Consolidate validation logic currently inline in handler code
(`hu.validateTTR` and `validateCacheMetadata` in
`packages/at_secondary_server/lib/src/utils/handler_util.dart:17,26`;
reserved-key/permission checks scattered through handlers) into a
`ProtocolValidator` operating on Stage 2's AST nodes, instead of on the raw
string map.

**Why safe:** new pure functions (`AST -> ValidationResult`) per verb,
addable without touching the parsing path. Existing inline handler
validation stays in place until Stage 5.

**Verify:** unit tests feeding hand-built valid/invalid AST nodes to the
validator, asserting accept/reject with the right reason.

## Stage 5 (after Stage 3 is proven for at least one verb) — Dispatcher and typed handlers

**What:** Introduce `dispatch(ProtocolMessage, ProtocolContext) -> ProtocolResponse`
in `at_secondary_server`, and change handler signatures verb-by-verb from
taking the raw string map to taking the typed AST node (e.g.
`handlePut(PutCommand command)` instead of indexing `verbParams[...]`).
This directly removes the duplicated `int.parse`/`DateTime.parse`/
`AtMetadataUtil.getBoolVerbParams` coercion documented in
`01-acceptance.md` from `abstract_update_verb_handler.dart` and the other
handler files, since the AST already carries typed, Stage-4-validated
fields. Gate each verb's cutover with a `supports(verb)`-style check so
each verb's migration is isolated and revertible. Unmigrated verbs keep
using the current `getVerbParam` / `RegExp(verb.syntax())` /
`processMatches` path
(`packages/at_secondary_server/lib/src/utils/handler_util.dart:7`,
`regex_util.dart:13`) untouched.

**Verify:** existing at_secondary_server handler tests for the migrated verb
pass unmodified (they test outcomes, not parsing internals). Add an
end-to-end regression test per migrated verb comparing server responses
with the new path vs. the old one for a representative command set, then
retire the comparison once confident.

## Stage 6 (can run in parallel with 3/4/5, lower priority) — Typed responses, serialization, error model

**What:**
- `ProtocolResponse` types per verb and a `ResponseEncoder` to wire format,
  living entirely in **`at_server_spec`**, not `at_secondary_server` —
  serialization is a pure `typed response → wire string` transform with no
  I/O, the exact mirror of parsing (`wire string → typed AST`), so it
  belongs on the no-I/O side of the package boundary (`02-architecture.md`,
  "Package boundaries"). `at_secondary_server`'s dispatcher/handlers
  (Stage 5) only decide *which* typed response to produce and hand it to
  this encoder, along with the one piece of connection state the encoder
  needs — the trailing prompt string (`$atSign@` / `$fromAtSign@` / `@`) —
  passed in as a plain parameter, not by giving the encoder connection
  access. Verified against the actual response-handling code that framing
  selection is purely a function of verb type (no connection object
  needed), and that `monitor`/`stream` aren't framing variants at all —
  they bypass response encoding entirely via a separate streaming push
  mechanism, which is a future design question of its own, not part of
  this stage. See `02-architecture.md`'s "Package boundaries" for the full
  breakdown.
- An error taxonomy (`LexicalError`, `SyntaxError`, `SemanticError`,
  `ExecutionError`) replacing the current collapse into
  `InvalidSyntaxException` (`handler_util.dart:11`), mapped from Stage 3's
  lexer/parser failures and Stage 4's validation failures respectively,
  each carrying the source position from Stage 3's `Token` offsets. Also
  lives in `at_server_spec`, for the same no-I/O reason.

**Why lower priority / parallel:** orthogonal to the incoming-parsing work;
doesn't block or get blocked by Stages 1-5, but shares the same AST node
shapes and is natural to do once those stabilize for a verb.

**Verify:** encoder round-trip tests per response type; error-taxonomy
tests asserting the right category/message/position for representative
malformed commands at each layer.

## Tests at each boundary (ongoing, not a separate stage)

Structure tests per boundary as each stage lands: lexer tests (input →
tokens), parser tests (tokens → AST), validator tests (AST → valid/error),
dispatcher tests (AST → handler/result), end-to-end wire tests (command
string → wire response). Stage 3's conformance fixtures (command → expected
AST) are reusable beyond this codebase — if atProtocol ever gets another
implementation, they become a shared conformance suite.

## Sequencing and dependencies

1. Protocol spec — no dependencies, do first.
2. AST node shapes — depends on 1.
3. Real token/lexer/parser, verb-by-verb — depends on 1, 2; the biggest
   single stage.
4. Semantic validation over AST — depends on 2 (and 3 for real parsed
   inputs to validate).
5. Dispatcher + typed handlers in at_secondary_server — depends on 3 (at
   least one verb proven) and 4.
6. Typed responses/serialization/error model — depends on 2; can run
   alongside 3/4/5.
7. Per-boundary tests — ongoing alongside every stage above.

## Critical files

- `packages/at_commons/lib/src/verb/syntax.dart` (Stage 1/3 — the grammar
  source of truth; external dependency, read-only)
- new `packages/at_server_spec/lib/src/ast/` (or similar) for Stage 2's
  per-verb node classes
- new `packages/at_server_spec/lib/src/lexer/` and `lib/src/parser/` (or
  similar) for Stage 3's `Token`/`TokenType`, `ProtocolLexer`,
  `ProtocolParser`
- new `packages/at_server_spec/lib/src/validation/` (or similar) for
  Stage 4's `ProtocolValidator`
- `packages/at_secondary_server/lib/src/verb/handler/abstract_update_verb_handler.dart` and the ~29 other handler files under `lib/src/verb/handler/` (Stage 5)
- `packages/at_secondary_server/lib/src/verb/handler/abstract_verb_handler.dart`, `lib/src/utils/handler_util.dart`, `lib/src/utils/regex_util.dart` (Stage 5 — dispatch/parse entry point)
- new `packages/at_server_spec/lib/src/response/` (or similar) for
  `ProtocolResponse` types, `ResponseEncoder`, and the error taxonomy
  (Stage 6 — in `at_server_spec`, not `at_secondary_server`, per
  `02-architecture.md`'s package boundaries)
