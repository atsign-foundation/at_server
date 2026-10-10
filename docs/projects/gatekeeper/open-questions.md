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
| [rules.feature](features/rules.feature) | agreed 2026-10-10 |
| [namespace_less.feature](features/namespace_less.feature) | agreed 2026-10-10 |
| [outbound.feature](features/outbound.feature) | agreed 2026-10-10 |
| [quarantine.feature](features/quarantine.feature) | agreed 2026-10-10 |
| [refusals.feature](features/refusals.feature) | agreed 2026-10-10 |

## Design

| # | Question | Depends on |
|---|---|---|
| Q11 | Where rules, quarantine state and counters are stored; whether they sync | D2, D3, D5 |
| Q12 | Concurrency: counters under parallel connections, rule changes during an exchange | Q11 |
| Q13 | Bound values: operator defaults and ceilings for D7's limits and D15's bounds | D7, D15, Q11 |
| Q14 | Compatibility with released senders, which retry a refusal until it expires and hold later notifications to the same atSign behind it (D4's first consequence is one case) | Q8 |
| Q15 | Which test pack proves each scenario | the agreed spec |
