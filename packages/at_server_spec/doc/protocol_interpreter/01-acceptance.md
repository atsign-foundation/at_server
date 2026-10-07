# AST migration — acceptance

## Problem statement

Today, parsing an atProtocol command — via the legacy
`RegExp(VerbSyntax.*)` + `processMatches` path
(`packages/at_secondary_server/lib/src/utils/regex_util.dart:13`) — produces
a flat `Map<String, String?>`. Every value in that map is a string, even
where the underlying field is really an int, a bool, a timestamp, or an
enum.

Because of this, every verb handler in `at_secondary_server` does its own
ad hoc coercion and validation directly against the string map, at the call
site, every time. In
`packages/at_secondary_server/lib/src/verb/handler/abstract_update_verb_handler.dart`,
`getUpdateParams` (starting line 246) alone contains:
- `hu.validateTTR(int.parse(verbParams[AtConstants.ttr]!))` (line 286)
- four separate `DateTime.parse(verbParams[...]!)` calls for
  `createdAt`/`updatedAt`/`expiresAt`/`availableAt` (lines 293, 296, 299, 303)
- four separate `AtMetadataUtil.getBoolVerbParams(verbParams[...])` calls for
  `ccd`/`isBinary`/`isEncrypted`/`immutable` (lines 288–290, 306–313, 332–335)
- a JSON decode wrapped in its own try/catch (`Metadata.decodeAppMetadata`,
  lines 336–342)
- a raw string comparison for scope (`verbParams[AtConstants.publicScopeParam] == 'public'`,
  line 314)

This same shape of code — parse, then hand-coerce, then validate — repeats
across the ~30 other handler files that index into `verbParams[...]`
(`grep -l "verbParams\[" packages/at_secondary_server/lib/src/verb/handler`
→ 30 files, 242 occurrences total). A real AST — typed per-verb command
nodes produced by the parser itself — would let this coercion and
validation happen once, centrally, instead of being re-implemented per
handler.

## Success criteria

Not all required to ship together — each is a usable milestone on its own,
matching the staged implementation plan (`03-implementation-plan.md`):

1. **Spec coverage.** Every verb's syntax, fields, and field types are
   written down in one place (`00-protocol-spec.md`, done — derived
   directly from `at_commons/lib/src/verb/syntax.dart`, not merely
   transcribed from the upstream
   [atsign-foundation/at_protocol](https://github.com/atsign-foundation/at_protocol)
   doc, which was found to be stale on several verbs — see
   `00-protocol-spec.md`'s "Corrections vs. the upstream spec"), kept in
   sync as `at_commons` evolves.
2. **Typed AST reachable without touching handler code.** An immutable
   typed command node (e.g. `DeleteCommand`, in `at_server_spec`'s
   `lib/src/ast/`) is buildable directly from a parsed command, with no
   changes required to `at_secondary_server`; conversion to at_commons
   objects like `UpdateParams` happens at the handler boundary.
3. **Centralized semantic validation.** Validation currently inline in
   handlers (`hu.validateTTR`, reserved-key / permission checks) is
   expressible as a pure function over the AST, independent of parsing.
4. **At least one verb parsed end-to-end by a real lexer + parser**
   producing typed AST directly, verified against conformance fixtures
   (command → expected AST).
5. **At least one handler converted to take a typed command object**
   instead of indexing into `verbParams[...]`, with existing handler tests
   passing unmodified.

## Non-goals (for now)

- No change to the wire protocol or to any verb's observable syntax/semantics.
- No change to at_commons' public `VerbSyntax` strings.
- Not a commitment to a multi-language/ANTLR-generated parser — noted as a
  possible future direction if atProtocol ever needs a second-language
  implementation, not something this effort is building toward.

## Constraints

- **Behavior-identical to the legacy regex path.** Whatever parses atProtocol
  commands — legacy regex today, or a real lexer/parser once built — must
  match `RegExp(VerbSyntax.*)` + `processMatches`'s observable behavior for
  every verb until that verb is deliberately and explicitly cut over to new,
  reviewed behavior.
- **No committed public API yet.** There is no existing typed parsing API to
  keep stable — this work starts from the current regex path, so there's
  nothing to be backward-compatible with beyond the wire protocol itself.
  The real implementation's public API is designed in Stage 2/3, not
  constrained by anything pre-existing.
