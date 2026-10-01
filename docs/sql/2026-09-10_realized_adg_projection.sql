-- 2026-09-10  The projection walks forward on the lot's OWN realized ADG.
--
-- John, 2026-09-10: "we don't weigh a lot of cattle ... since we shipped
-- yesterday I have good estimates on some cattle."
--
-- There are two different corrections and the anchor work only did one:
--
--   LEVEL  "these cattle weigh X today"      needs a scale.  Rare.
--   RATE   "this lot gains Y, not what we    needs no scale. Falls out of
--          assumed"                          pay weights every time we ship.
--
-- The rate correction is free and the ranch already generates it on every
-- sale, and the books were throwing it away: 37X shipped 283 head at a
-- realized 1.473 lb/day while the projection carried its remaining 32 head
-- forward at the assumed 1.80 - 910.7 lb against roughly 823. Eighty-eight
-- pounds a head of inventory that is not there, straight into break-even.
--
-- So `lot_projected_weight_detail()` now picks its daily rate in this order:
--
--   1. lot_adg_phases      an explicit, hand-entered curve. A deliberate
--                          statement about this lot beats a measurement.
--   2. lot_realized_adg    what the lot ACTUALLY did, off real pay weights,
--                          once enough head have shipped to mean anything.
--   3. lots.target_adg     the assumption. Where every lot starts.
--
-- `adg_source` gains 'realized' and 'realized_thin' so the screen can always
-- say which of the three it used and how much it rests on.
--
-- WHAT THIS DOES NOT DO
-- - It does not restate anything booked. Projected weight is an estimate;
--   no frozen number, no cost, no head count moves.
-- - It does not touch `per_lb` cost of gain, which reads lot_realized_adg and
--   lots.target_adg directly and never went through this function.
-- - It does not re-rate a lot with nothing shipped (36-27 is untouched), and
--   it never overrides a hand-entered ADG phase.
--
-- THE BIAS, STATED OUT LOUD
-- Cattle shipped first are generally the best ones, so realized ADG measured
-- on them tends to OVERSTATE what the remnant is doing. It is still far
-- better than an assumption that is 18% wrong, but it is not a random
-- sample and this migration does not pretend otherwise - which is why the
-- source is always reported rather than folded silently into one number.
--
-- Idempotent: CREATE OR REPLACE throughout.
-- Paste into the SQL editor WITHOUT the begin/commit lines.
begin;

-- =====================================================================
-- Snapshot before, so the verify block can show exactly which lots moved
-- and prove that the ones that should not have, did not.
-- =====================================================================
drop table if exists _adg_before;
create temp table _adg_before on commit preserve rows as
select lot_id, projected_current_weight from public.lot_status;

-- =====================================================================
-- Is a lot's realized ADG worth believing?
--
-- Two gates, both on the SAMPLE and not on the answer:
--   - at least 20 head with a real pay weight, and
--   - at least 10% of the head that came in.
-- Below either, the number is an anecdote and the assumption stands.
--
-- 'thin' is the softer line: under 30% of head in, it is used but the
-- screen says so. 37X-1 sits here - 66 head of 274 - and a reader should
-- know that before leaning on it.
-- =====================================================================
-- NOTE: this reads `lot_realized_adg_internal()` and the two head-in tables
-- DIRECTLY, never `lot_realized_adg` (the view) or `lot_status`. It has to:
-- lot_status calls lot_projected_weight_detail(), which calls this, so going
-- through lot_status makes the three mutually recursive and Postgres blows
-- the stack rather than erroring usefully. Caught on the first apply.
create or replace function public.lot_realized_adg_confidence(p_lot_id uuid)
returns text
language sql
stable
set search_path to 'public'
as $function$
    with hd as (
        select greatest(
                 coalesce((select sum(i.head_count)  from public.invoices i
                            where i.lot_id = p_lot_id), 0),
                 coalesce((select sum(dr.head_count) from public.delivery_receipts dr
                            where dr.lot_id = p_lot_id), 0)
               )::numeric as head_in
    )
    select case
             when r.realized_adg is null or r.realized_adg <= 0     then 'none'
             when r.head_sold_with_weight is null                   then 'none'
             when r.head_sold_with_weight < 20                      then 'none'
             when hd.head_in = 0                                    then 'none'
             when r.head_sold_with_weight < 0.10 * hd.head_in       then 'none'
             when r.head_sold_with_weight < 0.30 * hd.head_in       then 'thin'
             else 'good'
           end
      from public.lot_realized_adg_internal(p_lot_id) r
      cross join hd;
$function$;

