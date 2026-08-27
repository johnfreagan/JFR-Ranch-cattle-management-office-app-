# Performance Beef API — handoff

**Written 2026-08-27.** For a Claude Code session picking this up cold.

Read `CLAUDE.md` first, then the "Performance Beef" and "Commodity feed &
mineral inventory" sections of `docs/commodity-feed-inventory-plan.md`. This
document covers only what is specific to the **API**: how credentials are
handled, what the API actually returns, and what to build on top of it.

The full vendor spec is checked in at `docs/pb-consultant-openapi.json`
(OpenAPI 3.0, 7 endpoints). It is byte-identical to the copy embedded in the
vendor's integration starter, which was verified rather than assumed.

---

## Status as of this handoff

| | |
|---|---|
| API exists, spec in hand | ✅ `docs/pb-consultant-openapi.json` |
| Credentials issued to John | ✅ client_id + client_secret |
| Credential access verified live | ❌ **not yet — `/users/` has never returned** |
| As-fed vs dry-matter question | ❌ **unresolved, blocks everything** |
| Probe script | ✅ `scripts/pb_probe.py` |
| Ingest RPC `import_pb_usage` | ❌ not built |
| Edge Function | ❌ not built |

**Nothing below the probe should be built until the probe runs green.** The
whole design branches on one unanswered question (§4).

---

## 1. Credentials — the rules

The office app is `index.html`, a single static file served from **GitHub
Pages, with public source**. A third-party API secret in it is readable by
anyone who hits View Source. This is categorically different from the Supabase
publishable key, which is safe there because RLS stands behind it.

So:

1. **Never put PB credentials in `index.html`, any repo file, or any migration.**
2. **Never call the PB API from the browser.** No `fetch()` to
   `performancebeef.com` from app code, ever. There is no CORS-friendly,
   token-safe way to do it.
3. **Never read the credential file into the agent's context.** Do not `cat`
   it, do not open it with Read, do not script Apple Notes to fetch it. Once
   it is in a transcript it cannot be removed. The agent needs the **path**,
   never the contents — a path is not a secret.
4. **Never pass secrets as command-line arguments.** `argv` is visible to every
   process on the machine via `ps`. Use a file or environment variables.
5. Production home is **Supabase Edge Function secrets**
   (`supabase secrets set PB_CLIENT_ID=... PB_CLIENT_SECRET=...`), set by John,
   never by the agent.
6. Local credential files live outside the repo (`~/pb-creds.json`,
   `~/Desktop`, `~/Downloads` — anywhere but here) and should be `chmod 600`.

### The loader contract

`scripts/pb_probe.py` implements `load_credentials()`, which is the pattern to
reuse. It resolves, in order: a path in `argv[1]`, then `$PB_CREDS_FILE`, then
the environment variables `PB_CLIENT_ID` / `PB_CLIENT_SECRET` /
`PB_ACCESS_TOKEN`. It accepts four file shapes, all verified against dummy data:

| file contents | behaviour |
|---|---|
| `{"client_id":"...","client_secret":"..."}` | exchanges for a fresh bearer token |
| `{"access_token":"..."}`, at any nesting depth | uses the token directly |
| `PB_CLIENT_ID=...` / `export PB_CLIENT_ID="..."` (.env style) | exchanges for a fresh token |
| a bare token alone on one line | uses the token directly |

It prints only the **character count** of each value found, never the value,
and warns when the file is not mode 600.

A stored bearer token is usually stale — PB tokens live one hour. Prefer the
client_id/secret pair so every run mints its own.

---

## 2. Running the probe

```bash
python3 scripts/pb_probe.py ~/pb-creds.json      # or: PB_CREDS_FILE=... , or exported env vars
```

The agent generally **cannot run this itself**: variables exported in John's
terminal are not visible to the agent's shell, and the agent must not read the
file. Give John the command; have him paste the output back.

The probe is read-only — one POST to mint a token, then GETs. It writes
nothing to PB and nothing to our database.

---

## 3. The API in brief

`https://performancebeef.com`, OAuth 2.0 client credentials →
`POST /api/consultant/tokens/` → bearer token, `expires_in` 3600.

| endpoint | use to us |
|---|---|
| `/users/` | feedyard roster. Cheapest liveness check for a credential. |
| `/pen_history/` | **the one that matters.** Daily, per pen: `date`, `pen`, `ration`, `head_count`, `weight_unit`, `total_weight`, `dry_weight{actual,target}`, `days_on_feed`, `groups[]`, `feed[{name,weight}]`. |
| `/pens/` | pen roster with stable `pen_id` — build `pb_pen_map` from this once. |
| `/loads_summary/` | per-load ingredient detail. Cross-check only (see below). |
| `/yardsheets/` | group-level closeout figures incl. `h_headdays`, `c_feed`. Cross-check only, never posted. |
| `/deliveries/` | per-delivery pounds at ration level. Not needed if pen_history holds up. |

