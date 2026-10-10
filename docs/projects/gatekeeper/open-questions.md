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
| [rules.feature](features/rules.feature) | agreed 2026-10-10, with D20's addition |
| [namespace_less.feature](features/namespace_less.feature) | agreed 2026-10-10 |
| [outbound.feature](features/outbound.feature) | agreed 2026-10-10 |
| [quarantine.feature](features/quarantine.feature) | agreed 2026-10-10, with D20's two additions |
| [refusals.feature](features/refusals.feature) | agreed 2026-10-10 |

## Design

Q11 became D17, Q14 became D18, Q23 became D19, Q13 became D20, Q12 became D21 and Q15 became D22. No design fork is
open. [design.md](design.md) is to be agreed as a whole.

The three checks this list held are answered in design.md: the SQLite codec
decodes an unknown status as `null`, a client turns an unknown error code into a
plain `AtException`, and `batch` and `update:json` meet the `local:` guard.