comment on function public.lot_realized_adg_confidence(uuid) is
    'How much the lot''s realized ADG rests on: none (too few head shipped with a pay weight - the assumption stands), thin (used, but under 30% of head in), good. Gates are on the SAMPLE, never on the answer.';

revoke all on function public.lot_realized_adg_confidence(uuid) from public, anon;
grant execute on function public.lot_realized_adg_confidence(uuid) to authenticated, service_role;

-- =====================================================================
-- The projection, now rate-aware.
-- Signature, return type, volatility and SECURITY DEFINER posture are all
-- unchanged - every existing caller is untouched.
-- =====================================================================
create or replace function public.lot_projected_weight_detail(
    p_lot_id uuid,
    p_on_date date default current_date
)
returns table (
    projected_weight_lb numeric,
    anchor_date         date,
    anchor_type         text,
    days_since_anchor   integer,
    adg_used            numeric,
    adg_source          text
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
DECLARE
    v_anchor_date  DATE;
    v_anchor_type  TEXT;
    v_anchor_avg   NUMERIC;
    v_arrival      DATE;
    v_target_adg   NUMERIC;
    v_base_adg     NUMERIC;
    v_base_source  TEXT;
    v_confidence   TEXT;
    v_realized     NUMERIC;
    v_days         INTEGER;
    v_gain         NUMERIC;
    v_phase_days   INTEGER;
    v_rate         NUMERIC;
    v_source       TEXT;
BEGIN
    SELECT a.anchor_date, a.anchor_type, a.anchor_avg_weight_lb
      INTO v_anchor_date, v_anchor_type, v_anchor_avg
      FROM public.lot_weight_anchor a
     WHERE a.lot_id = p_lot_id;

    IF v_anchor_date IS NULL OR v_anchor_avg IS NULL THEN
        RETURN;
    END IF;

    SELECT COALESCE(l.target_adg, 0) INTO v_target_adg
      FROM public.lots l WHERE l.id = p_lot_id;
    v_target_adg := COALESCE(v_target_adg, 0);

    -- The lot's own measured rate, if the sample earns it.
    v_confidence := public.lot_realized_adg_confidence(p_lot_id);
    IF v_confidence IN ('good','thin') THEN
        SELECT r.realized_adg INTO v_realized
          FROM public.lot_realized_adg r WHERE r.lot_id = p_lot_id;
        v_base_adg    := v_realized;
        v_base_source := CASE WHEN v_confidence = 'thin' THEN 'realized_thin' ELSE 'realized' END;
    ELSE
        v_base_adg    := v_target_adg;
        v_base_source := 'assumed';
    END IF;

    v_arrival := public.lot_weighted_arrival_date(p_lot_id);
    v_days    := GREATEST(p_on_date - v_anchor_date, 0);

    -- The walk. A hand-entered phase still wins the day it covers; every
    -- other day takes the base rate chosen above.
    SELECT COALESCE(SUM(d.adg), 0),
           COUNT(*) FILTER (WHERE d.from_phase)
      INTO v_gain, v_phase_days
      FROM (
        SELECT COALESCE(ph.adg_lb_per_day, v_base_adg) AS adg,
               ph.adg_lb_per_day IS NOT NULL           AS from_phase
          FROM generate_series(v_anchor_date + 1, p_on_date, INTERVAL '1 day') AS gs(d)
          LEFT JOIN LATERAL (
              SELECT p.adg_lb_per_day
                FROM public.lot_adg_phases p
               WHERE p.lot_id = p_lot_id
                 AND v_arrival IS NOT NULL
                 AND (gs.d::DATE - v_arrival) >= p.start_day
                 AND (p.end_day IS NULL OR (gs.d::DATE - v_arrival) <= p.end_day)
               ORDER BY p.phase_order, p.start_day
               LIMIT 1
          ) ph ON TRUE
      ) d;

    IF v_days > 0 THEN
        v_rate   := v_gain / v_days;
        v_source := CASE WHEN v_phase_days > 0 THEN 'phase' ELSE v_base_source END;
    ELSE
        SELECT p.adg_lb_per_day INTO v_rate
          FROM public.lot_adg_phases p
         WHERE p.lot_id = p_lot_id
           AND v_arrival IS NOT NULL
           AND ((p_on_date + 1) - v_arrival) >= p.start_day
           AND (p.end_day IS NULL OR ((p_on_date + 1) - v_arrival) <= p.end_day)
         ORDER BY p.phase_order, p.start_day
         LIMIT 1;
        v_source := CASE WHEN v_rate IS NOT NULL THEN 'phase' ELSE v_base_source END;
        v_rate   := COALESCE(v_rate, v_base_adg);
    END IF;

    RETURN QUERY SELECT
        v_anchor_avg + v_gain,
        v_anchor_date,
        v_anchor_type,
        v_days,
        v_rate,
        v_source;
END;
$function$;

comment on function public.lot_projected_weight_detail(uuid, date) is
    'Projected weight WITH provenance. Daily rate precedence: lot_adg_phases, then the lot''s own realized ADG off real pay weights once the sample earns it, then lots.target_adg. adg_source says which: phase | realized | realized_thin | assumed.';

-- =====================================================================
-- lot_status carries the rate and its source, APPENDED.
-- The LATERAL already computes both; this only stops throwing them away,
-- so a screen can say "on the lot's own 1.473, not the 1.80 assumption"
-- instead of quietly showing a different number than it did yesterday.
-- =====================================================================
create or replace view public.lot_status
with (security_invoker = true) as
 WITH inv AS (
         SELECT invoices.lot_id,
            sum(invoices.head_count)::integer AS head_in_invoiced,
            sum(invoices.total_weight_lb) AS total_weight_lb,
            sum(invoices.total_cost) AS total_cost
           FROM invoices GROUP BY invoices.lot_id
        ), rcpt AS (
         SELECT delivery_receipts.lot_id,
            sum(delivery_receipts.head_count)::integer AS head_in_received
           FROM delivery_receipts GROUP BY delivery_receipts.lot_id
        ), ev AS (
         SELECT lot_events.lot_id,
            sum(CASE WHEN lot_events.event_type = 'death'::text THEN abs(lot_events.head_count) ELSE 0 END)::integer AS head_dead,
            sum(CASE WHEN lot_events.event_type = 'sold'::text THEN abs(lot_events.head_count) ELSE 0 END)::integer AS head_sold_legacy,
            sum(CASE WHEN lot_events.event_type = 'transfer_out'::text THEN abs(lot_events.head_count) ELSE 0 END)::integer AS head_transfer_out,
            sum(CASE WHEN lot_events.event_type = 'transfer_in'::text THEN abs(lot_events.head_count) ELSE 0 END)::integer AS head_transfer_in,
            sum(CASE WHEN lot_events.event_type = 'adjustment'::text THEN lot_events.head_count ELSE 0 END)::integer AS head_adjustment
           FROM lot_events GROUP BY lot_events.lot_id
        ), s AS (
         SELECT sales.lot_id, sum(sales.head_count)::integer AS head_sold_new
           FROM sales GROUP BY sales.lot_id
        )
 SELECT l.id AS lot_id,
    l.lot_number, l.arrival_date, l.fiscal_year, l.source, l.sex_class,
    l.target_adg, l.closed_at,
    GREATEST(COALESCE(inv.head_in_invoiced, 0), COALESCE(rcpt.head_in_received, 0)) AS head_in,
    COALESCE(ev.head_dead, 0) AS head_dead,
    COALESCE(ev.head_sold_legacy, 0) + COALESCE(s.head_sold_new, 0) AS head_sold,
    COALESCE(ev.head_transfer_out, 0) AS head_transferred_out,
    GREATEST(COALESCE(inv.head_in_invoiced, 0), COALESCE(rcpt.head_in_received, 0)) - COALESCE(ev.head_dead, 0) - (COALESCE(ev.head_sold_legacy, 0) + COALESCE(s.head_sold_new, 0)) - COALESCE(ev.head_transfer_out, 0) + COALESCE(ev.head_transfer_in, 0) + COALESCE(ev.head_adjustment, 0) AS head_current,
    inv.total_weight_lb AS total_weight_in,
    inv.total_cost AS total_cost_in,
        CASE WHEN inv.head_in_invoiced > 0 THEN inv.total_weight_lb / inv.head_in_invoiced::numeric ELSE NULL::numeric END AS avg_weight_in,
        CASE WHEN inv.total_weight_lb > 0::numeric THEN inv.total_cost / inv.total_weight_lb ELSE NULL::numeric END AS avg_cost_per_lb,
        CASE WHEN inv.head_in_invoiced > 0 THEN inv.total_cost / inv.head_in_invoiced::numeric ELSE NULL::numeric END AS avg_cost_per_head,
    lot_weighted_arrival_date(l.id) AS weighted_arrival_date,
    lot_projected_weight(l.id, CURRENT_DATE) AS projected_current_weight,
        CASE WHEN l.closed_at IS NOT NULL THEN l.closed_at::date - l.arrival_date ELSE CURRENT_DATE - l.arrival_date END AS days_on_feed,
        CASE WHEN lot_weighted_arrival_date(l.id) IS NOT NULL THEN CURRENT_DATE - lot_weighted_arrival_date(l.id) ELSE NULL::integer END AS days_since_weighted_arrival,
    COALESCE(inv.head_in_invoiced, 0) AS head_in_invoiced,
    COALESCE(rcpt.head_in_received, 0) AS head_in_received,
    GREATEST(COALESCE(rcpt.head_in_received, 0) - COALESCE(inv.head_in_invoiced, 0), 0) AS head_pending_invoice,
    pwd.anchor_date,
    pwd.anchor_type,
    pwd.days_since_anchor,
    pwd.adg_used,
    pwd.adg_source
   FROM lots l
     LEFT JOIN inv ON inv.lot_id = l.id
     LEFT JOIN rcpt ON rcpt.lot_id = l.id
     LEFT JOIN ev ON ev.lot_id = l.id
     LEFT JOIN s ON s.lot_id = l.id
     LEFT JOIN LATERAL public.lot_projected_weight_detail(l.id, CURRENT_DATE) pwd ON TRUE;

-- =====================================================================
-- VERIFY
-- =====================================================================
do $verify$
DECLARE
    v_txt  text;
    v_n    integer;
BEGIN
    -- A lot with nothing shipped must not have moved at all.
    SELECT string_agg(ls.lot_number || ': ' || b.projected_current_weight || ' -> ' || ls.projected_current_weight, ', ')
      INTO v_txt
      FROM public.lot_status ls
      JOIN _adg_before b ON b.lot_id = ls.lot_id
     WHERE ls.adg_source = 'assumed'
       AND ls.projected_current_weight IS DISTINCT FROM b.projected_current_weight;
    IF v_txt IS NOT NULL THEN
        RAISE EXCEPTION 'A lot still on the assumption moved: %. Only lots with a believable realized ADG may move.', v_txt;
    END IF;

    -- Every lot that DID move must say why.
    SELECT string_agg(ls.lot_number, ', ') INTO v_txt
      FROM public.lot_status ls
      JOIN _adg_before b ON b.lot_id = ls.lot_id
     WHERE ls.projected_current_weight IS DISTINCT FROM b.projected_current_weight
       AND ls.adg_source NOT IN ('realized','realized_thin');
    IF v_txt IS NOT NULL THEN
        RAISE EXCEPTION 'These lots moved without a realized rate to explain it: %.', v_txt;
    END IF;

    -- The gates are on the sample, so a lot with nothing sold can never qualify.
    SELECT string_agg(ls.lot_number, ', ') INTO v_txt
      FROM public.lot_status ls
     WHERE ls.head_sold = 0 AND ls.adg_source IN ('realized','realized_thin');
    IF v_txt IS NOT NULL THEN
        RAISE EXCEPTION 'A lot with nothing sold is claiming a realized rate: %.', v_txt;
    END IF;

    -- adg_used has to reproduce the number, or the provenance is decorative.
    SELECT string_agg(ls.lot_number, ', ') INTO v_txt
      FROM public.lot_status ls
      JOIN public.lot_weight_anchor a ON a.lot_id = ls.lot_id
     WHERE ls.projected_current_weight IS NOT NULL
       AND ls.days_since_anchor > 0
       AND abs((a.anchor_avg_weight_lb + ls.adg_used * ls.days_since_anchor)
               - ls.projected_current_weight) > 0.01;
    IF v_txt IS NOT NULL THEN
        RAISE EXCEPTION 'anchor + adg_used x days does not reproduce the projection on: %.', v_txt;
    END IF;

    -- The view kept RLS and its column order.
    SELECT COALESCE(reloptions::text,'') INTO v_txt FROM pg_class WHERE oid='public.lot_status'::regclass;
    IF v_txt NOT LIKE '%security_invoker=true%' THEN
        RAISE EXCEPTION 'lot_status lost security_invoker: %', v_txt;
    END IF;
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_txt
      FROM information_schema.columns
     WHERE table_schema='public' AND table_name='lot_status' AND ordinal_position > 25;
    IF v_txt <> 'anchor_date,anchor_type,days_since_anchor,adg_used,adg_source' THEN
        RAISE EXCEPTION 'lot_status columns 26+ are "%", not the five appended ones.', v_txt;
    END IF;

    SELECT count(*) INTO v_n FROM public.lot_status WHERE adg_source IN ('realized','realized_thin');
    RAISE NOTICE 'Realized-ADG projection live on % lot(s).', v_n;
END
$verify$;

drop table if exists _adg_before;

commit;
