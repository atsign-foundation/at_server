# AST migration — architecture

## Target pipeline

```
          incoming                              outgoing
          --------                              --------
wire command string                    response model (typed, per verb)
        |                                        |
     ProtocolLexer (tokens)               ResponseEncoder
        |                                        |
    ProtocolParser (recursive descent)          wire response
        |
   AST / message model  ----->  semantic validation (ProtocolValidator)
        |                                        |
   dispatcher  ------------------------->  handlers (produce response values)
```

Spec and grammar aren't boxes in the diagram — they're what the lexer,
parser, and AST are each *derived from and checked against* (Stage 1/2 of
`03-implementation-plan.md`), not separate runtime components.

Note the left and right columns are deliberately symmetric: parsing is
`wire → typed` with no I/O, and serialization is `typed → wire` with no
I/O. Only the dispatcher/handlers in the middle touch actual runtime state
(the keystore, connection metadata, notification queues). See "Package
boundaries" below for what that symmetry means for where each piece lives.

## Layer-by-layer: target responsibility vs. what exists today

| Layer | Responsibility | Today in this codebase |
|---|---|---|
| Spec | Human-readable source of truth: every verb's syntax, fields, types, response, errors | Now exists: `00-protocol-spec.md`, derived from `at_commons/lib/src/verb/syntax.dart`. Previously implicit, spread across at_commons' `VerbSyntax` regex strings with no single document. |
| AST / message model | One typed node per verb (`UpdateCommand`, `LookupCommand`, ...) | Exists: `lib/src/ast/`, one sealed `Command` subtype per verb (Stage 2 done). Before that, didn't exist. Closest equivalent: at_commons' per-verb param objects (e.g. `UpdateParams` in `at_commons/lib/src/verb/update_json.dart`), populated by hand in handler code, not by a parser. |
| Grammar | Declarative rule set per verb | Implicit in at_commons' `VerbSyntax` regex strings (`at_commons/lib/src/verb/syntax.dart`) — a real grammar, but as raw regex text, not a structure a parser can be generated from or checked against directly. |
| Token model | A stream of typed tokens with source positions | Doesn't exist. The legacy path runs one `RegExp` over the whole command string in one shot; there is no intermediate `Token`/`TokenType`, and no source-position tracking for error reporting. |
| Lexer | Chars → tokens, lexical concerns only | Doesn't exist as a separate phase. Lexical concerns (escaping, character classes, quoting) are encoded directly inside each verb's regex. |
| Parser | Tokens → AST, one rule ↔ one routine | Doesn't exist. `RegExp(verb.syntax())` + `processMatches` (`handler_util.dart:7`, `regex_util.dart:13`) plays this role today, returning a flat `Map<String,String?>`, not typed nodes. |
| Semantic validation | AST → valid/rejected, independent of grammar | Doesn't exist as a layer. Validation logic (`hu.validateTTR`, `validateCacheMetadata` in `packages/at_secondary_server/lib/src/utils/handler_util.dart:17,26`; reserved-key/permission checks) is inline inside handler methods, interleaved with coercion. |
| Dispatcher | Route AST node → handler | Doesn't exist as a separate component. `AbstractVerbHandler.parse()` (`packages/at_secondary_server/lib/src/verb/handler/abstract_verb_handler.dart:39`) plus each verb's own handler class play this role together; each handler also does its own coercion inline (see `01-acceptance.md`). |
| Handlers | Business logic over typed input | Exist, but take the raw string map (`HashMap<String,String?>`) and coerce it themselves, verb by verb, 30 files deep. |
| Serialization | Typed response → wire format, no I/O (mirrors the parser) | Doesn't exist. Handlers build response content directly, inline, mixed in with actual dispatch/execution; no typed response model and no separation between "what the response is" and "running the request." |
| Errors | Lexical / syntax / semantic / execution error taxonomy | Doesn't exist. Everything collapses to `InvalidSyntaxException` (thrown from `getVerbParam`, `handler_util.dart:11`) regardless of which layer actually failed. |

## Package boundaries

