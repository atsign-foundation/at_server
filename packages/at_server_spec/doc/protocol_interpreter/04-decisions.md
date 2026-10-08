# AST migration — decisions

ADR-style record of the calls made while planning this migration. Each
entry: decision, alternatives considered, rationale, status.

---

## D1 — AST nodes are new, self-contained immutable types in `at_server_spec`

**Decision:** Each verb gets a new immutable node in `at_server_spec`
(`DeleteCommand`, `UpdateCommand`, ...) under a `sealed class Command`,
with value equality. The AST does not reuse at_commons types, even as
leaf fields: small enums (`Priority`, `LookupOperation`) and the metadata
fragment (`MetadataFragment`) are defined alongside the nodes. Where a
Stage 5 handler needs an at_commons object (e.g. `UpdateParams`,
`Metadata`), a conversion is added at that point, not baked into the
node shape.

**Alternatives considered:**
1. *(This decision's first draft.)* The node for a verb *is* at_commons'
   existing destination object — `UpdateParams`
   (`at_commons/lib/src/verb/update_json.dart`) for `update`.
2. Reuse at_commons' per-verb `*VerbBuilder` classes
   (`at_commons/lib/src/verb/*_verb_builder.dart`) as the nodes — they
   exist for nearly every verb, and `delete`/`update`/`monitor` even have a
   regex-based `getBuilder(command)`.

**Rationale:** Both alternatives fail on inspection of the actual types:
- `UpdateParams` is mutable, all-nullable, has no `==`/`hashCode`, and is
  lossy — no `noCommit`, no positional-vs-`update:json` distinction. It
  can't satisfy Stage 2's own verification (field access + equality) or
  Stage 3's conformance fixtures (`command -> expected AST` needs equality).
- The `*VerbBuilder`s are mutable, client-oriented (their `validateKey`
  throws client exceptions), and also lossy:
  `DeleteVerbBuilder.getBuilder` silently drops `priority` and `cached`.
  Their `buildCommand()` is still useful later as a cross-check for
  Stage 6's encoder.

Leaf-type reuse was also dropped: at_commons' `Metadata` is mutable and
carries non-wire state (`isCached`, `namespaceAware`, ...), so it can't
represent "this tag was absent" distinctly from a default, which the
order-sensitive, all-optional metadata fragment needs. Small enums like
`PriorityEnum` gain nothing over a local declaration and would couple the
AST's public API to at_commons releases. The original rationale (no
dependency-direction obstacle) still makes conversions cheap where Stage 5
needs them.

**Status:** adopted, superseding the first draft (alternative 1), which
was marked resolved after checking only `pubspec.yaml`, not the shape of
`UpdateParams` itself. Implemented for every verb in `lib/src/ast/`.

---

## D2 — Domain-specific AST nodes, not a generic compiler-style hierarchy

**Decision:** Per-verb domain nodes (`PutCommand`, `GetCommand`,
`DeleteCommand`, ...) rather than generic `Statement`/`Expression`/
`Argument` nodes.

**Rationale:** atProtocol's verb set is fixed and enumerable (~29 verbs,
`lib/src/verb/*.dart`) — it isn't a general-purpose language needing
recursive expression composition. A generic node hierarchy would add a
layer of indirection (pattern-matching on node *kind* instead of on the
Dart type system via `sealed class`/exhaustive `switch`) without a
corresponding need.

**Status:** adopted for Stage 2.

---

## D3 — Lexer/parser (Stage 3) built directly, sequenced after spec/AST (Stages 1-2), not first

**Decision:** The real token model + hand-written recursive-descent parser
is built directly against the spec and AST shape, once those are settled —
not before them, and with no intermediate bridge layer in between.

**Alternatives considered:** Building the lexer/parser first, since it's
nominally "the real AST work," and layering spec/AST/validation on top
afterward.

**Rationale:** The token model + parser is the single largest, hardest-to
-unwind piece of new machinery in this migration. Doing it after Stages 1-2
means it's built against an already-settled target: the spec defines
exactly what each verb accepts, and the AST node shapes are fixed — so the
parser's job is narrowly "produce this already-specified shape," not
"co-design the shape while also inventing how to produce it." Semantic
validation (Stage 4) is likewise kept separate from the parser itself, so
grammar concerns (is this syntactically a valid command?) don't get
tangled with semantic ones (is `ttr:-1` meaningful here?).