Behaviours that will bite if missed:

- **`start_date` is required on `/pen_history/` and only there.** Every other
  endpoint defaults; `deliveries` and `loads_summary` quietly default to *10
  days before end_date*. Always pass both dates explicitly.
- **A `200` can carry failures.** The envelope is
  `{"data":[...], "errors":[...]}` and a per-feedyard authorization failure
  rides along inside a successful response. **Treat a non-empty `errors` array
  as a hard abort of the import.** Ignoring it means a lot silently stops
  eating — the same failure shape as an RLS denial returning zero rows.
- **429 carries `Retry-After`** (seconds). Honour it; do not blind-retry.
- **401 has no body.** Mint a new token and retry once.
- Filter with `users=<feedyard_id>` one yard at a time; use
  `fields=` + `field_filter_mode=` to keep payloads small.
- Response shapes are irregular by endpoint: `deliveries.feed_deliveries` is a
  **date-keyed dictionary**, not an array; every `yardsheets` group field is a
  `{label, value}` object, not a scalar; `pen_history.bunk_score` is **either**
  a string **or** an array depending on the yard's configuration. Parse
  defensively.
- **No pagination parameters exist.** Bound requests by date range instead, and
  do not assume a large range returns completely.

---

## 4. The question everything branches on

**Is `pen_history.feed[].weight` as-fed or dry matter?**

Inventory is bought, stored and counted **as fed**. Relieving a bay by a dry
matter figure would leave ~12.4% of every load sitting in inventory that isn't
physically there.

The acceptance test is already encoded in the probe, against the real 36-27
Group Invoice for **Aug 17–26 2026**:

| check | must be | meaning if it fails |
|---|---|---|
| Σ `feed[].weight` | **69,510 lb** | **60,881** means it is dry matter — do not post it |
| Σ `head_count` | **3,756 head-days** | PB and our books have drifted apart |
| `feed[].name` values | commodity names (`Corn hopper bin`, `Pennchlor 50G`, `Peanut Hulls`) | ration components instead → fall back to `/loads_summary/` |
| `weight_unit` | `"lb"` | assert it, never assume it |
| Σ `dry_weight.actual` ÷ Σ as-fed | ≈ 87.6% | corroborates the first row |

If `feed[]` turns out to be ration components rather than commodities, the
fallback is `/loads_summary/`, whose `ingredients[].af_actual` is explicitly
as-fed. **The catch:** `ingredients` are per *load* while `drops` are per
*pen*, so a load split across pens yields no ingredient×pen figure without
prorating ingredients across drops by `af_actual`. That is materially more
work and more error surface. Confirm pen_history first.

---

## 5. Mapping PB onto our schema

Target table is `feed_usage` (see `docs/sql/2026-08-27_feed_inventory.sql`).
Post through the existing RPC — **never insert into `feed_usage` directly**;
it will not consume FIFO layers or freeze cost.

```
post_feed_usage(p_item_id, p_from_location_id, p_qty_lb, p_destination_type,
                p_period_start, p_period_end, p_lot_id, p_pasture_id,
                p_to_location_id, p_usage_date, p_source, p_pb_row_key,
                p_reason, p_notes, p_batch_id) RETURNS uuid
```

| PB | ours |
|---|---|
| `date` | `p_usage_date` = `p_period_start` = `p_period_end` — **one day, no spreading** |
| `pen` + `/pens/`.`pen_id` | `p_pasture_id` via a new `pb_pen_map` |
| `groups[]` | `p_lot_id` via `pb_group_map` |
| `feed[].name` | `p_item_id` via `feed_items.pb_name` |
| `feed[].weight` | `p_qty_lb` (as-fed, pending §4) |
| — | `p_source = 'pb_import'` |
| — | `p_pb_row_key` = stable key, see §6 |
| `head_count` | **nothing.** Tie-out only. |

Still to build: `pb_group_map`, `pb_pen_map`, `feed_items.pb_name` aliases, and
`import_pb_usage(rows jsonb)` wrapping the above in one transaction.

**Never import:** `Cost Per Ton`, `Feed Cost`, `Dry Matter Fed`,
`Dry Matter Cost Per Ton`, yardage, management fee. PB supplies pounds; we own
cost. Yardage and the management fee are John's own estimates typed into PB and
would double-charge against the app's labor and COG lines.

---

## 6. Three gaps in the API, and the answer to each

**a. No `updated_since`, no row IDs, no void flag.** A feeding corrected or
deleted in PB simply changes; nothing marks it. Polling for deltas is
impossible.

> **Window replace.** Every run, pull a rolling trailing window (14 days
> suggested) and make our rows for that window match PB's exactly: upsert what
> came back on `pb_row_key`, and **reverse any `pb_row_key` inside the window
> that PB did not return.** Without the reversal half, deletions in PB never
> reach our books. Reversal goes through `delete_feed_usage`, which puts pounds
> back on the exact layers.
>
> Construct `pb_row_key` from `(feedyard_id, date, pen_id, feed_name)` — stable
> across re-pulls, unique per posted row. Note the unique index on
> `feed_usage.pb_row_key` is partial (`WHERE pb_row_key IS NOT NULL`).