The dividing line is **I/O, not request-vs-response direction**:
`at_server_spec` owns everything that's a pure transform with no access to
live server state; `at_secondary_server` owns everything that touches the
keystore, connections, or notification queues to actually run a request.
Serialization is a pure `typed response → wire string` transform, the exact
mirror of parsing's `wire string → typed AST`, so it belongs on the
`at_server_spec` side of that line, not grouped with the dispatcher/handlers
just because it happens to run "on the way out."

- **`at_server_spec`** owns protocol *definition*, no I/O: spec, AST node
  shapes, grammar, token model, lexer, parser, semantic validation, **typed
  response models and the `ResponseEncoder`**. This is where all of Stages
  1-4 and 6 in `03-implementation-plan.md` belong.
- **`at_secondary_server`** (pub name `at_secondary`) owns the runtime:
  the dispatcher and handlers that execute a request against real state and
  decide *which* typed response to emit — then hand that value to
  `at_server_spec`'s encoder rather than building wire strings themselves.
  This is where Stage 5 lands, and where the 30 handler files doing inline
  coercion live today (`packages/at_secondary_server/lib/src/verb/handler/`).

  Checked against the actual response-handling code
  (`at_secondary_server/lib/src/verb/manager/response_handler_manager.dart`,
  `.../response/base_response_handler.dart`,
  `.../response/pol_response_handler.dart`) before finalizing this
  boundary, since the obvious first guess — "`pol`/`monitor`/`stream`'s
  framing needs live connection access, so keep it in
  `at_secondary_server`" — turned out to be wrong on inspection:
  - Which framing applies is selected purely by **verb type**
    (`ResponseHandlerManager.getResponseHandler`: `verb is Pol`, `verb is
    Monitor`, ... — `response_handler_manager.dart:37-52`), which the AST
    node's type already encodes statically. No connection object needed
    for that dispatch.
  - The one piece that's genuinely connection-dependent — the trailing
    prompt (`$atSign@` / `$fromAtSign@` / `@`,
    `base_response_handler.dart:22-30`) — is universal to nearly every
    response, not specific to the three "quirky" verbs, and it's a single
    string. It gets computed once from connection state in
    `at_secondary_server` and passed into the `at_server_spec` encoder as
    a plain parameter; the encoder itself never touches the connection.
  - `pol` doesn't even use the prompt — `pol_response_handler.dart` just
    strips the `pol:` prefix and returns the rest, no state involved.
  - `monitor` isn't a framing variant at all: setting `response.isStream`
    makes `base_response_handler.dart`'s `process()` return immediately
    without writing anything (`:19-21`) — notifications reach the
    connection through a separate, ongoing push mechanism, not through
    response encoding. `stream` is the same shape of exception. These are
    a different communication mode from request/response, not something
    the `ResponseEncoder` needs to special-case — they're a future design
    question of their own (an output-stream abstraction), out of scope for
    Stage 6.

  Net effect: the full `ResponseEncoder`, including every verb's framing
  rule, lives in `at_server_spec` with zero connection access. The only
  thing `at_secondary_server` supplies is the prompt string and, for
  streaming verbs, bypasses the encoder altogether.
- **`at_commons`** (external pub dependency — already a regular, non-dev
  dependency of `at_server_spec`, per `pubspec.yaml:13`) already owns some
  typed destination objects (`UpdateParams`, `Metadata`) that handlers
  populate today. AST nodes are new, self-contained immutable types in
  `at_server_spec`, converted to these objects only where Stage 5 handlers
  need them — not the objects themselves, which are mutable and
  lossy (`04-decisions.md` D1).

## Key architectural stance

Build directly toward the target pipeline above — spec and AST node shapes
first (Stages 1-2), then a real token model, lexer, and hand-written
recursive-descent parser (Stage 3), with no intermediate bridge layer. The
legacy `RegExp(VerbSyntax.*)` + `processMatches` path remains every verb's
behavioral oracle (conformance fixtures are checked against it) until a
verb's real parser is built and proven, at which point that verb cuts over;
unmigrated verbs keep using the legacy path exactly as today.

The token model + hand-written parser is the single largest piece of new
machinery in this migration — see `04-decisions.md` for the rationale on
why it's sequenced after the spec/AST/validation work settles, not before.