The legacy `RegExp(VerbSyntax.*)` + `processMatches` path remains the
behavioral oracle for every verb until that verb's real parser is built and
differentially tested against it (see `03-implementation-plan.md`, Stage
3's verification) — there is no interim engine to bridge from or to.

**Status:** adopted.

---

## D4 — Dispatcher/handler work scoped to `at_secondary_server`, deliberately deferred

**Decision:** Stage 5 (dispatcher, typed handler signatures) is explicitly
not started alongside Stages 1-2, and does not start until at least one
verb has a proven parser (Stage 3) and validator (Stage 4). Stage 6 (typed
responses, `ResponseEncoder`, error taxonomy) is a separate case — see D5 —
and is not subject to this same deferral, since it lives in `at_server_spec`
and doesn't touch handler code.

**Rationale:** `at_secondary_server` has roughly 10x the blast radius of
`at_server_spec` for this change — 30 handler files directly index into
`verbParams[...]` (`grep -l "verbParams\[" packages/at_secondary_server/lib/src/verb/handler`
→ 30 files) versus a handful of new files in `at_server_spec`. Cutting
handlers over before the AST and parser are proven would mean debugging
handler regressions and parser/AST design mistakes at the same time, in the
harder-to-isolate package.

**Status:** adopted. Each verb's cutover should be gated by a
`supports(verb)`-style check so a regression is scoped to one verb and
trivially revertible by flipping the gate back, with unmigrated verbs
continuing to use the legacy regex path untouched.

---

## D5 — Serialization (`ProtocolResponse`/`ResponseEncoder`) lives entirely in `at_server_spec`, not `at_secondary_server`

**Decision:** Stage 6's typed response model and `ResponseEncoder` are
placed in `at_server_spec`, alongside the AST/parser, not in
`at_secondary_server` alongside the dispatcher/handlers — including every
verb's framing rule, with no carve-out for `pol`/`monitor`/`stream`.

**Alternatives considered:**
1. Grouping all "outgoing path" work with the dispatcher/handlers in
   `at_secondary_server`, on the theory that responses are a runtime
   concern because they're produced at request-handling time.
2. An intermediate position (this decision's own first draft): keep the
   encoder for the common case in `at_server_spec`, but carve out
   `pol`/`monitor`/`stream`'s framing into `at_secondary_server` on the
   assumption that it needs live connection access.

**Rationale:** The dividing line that matters for package placement is
I/O, not which direction of the request/response cycle something sits on.
Serialization is a pure `typed response → wire string` transform with no
access to live server state — exactly the mirror of parsing's
`wire string → typed AST`, which already lives in `at_server_spec` with no
dispute.

Alternative 2 was this decision's own first draft, and turned out to be
wrong on inspection of the actual response-handling code
(`response_handler_manager.dart`, `base_response_handler.dart`,
`pol_response_handler.dart` — prompted by a reviewer question: "why do I
need state?"):
- Which framing applies is selected purely by **verb type**
  (`ResponseHandlerManager.getResponseHandler`, a chain of `verb is Pol`/
  `verb is Monitor`/... checks, `response_handler_manager.dart:37-52`) —
  already known statically from the AST node's type, no connection needed.
- The only genuinely connection-dependent piece is the trailing prompt
  (`$atSign@` / `$fromAtSign@` / `@`, `base_response_handler.dart:22-30`),
  which is universal to nearly every verb's response (not special to the
  three "quirky" ones) and is a single string — passed into the encoder as
  a plain parameter, not a reason to give the encoder connection access.
- `pol` doesn't use the prompt at all (`pol_response_handler.dart` just
  strips the `pol:` prefix).
- `monitor` (and `stream`) aren't framing variants of a response at all:
  setting `response.isStream` makes response processing return immediately
  without writing anything (`base_response_handler.dart:19-21`) —
  notifications reach the connection through a separate, ongoing push
  mechanism. This is a different communication mode from request/response,
  not a case the `ResponseEncoder` needs to handle; it's a future design
  question of its own (an output-stream abstraction), out of scope for
  Stage 6.

**Status:** adopted, after one correction. The original draft of
`02-architecture.md` grouped serialization with `at_secondary_server` by
default (no rationale given); the first revision added a `pol`/`monitor`/
`stream` carve-out that seemed reasonable but wasn't checked against the
actual code; this version is checked against `response_handler_manager.dart`
and `base_response_handler.dart` directly. Both corrections were prompted
by reviewer questions, not caught in the initial design pass — worth
noting as a pattern: package-boundary claims about "needs runtime state"
are worth verifying against the actual code before they harden into an
architecture decision.
