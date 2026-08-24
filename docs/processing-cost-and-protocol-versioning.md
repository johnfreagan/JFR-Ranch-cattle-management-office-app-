# Processing cost & protocol versioning

How processing cost actually computes, why it is not date-aware, and the safe
way to change a protocol or a drug price.

Established 2026-08-24 while backdating the Draxxin → Macrosyn change on lot 36-27.

---

## The mechanism

`lot_processing_costs` and `lot_processing_cost_detail` compute cost live:

```
delivery_receipts.receiving_protocol_id
  → protocol_meds  (which meds, dose overrides)
  → medications    (dose_mode, per_weight_rate, round_up_to, cost_per_unit)
```

Weight comes from the receipt's own invoice where one exists, otherwise the
lot's average in-weight.

**Nothing in that chain is date-filtered.** `protocols.effective_from` exists on
the table and is never referenced by any view. Protocol versioning columns
(`version_label`, `parent_protocol_id`, `effective_from`) are scaffolding that
was never wired to the cost math.

### Consequence

| | behavior |
|---|---|
| **Treatment cost** (doctoring_event_meds) | **Frozen** per row at save time. Changing a drug price does not move history. |
| **Processing cost** (receipts × protocol) | **Derived live.** Changing a protocol's meds, or a medication's price or rounding, rewrites every lot that ever used it — closed lots and prior fiscal years included, silently, no audit trail. |

The two behave oppositely. That is the thing to remember.

---

## Safe procedure for a protocol change

1. **Create a new protocol row.** `parent_protocol_id` → the old one, new
   `version_label`, set `effective_from`. Do not edit the old protocol.
2. **Price every medication on it first.** See the NULL trap below.
3. **Repoint the specific receipts** — `UPDATE delivery_receipts SET
   receiving_protocol_id = <new> WHERE receiving_protocol_id = <old> AND
   receipt_date >= <cutover>`. Guard with a row-count assertion and append an
   audit note to `notes`.
4. **Verify** `unpriced_line_count = 0` and the lot total moved by the expected
   amount, not by the whole line.

Earlier loads keep the old protocol id, so their books keep saying they got the
old product — which is true, and is the point.

---

## The NULL trap

The pricing branch in the cost view:

```sql
case
  when cost_per_unit is not null and dose_per_head is not null
       then dose_per_head * cost_per_unit
  when cost_per_head is not null then cost_per_head
  else null
end
```

A medication with **both** `cost_per_unit` and `cost_per_head` null prices as
NULL, and `SUM()` ignores NULL. The line does not error — it **disappears from
processing cost**. `unpriced_line_count` is the only signal.

Pointing a protocol at an unpriced med therefore *understates* the books rather
than failing. Always guard a repoint script:

```sql
select count(*) from protocol_meds pm
join medications m on m.id = pm.medication_id
where pm.protocol_id = '<new>'
  and m.cost_per_unit is null and m.cost_per_head is null;
-- raise exception if > 0
```

---

## `round_up_to` is a math setting, not a price setting

It models the **syringe setting including waste**, not drug consumed. Keep it
consistent between the brand and generic of the same drug, or a price change
quietly becomes a dosing change.

Draxxin vs Macrosyn at 386 lb avg in-weight, both 1.1 mL / 100 lb:

| round_up_to | mL drawn | $/hd |
|---|---|---|
| 1.0 (Draxxin) | 5.0 | $4.9631 |
| 0.1 | 4.3 | $3.3621 |
| 1.0 (Macrosyn, chosen) | 5.0 | $3.9094 |

The generic was initially entered at 0.1 — a $0.55/hd difference that had
nothing to do with the price of the drug. Set to 1.0 to match.

---

## Worked example — lot 36-27, Aug 2026

Draxxin → Macrosyn(Draxxin), effective Wednesday 2026-08-19 (first day of new
processing). Protocols were otherwise identical; only that one med differed.

- New protocol version created with `parent_protocol_id` → old
- Macrosyn priced: 500 mL bottle, $390.94 → $0.78188/mL; `round_up_to` set 0.1 → 1.0
- 5 of 11 receipts repointed (197 of 441 head, Aug 19–23)
- 6 receipts (244 head, Aug 11–18) left on branded Draxxin

| | before | after |
|---|---|---|
| Lot processing total | $9,109.06 | $8,901.48 |
| Processing $/hd in | $20.66 | $20.18 |
| Unpriced lines | 0 | 0 |

Had the repoint run before Macrosyn was priced, the total would have landed at
~$8,131 — the drug line gone entirely, with no error.
