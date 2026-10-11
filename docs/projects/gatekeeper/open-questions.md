# Gatekeeper: open questions

The design tree still to be settled. A question is on the **frontier** when
everything it depends on is decided. Settled questions move to
[decisions.md](decisions.md): Q2 became D2, Q3 became D3, Q4 became D4 and P1,
Q5 became D5, Q6 became D6, Q7 became D7, Q17 became D8,
Q8 became D9, Q9 became D10, Q10 became D11, Q16 became D12, Q20 became
D13, Q19 became D14, Q21 became
D15, and Q18 narrowed D4.

## Spec

No spec question is open. The spec was agreed file by file:

| File | State |
|---|---|
| [rules.feature](features/rules.feature) | agreed 2026-10-10, with the additions from D20 and D23, and stream's removal |
| [namespace_less.feature](features/namespace_less.feature) | agreed 2026-10-10, less the stream scenario |
| [outbound.feature](features/outbound.feature) | agreed 2026-10-10 |
| [quarantine.feature](features/quarantine.feature) | agreed 2026-10-10, with D20's two additions, less the stream scenario |
| [refusals.feature](features/refusals.feature) | agreed 2026-10-10 |

On 2026-10-11 every file gained Forgery and Impersonation lines, agreed file by
file, and rules.feature, namespace_less.feature and outbound.feature each
gained a `@forgery` scenario.

## Design

Q11 became D17, Q14 became D18, Q23 became D19, Q13 became D20, Q12 became D21 and Q15 became D22. gkc agreed
[design.md](design.md) as a whole on 2026-10-10.

The gate verb's answers in [design.md, section 5.1](design.md#51-the-gate-verb),
agreed on 2026-10-11, were re-opened the same day from a review on the client
API's side:

- **Q24 Closing a namespace.** Closing drops the denied set, so reopening lets
  each atSign it denied back in, quarantined on first contact. Should the
  denied set be kept across a close and ignored while closed? And what becomes
  of quarantined notifications already held when the quarantined set goes?
- **Q25 Admitting into a namespace with no rule.** `admit` and `remove` there
  are refused with AT0022, so under the ungated default an application cannot
  record an admission without claiming the namespace, and switching the
  default to closed then cuts off everyone it meant to admit. AT0022 also
  answers a setting over its ceiling and `deny` on a closed namespace, so a
  client cannot tell "no rule" apart by code.
- **Q26 Reads.** Nothing lists the atSign-wide admitted set (`*` takes `admit`
  and `remove`, not `show`), and nothing lists the namespaces that have a rule.
- **Q27 Unbounded answers.** `gate:show` answers the admitted and denied sets
  whole in one `data:` line, and D20 bounds neither set.
- **Q28 A setting back to the operator's default.** Sending the default's value
  fixes it, so it no longer follows a later change to the operator's default.
- **Q29 The closed answer** omits the settings a closed namespace keeps.
- **Q30 Quarantined entries** carry no time, so an invitation review cannot
  show first-contact order.

## Next

Implementation has begun, following spec-anchored step 4: the bench's baseline
is taken, and the gatekeeper's verdicts, settings and `local:` records are built
and tested. The gate verb waits on Q24 to Q30. The work spans at_commons (in
at_client_sdk), at_server, at_client, and every atServer implementation.

The three checks this list held are answered in design.md: the SQLite codec
decodes an unknown status as `null`, a client turns an unknown error code into a
plain `AtException`, and `batch` and `update:json` meet the `local:` guard.