Because rows are per-day and the window is replaced wholesale, **the
overlapping-import hazard disappears for the API path**. The overlap refusal
described in the plan is still required for any manual or file-based path.

**b. A pen can hold more than one lot.** `groups` is an *array*, with one
pounds figure for the pen. Five pastures currently hold multiple lots
(Garrett/Trap has three; Steele/Front Native has 416 head across two). PB will
not split those.

> Prorate the pen's pounds across its lots by that day's head-days from
> `lot_daily_head`. Use largest-remainder so the parts sum **exactly**, as the
> shipment allocator does. Log every prorated row — a silent split is a silent
> error.

**c. Nothing states the day boundary.** `pen_history.date` is a bare date;
`deliveries.delivery_time` is a `Z` timestamp.

> The DB runs UTC and the ranch does not. Use `public.ranch_today()` /
> `ranchToday()` for anything counting days, and confirm with John which clock
> PB closes its work day on before trusting a same-day pull. Prefer pulling
> through *yesterday* rather than today.

---

## 7. Reports to build

**This list needs John's sign-off before anything is built — it is inferred
from the plan, not dictated by him.** Ask which he actually wants and in what
order. Feed is office+owner only; every surface carries `data-perm="office"`.

Ordered by my read of value:

1. **Import preview / tie-out** (not optional — it is part of the importer).
   Per group: pounds by item, lb/hd/day, PB head count and head-days beside
   ours, which FIFO layers will be consumed, which will go short, our frozen
   dollars beside PB's. Nothing posts until accepted.
2. **Daily head-day reconciliation, PB vs our books.** The Aug 17–26 invoice
   tied exactly (537 head, 3,756 head-days). The day that stops being true is
   the day every $/hd/day quietly stops meaning anything, so it wants to be a
   standing report, not a one-off check.
3. **Cost of gain, actual vs assumed, per lot.** Phase 4 already computes the
   actual side (`lot_feed_costs`, `lot_feed_daily`). The comparison against
   `assumed_cog_per_day` (~$0.75, while the receiving window ran $2.57 of feed
   alone) is the number John said he wanted to stop guessing at.
4. **Consumption vs inventory drift.** PB's fed pounds against our bay
   drawdown, per item per bay — catches a mis-mapped `pb_name` or a bay
   quietly running on estimates.
5. **Receiving-additive split.** Deccox-Corrid and Pennchlor 50G were 30% of
   that invoice and are feed-grade drugs; they should code to animal health,
   not commodity feed. `feed_items.item_type = 'additive'` already exists to
   carry it.
6. **Unmatched groups / items exception report.** An unmatched group must
   block the import, never be skipped — a skipped group is a lot that silently
   stops eating.

Build on the existing views where possible: `lot_feed_daily`,
`lot_feed_costs`, `feed_cost_unallocated`, `pasture_feed_allocation`,
`pasture_feed_costs`, `feed_on_hand`, `feed_usage_detail`,
`feed_count_variance`.

---

## 8. Architecture

```
PB API ──▶ Supabase Edge Function ──▶ import_pb_usage() ──▶ post_feed_usage() ──▶ feed_usage
             (holds the secret)         (one transaction)      (FIFO + frozen $)
```

The Edge Function is the **first server-side component in this project**. It
brings a deploy step, secret rotation, and a log that has to be read when it
fails quietly at 3am. Budget days, not an afternoon.

It also forces the migration reconciliation described in CLAUDE.md
("Migrations"): the remote has no CLI migration history, so `supabase db push`
would try to apply everything from scratch against existing tables. Adopt the
CLI properly — `supabase link` → `db pull` for a baseline → mark applied →
`supabase migration list` — before deploying functions.

The manual weekly-entry screen from Phase 2 stays. It is the hedge, it already
works, and it is the fallback for any window the API cannot serve.

---

## 9. Definition of done for the next session

1. Probe runs green: `/users/` returns the yard, and the three numbers in §4
   match.
2. `pb_group_map`, `pb_pen_map`, `feed_items.pb_name` populated for the pens
   and commodities actually in use.
3. `import_pb_usage(rows jsonb)` built: transactional, upserts on
   `pb_row_key`, reverses rows absent from the window, blocks on unmatched
   group or item, aborts on a non-empty `errors` array.
4. Edge Function deployed with secrets set by John, on a schedule, with a
   readable failure log.
5. Preview screen shows the tie-out and posts nothing until accepted.
6. `supabase/migrations/20260821000300_rls_verify.sql` run after any migration
   adding a table, view or function.
7. Verified against the Aug 17–26 window: import, then re-import the same
   window, and confirm the pounds do **not** double.

Do not skip 7. Re-import idempotency is the single most likely way to corrupt
this module's books.
