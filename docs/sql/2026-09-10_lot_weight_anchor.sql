-- 2026-09-10  lot_projected_weight() anchors on the most recent REAL weight.
--
-- Until now the projection ignored every weight taken after purchase:
--
--     avg weight off the invoices  +  (today - weighted arrival) x target_adg
--
-- so a lot weighed on the scale in month five still read as an arrival weight
-- carried forward on an assumption. This migration gives the projection an
-- ANCHOR - the newest weight we actually believe - and walks forward from
-- there, through lot_adg_phases where they exist.
--
-- This REVERSES, deliberately and at John's instruction (2026-09-10, the CFO
-- project), the standing "nothing reads `weights` yet" decision of
-- 2026-09-07. That decision's reason was sound and is answered rather than
-- ignored: a pasture draft is full of grass and water and the first 20 head
-- into the trap are the gentle ones, not a random sample. So a weight only
-- becomes an anchor when it is affirmatively marked as covering the WHOLE
-- lot (`coverage = 'whole_lot'` AND `applies_to = 'lot'`). Everything the
-- field app writes today is a sampled draft and anchors nothing.
--
-- A. `weights` gains `coverage` ('whole_lot' | 'sample'), documented CHECKs
--    on weight_type / applies_to / coverage, and a partial anchor index.
-- B. New view `public.lot_weight_anchor` - one row per lot, the anchor and
--    where it came from.
-- C. `lot_projected_weight()` is rewritten on top of the anchor, keeping its
--    exact signature, return type, volatility and SECURITY DEFINER posture.
-- D. New `public.lot_projected_weight_detail()` returns the number WITH its
--    provenance. It is the single implementation; the scalar function is now
--    a thin wrapper over it, so the two can never disagree.
-- E. `lot_status` gains anchor_date / anchor_type / days_since_anchor,
--    APPENDED - no existing column is renamed, reordered or re-expressed.
--
-- SAFETY: with `weights` and `lot_adg_phases` both empty, every lot falls to
-- the purchase anchor and the arithmetic is identical to the old function.
-- The verify block at the bottom PROVES that inside this transaction: it
-- snapshots lot_status.projected_current_weight before the rewrite and
-- raises if any lot moves by so much as the last decimal place.
--
-- Idempotent: guarded ALTERs, CREATE OR REPLACE throughout.
-- Paste into the SQL editor WITHOUT the begin/commit lines.
begin;

-- =====================================================================
-- 0. Snapshot every lot's projected weight BEFORE anything changes.
--    `on commit preserve rows` so this also works pasted statement by
--    statement into the SQL editor, where there is no transaction.
-- =====================================================================
drop table if exists _pw_before;
create temp table _pw_before on commit preserve rows as
select lot_id, projected_current_weight
  from public.lot_status;

-- =====================================================================
-- A. `weights`: say out loud what each row covers
--
--    weight_type says WHAT KIND of weighing it was.
--    applies_to  says WHAT THE SAMPLE STANDS FOR - the pasture it came off
--                or the whole lot. The office decides that at approval.
--    coverage    says WHETHER EVERY HEAD WAS ON THE SCALE.
--
--    The third is the one this change needs and the reason it cannot be
--    folded into applies_to: the office is explicitly allowed to say a
--    20-head draft stands for the lot average (applies_to = 'lot'), and
--    that is NOT the same statement as "we ran all 585 head across the
--    scale". Only the second is a valid anchor for a lot average, so the
--    two have to be distinguishable.
--
--    The default is 'sample' on purpose. Anchoring is opt-in: a caller
--    that says nothing has not claimed whole-lot coverage, and no row
--    written by the field app's approval path becomes an anchor by
--    accident.
-- =====================================================================
alter table public.weights
    add column if not exists coverage text not null default 'sample';

do $$
begin
    -- weight_type: the occasion. 'arrival' at receiving, 'chute' run through
    -- the working chute, 'pasture_check' a draft pulled out of a pasture,
    -- 'sale' a pay weight off the buyer's scale, 'individual' one animal,
    -- 'other' anything else. The list already existed; it is asserted here
    -- rather than assumed, and documented below.
    if exists (select 1 from pg_constraint
               where conname = 'weights_weight_type_check'
                 and conrelid = 'public.weights'::regclass) then
        alter table public.weights drop constraint weights_weight_type_check;
    end if;
    alter table public.weights add constraint weights_weight_type_check
        check (weight_type = any (array[
            'arrival','chute','pasture_check','sale','individual','other']));

    -- applies_to: scope. NULL is still permitted - the field app writes the
    -- row before the office has decided - and NULL never anchors.
    if exists (select 1 from pg_constraint
               where conname = 'weights_applies_to_check'
                 and conrelid = 'public.weights'::regclass) then
        alter table public.weights drop constraint weights_applies_to_check;
    end if;
    alter table public.weights add constraint weights_applies_to_check
        check (applies_to is null or applies_to = any (array['pasture','lot']));

    if exists (select 1 from pg_constraint
               where conname = 'weights_coverage_check'
                 and conrelid = 'public.weights'::regclass) then
        alter table public.weights drop constraint weights_coverage_check;
    end if;
    alter table public.weights add constraint weights_coverage_check
        check (coverage = any (array['whole_lot','sample']));

    -- A pay weight and a single animal are never whole-lot coverage of a
    -- lot still standing: the sale weight belongs to cattle that LEFT, and
    -- one head is not a lot average. Refuse the contradiction at the door
    -- rather than filtering it out in six different readers later.
    if exists (select 1 from pg_constraint
               where conname = 'weights_coverage_type_check'
                 and conrelid = 'public.weights'::regclass) then
        alter table public.weights drop constraint weights_coverage_type_check;
    end if;
    alter table public.weights add constraint weights_coverage_type_check
        check (coverage = 'sample'
               or weight_type <> all (array['sale','individual']));
end $$;

comment on column public.weights.weight_type is
    'Occasion: arrival | chute | pasture_check | sale | individual | other.';
comment on column public.weights.applies_to is
    'Scope this sample stands for: pasture | lot. Office decides at approval; NULL until then.';
comment on column public.weights.coverage is
    'whole_lot = every head was on the scale. sample = a draft. Only whole_lot + applies_to=lot anchors lot_projected_weight(); default sample so anchoring is opt-in.';

-- The anchor lookup is "newest qualifying row for this lot"; index exactly
-- the rows that qualify.
create index if not exists weights_anchor_idx
    on public.weights (lot_id, weigh_date desc)
    where coverage = 'whole_lot' and applies_to = 'lot';

create index if not exists lot_adg_phases_lot_order_idx
    on public.lot_adg_phases (lot_id, phase_order, start_day);

-- =====================================================================
-- B. public.lot_weight_anchor - where the projection starts, and why
--
--    One row per lot, ALWAYS: a lot with neither a whole-lot weight nor
--    invoices gets a row with NULL anchor columns rather than vanishing,
--    so a dashboard can show "no anchor" instead of showing nothing.
--
--    Precedence, newest first:
--      a) the latest whole-lot weighing on or before the RANCH's today
--      b) the purchase weight off the invoices, dated at the weighted
--         arrival date
--
--    A sale weight is never an anchor for the head still here - the CHECK
--    above makes that unrepresentable, and the WHERE repeats it so the
--    rule is readable where it is relied on.
--
--    One weighing is often several scale drafts sharing a weigh_session_id,
--    so the drafts are summed back into one weighing before the newest is
--    picked. Weighing 585 head in six drags is one anchor, not six.
--
--    ranch_today(), not CURRENT_DATE: the database runs UTC and the ranch
--    does not, so after 7pm Central CURRENT_DATE would admit a weight the
--    ranch has not yet had a day for, and days_since_anchor would count a
--    day Texas has not had. NOTE the deliberate difference from
--    lot_status.days_since_anchor, which is on CURRENT_DATE so it agrees
--    with the projected weight printed beside it - see section E.
-- =====================================================================
create or replace view public.lot_weight_anchor
with (security_invoker = true) as
with sessions as (
    select w.lot_id,
           coalesce(w.weigh_session_id::text, 'd:' || w.weigh_date::text) as session_key,
           w.weigh_date,
           sum(w.head_weighed)                  as anchor_head,
           sum(w.total_weight_lb)               as booked_weight_lb,
           max(w.created_at)                    as last_recorded_at
      from public.weights w
     where w.coverage    = 'whole_lot'
       and w.applies_to  = 'lot'
       and w.weight_type <> all (array['sale','individual'])
       and w.weigh_date <= public.ranch_today()
     group by w.lot_id,
              coalesce(w.weigh_session_id::text, 'd:' || w.weigh_date::text),
              w.weigh_date
    having sum(w.head_weighed) > 0
       and sum(w.total_weight_lb) > 0
), newest as (
    select distinct on (s.lot_id)
           s.lot_id, s.weigh_date, s.anchor_head, s.booked_weight_lb
      from sessions s
     order by s.lot_id, s.weigh_date desc, s.last_recorded_at desc
), purchase as (
    -- The same two sums, and the same two guards, the old function used.
    select i.lot_id,
           sum(i.head_count)      as head_in,
           sum(i.total_weight_lb) as weight_in
      from public.invoices i
     group by i.lot_id
    having sum(i.head_count) > 0
       and sum(i.total_weight_lb) > 0
)
select
    l.id as lot_id,
    case when n.lot_id is not null then n.weigh_date else wa.arrival_date end
        as anchor_date,
    case when n.lot_id is not null then 'test_weight'
         when p.lot_id is not null and wa.arrival_date is not null then 'purchase'
    end as anchor_type,
    case when n.lot_id is not null then n.booked_weight_lb / n.anchor_head
         when p.lot_id is not null and wa.arrival_date is not null
              then p.weight_in / p.head_in
    end as anchor_avg_weight_lb,
    case when n.lot_id is not null then n.anchor_head::integer
         when p.lot_id is not null and wa.arrival_date is not null
              then p.head_in::integer
    end as anchor_head,
    case when n.lot_id is not null
              then greatest(public.ranch_today() - n.weigh_date, 0)
         when p.lot_id is not null and wa.arrival_date is not null
              then greatest(public.ranch_today() - wa.arrival_date, 0)
    end as days_since_anchor
  from public.lots l
  left join newest   n on n.lot_id = l.id
  left join purchase p on p.lot_id = l.id
  cross join lateral (
      select public.lot_weighted_arrival_date(l.id) as arrival_date
  ) wa;

comment on view public.lot_weight_anchor is
    'The weight lot_projected_weight() starts from, and where it came from. Newest whole-lot weighing beats the purchase weight; a sale weight is never an anchor for the head still standing. One row per lot; NULL anchor columns mean the lot has neither.';

revoke all on public.lot_weight_anchor from public;
revoke all on public.lot_weight_anchor from anon;
grant select on public.lot_weight_anchor to authenticated;
grant select on public.lot_weight_anchor to service_role;

-- =====================================================================
-- D. lot_projected_weight_detail() - the implementation, with provenance
--
--    Walks day by day from the anchor to p_on_date. Each day takes the ADG
--    of the lot_adg_phase whose [start_day, end_day] contains that day's
--    day-number measured from the WEIGHTED ARRIVAL DATE - phases describe a
--    lot's life from when the cattle landed, not from when we last weighed
--    them - and falls back to lots.target_adg where no phase covers it.
--    A NULL target_adg is 0, as before.
--
--    adg_used is the BLENDED rate actually applied across the walk, so
--    anchor_avg + adg_used x days_since_anchor always reproduces the
--    number. Where the span is empty it reports the rate in effect on the
--    next day, which is what a dashboard wants to show.
--    adg_source is 'phase' if any day drew from a phase, else 'assumed'.
--
--    Returns NO ROW when the lot has no anchor at all, which is what makes
--    the scalar wrapper return NULL.
--
--    SECURITY DEFINER with a pinned search_path, matching the function it
--    backs: lot_projected_weight has been definer since it was written, and
--    that is why crew - who cannot read `invoices` - still see a projected
--    weight on the lot list. Making the detail function invoker would have
--    given crew a number with no provenance beside it. It exposes no
--    dollars: a weight, a date, a source and a rate.
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

    -- No anchor: no invoices and no whole-lot weighing. Nothing to project
    -- from, and inventing a starting weight would be worse than a blank.
    IF v_anchor_date IS NULL OR v_anchor_avg IS NULL THEN
        RETURN;
    END IF;

    SELECT COALESCE(l.target_adg, 0) INTO v_target_adg
      FROM public.lots l WHERE l.id = p_lot_id;
    v_target_adg := COALESCE(v_target_adg, 0);

    v_arrival := public.lot_weighted_arrival_date(p_lot_id);
    v_days    := GREATEST(p_on_date - v_anchor_date, 0);

    -- The walk. One row per day gained, each at its own phase's rate.
    SELECT COALESCE(SUM(d.adg), 0),
           COUNT(*) FILTER (WHERE d.from_phase)
      INTO v_gain, v_phase_days
      FROM (
        SELECT COALESCE(ph.adg_lb_per_day, v_target_adg) AS adg,
               ph.adg_lb_per_day IS NOT NULL             AS from_phase
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
        v_source := CASE WHEN v_phase_days > 0 THEN 'phase' ELSE 'assumed' END;
    ELSE
        -- Nothing gained yet; report the rate that would apply tomorrow.
        SELECT p.adg_lb_per_day INTO v_rate
          FROM public.lot_adg_phases p
         WHERE p.lot_id = p_lot_id
           AND v_arrival IS NOT NULL
           AND ((p_on_date + 1) - v_arrival) >= p.start_day
           AND (p.end_day IS NULL OR ((p_on_date + 1) - v_arrival) <= p.end_day)
         ORDER BY p.phase_order, p.start_day
         LIMIT 1;
        v_source := CASE WHEN v_rate IS NOT NULL THEN 'phase' ELSE 'assumed' END;
        v_rate   := COALESCE(v_rate, v_target_adg);
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
    'Projected weight WITH provenance: which anchor it started from, how old that anchor is, the blended ADG applied and whether that came from lot_adg_phases or the lot assumption. The single implementation - lot_projected_weight() is a wrapper over it.';

revoke all on function public.lot_projected_weight_detail(uuid, date) from public;
revoke all on function public.lot_projected_weight_detail(uuid, date) from anon;
grant execute on function public.lot_projected_weight_detail(uuid, date) to authenticated;
grant execute on function public.lot_projected_weight_detail(uuid, date) to service_role;

-- =====================================================================
-- C. lot_projected_weight() - same signature, same return type, same
--    volatility, same security posture. Every existing caller is
--    untouched; only the number's derivation changed, and only once
--    there is a whole-lot weight or an ADG phase to change it.
-- =====================================================================
create or replace function public.lot_projected_weight(
    p_lot_id uuid,
    p_on_date date default current_date
)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $function$
    SELECT d.projected_weight_lb
      FROM public.lot_projected_weight_detail(p_lot_id, p_on_date) d;
$function$;

comment on function public.lot_projected_weight(uuid, date) is
    'Projected average weight per head. Anchors on the most recent whole-lot weighing, else the purchase weight, and walks forward at lot_adg_phases where they exist, else lots.target_adg. NULL only when the lot has no anchor at all.';

-- =====================================================================
-- E. lot_status gains the provenance columns. APPENDED at the end -
--    nothing above them is renamed, reordered or re-expressed, and
--    projected_current_weight keeps the exact expression it had.
--
--    The three new columns come through the SECURITY DEFINER detail
--    function rather than through lot_weight_anchor directly, because
--    that view is (correctly) security_invoker: read as crew, its
--    purchase branch reads `invoices` and returns nothing, and the lot
--    list would show a projected weight beside a blank anchor.
--
--    They are evaluated at CURRENT_DATE, matching this view's other three
--    date-based columns (projected_current_weight, days_on_feed,
--    days_since_weighted_arrival). ranch_today() is the correct basis for
--    a day count and lot_weight_anchor uses it - but lot_status is
--    uniformly CURRENT_DATE today, and a single ranch-day column dropped
--    into a UTC-day view is worse than either: days_since_anchor would
--    read one day behind projected_current_weight's basis every evening
--    Central, so a dashboard dividing the gain by the days would read
--    double the real ADG for those hours, silently. Moving the whole view
--    onto ranch_today() moves projected_current_weight with it, which is a
--    deliberate change to a live number and belongs in its own migration.
--
--    WITH (security_invoker = true) is REPEATED because CREATE OR REPLACE
--    VIEW clears reloptions when the clause is omitted - it does not carry
--    them forward - which would silently strip RLS enforcement off a view
--    whose definition looks unchanged.
-- =====================================================================
create or replace view public.lot_status
with (security_invoker = true) as
 WITH inv AS (
         SELECT invoices.lot_id,
            sum(invoices.head_count)::integer AS head_in_invoiced,
            sum(invoices.total_weight_lb) AS total_weight_lb,
            sum(invoices.total_cost) AS total_cost
           FROM invoices
          GROUP BY invoices.lot_id
        ), rcpt AS (
         SELECT delivery_receipts.lot_id,
            sum(delivery_receipts.head_count)::integer AS head_in_received
           FROM delivery_receipts
          GROUP BY delivery_receipts.lot_id
        ), ev AS (
         SELECT lot_events.lot_id,
            sum(
                CASE
                    WHEN lot_events.event_type = 'death'::text THEN abs(lot_events.head_count)
                    ELSE 0
                END)::integer AS head_dead,
            sum(
                CASE
                    WHEN lot_events.event_type = 'sold'::text THEN abs(lot_events.head_count)
                    ELSE 0
                END)::integer AS head_sold_legacy,
            sum(
                CASE
                    WHEN lot_events.event_type = 'transfer_out'::text THEN abs(lot_events.head_count)
                    ELSE 0
                END)::integer AS head_transfer_out,
            sum(
                CASE
                    WHEN lot_events.event_type = 'transfer_in'::text THEN abs(lot_events.head_count)
                    ELSE 0
                END)::integer AS head_transfer_in,
            sum(
                CASE
                    WHEN lot_events.event_type = 'adjustment'::text THEN lot_events.head_count
                    ELSE 0
                END)::integer AS head_adjustment
           FROM lot_events
          GROUP BY lot_events.lot_id
        ), s AS (
         SELECT sales.lot_id,
            sum(sales.head_count)::integer AS head_sold_new
           FROM sales
          GROUP BY sales.lot_id
        )
 SELECT l.id AS lot_id,
    l.lot_number,
    l.arrival_date,
    l.fiscal_year,
    l.source,
    l.sex_class,
    l.target_adg,
    l.closed_at,
    GREATEST(COALESCE(inv.head_in_invoiced, 0), COALESCE(rcpt.head_in_received, 0)) AS head_in,
    COALESCE(ev.head_dead, 0) AS head_dead,
    COALESCE(ev.head_sold_legacy, 0) + COALESCE(s.head_sold_new, 0) AS head_sold,
    COALESCE(ev.head_transfer_out, 0) AS head_transferred_out,
    GREATEST(COALESCE(inv.head_in_invoiced, 0), COALESCE(rcpt.head_in_received, 0)) - COALESCE(ev.head_dead, 0) - (COALESCE(ev.head_sold_legacy, 0) + COALESCE(s.head_sold_new, 0)) - COALESCE(ev.head_transfer_out, 0) + COALESCE(ev.head_transfer_in, 0) + COALESCE(ev.head_adjustment, 0) AS head_current,
    inv.total_weight_lb AS total_weight_in,
    inv.total_cost AS total_cost_in,
        CASE
            WHEN inv.head_in_invoiced > 0 THEN inv.total_weight_lb / inv.head_in_invoiced::numeric
            ELSE NULL::numeric
        END AS avg_weight_in,
        CASE
            WHEN inv.total_weight_lb > 0::numeric THEN inv.total_cost / inv.total_weight_lb
            ELSE NULL::numeric
        END AS avg_cost_per_lb,
        CASE
            WHEN inv.head_in_invoiced > 0 THEN inv.total_cost / inv.head_in_invoiced::numeric
            ELSE NULL::numeric
        END AS avg_cost_per_head,
    lot_weighted_arrival_date(l.id) AS weighted_arrival_date,
    lot_projected_weight(l.id, CURRENT_DATE) AS projected_current_weight,
        CASE
            WHEN l.closed_at IS NOT NULL THEN l.closed_at::date - l.arrival_date
            ELSE CURRENT_DATE - l.arrival_date
        END AS days_on_feed,
        CASE
            WHEN lot_weighted_arrival_date(l.id) IS NOT NULL THEN CURRENT_DATE - lot_weighted_arrival_date(l.id)
            ELSE NULL::integer
        END AS days_since_weighted_arrival,
    COALESCE(inv.head_in_invoiced, 0) AS head_in_invoiced,
    COALESCE(rcpt.head_in_received, 0) AS head_in_received,
    GREATEST(COALESCE(rcpt.head_in_received, 0) - COALESCE(inv.head_in_invoiced, 0), 0) AS head_pending_invoice,
    pwd.anchor_date,
    pwd.anchor_type,
    pwd.days_since_anchor
   FROM lots l
     LEFT JOIN inv ON inv.lot_id = l.id
     LEFT JOIN rcpt ON rcpt.lot_id = l.id
     LEFT JOIN ev ON ev.lot_id = l.id
     LEFT JOIN s ON s.lot_id = l.id
     LEFT JOIN LATERAL public.lot_projected_weight_detail(l.id, CURRENT_DATE) pwd ON TRUE;

-- =====================================================================
-- VERIFY - raises rather than reporting a quiet success
-- =====================================================================
do $verify$
DECLARE
    v_drift    TEXT;
    v_n        INTEGER;
    v_opts     TEXT;
    v_missing  TEXT;
BEGIN
    -- 1. Not one lot's projected weight moved.
    SELECT string_agg(ls.lot_id::text || ': ' || COALESCE(b.projected_current_weight::text,'NULL')
                        || ' -> ' || COALESCE(ls.projected_current_weight::text,'NULL'), ', ')
      INTO v_drift
      FROM public.lot_status ls
      JOIN _pw_before b ON b.lot_id = ls.lot_id
     WHERE ls.projected_current_weight IS DISTINCT FROM b.projected_current_weight;
    IF v_drift IS NOT NULL THEN
        RAISE EXCEPTION 'lot_projected_weight moved on: %. With weights and lot_adg_phases empty it must be identical.', v_drift;
    END IF;

    SELECT count(*) INTO v_n FROM _pw_before;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'The before-snapshot is empty; the comparison proved nothing.';
    END IF;

    -- 2. Every lot has exactly one anchor row.
    SELECT count(*) INTO v_n FROM public.lots;
    IF (SELECT count(*) FROM public.lot_weight_anchor) <> v_n THEN
        RAISE EXCEPTION 'lot_weight_anchor is not one row per lot (% lots, % rows).',
            v_n, (SELECT count(*) FROM public.lot_weight_anchor);
    END IF;

    -- 3. An anchor row is internally consistent.
    SELECT string_agg(a.lot_id::text, ', ') INTO v_drift
      FROM public.lot_weight_anchor a
     WHERE (a.anchor_date IS NULL) <> (a.anchor_type IS NULL)
        OR (a.anchor_date IS NOT NULL
            AND (a.anchor_avg_weight_lb IS NULL OR a.anchor_head IS NULL
                 OR a.anchor_type <> ALL (ARRAY['test_weight','purchase'])));
    IF v_drift IS NOT NULL THEN
        RAISE EXCEPTION 'lot_weight_anchor rows are half-populated: %.', v_drift;
    END IF;

    -- 4. Both views still enforce RLS. CREATE OR REPLACE VIEW clears
    --    reloptions when the WITH clause is omitted, and a view running as
    --    its owner bypasses every policy underneath it.
    FOR v_missing, v_opts IN
        SELECT c.relname, COALESCE(c.reloptions::text, '')
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname IN ('lot_status','lot_weight_anchor')
    LOOP
        IF v_opts NOT LIKE '%security_invoker=true%' THEN
            RAISE EXCEPTION 'View % lost security_invoker: RLS is bypassed. reloptions = %', v_missing, v_opts;
        END IF;
    END LOOP;

    -- 5. Nothing reached anon, and the definer functions kept their pin.
    IF has_table_privilege('anon', 'public.lot_weight_anchor', 'SELECT') THEN
        RAISE EXCEPTION 'anon can read lot_weight_anchor. The publishable key is public.';
    END IF;
    IF has_function_privilege('anon', 'public.lot_projected_weight_detail(uuid,date)', 'EXECUTE')
       OR has_function_privilege('anon', 'public.lot_projected_weight(uuid,date)', 'EXECUTE') THEN
        RAISE EXCEPTION 'anon can execute a SECURITY DEFINER projection function.';
    END IF;

    SELECT string_agg(p.proname, ', ') INTO v_missing
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('lot_projected_weight','lot_projected_weight_detail')
       AND (p.prosecdef IS NOT TRUE
            OR p.proconfig IS NULL
            OR NOT (p.proconfig::text LIKE '%search_path=public%'));
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'SECURITY DEFINER function without a pinned search_path: %.', v_missing;
    END IF;

    -- 6. One overload each, or PostgREST cannot resolve the RPC.
    SELECT string_agg(c.proname || ' x' || c.n, ', ') INTO v_missing
      FROM (SELECT p.proname, count(*) AS n
              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public'
               AND p.proname IN ('lot_projected_weight','lot_projected_weight_detail')
             GROUP BY p.proname) c
     WHERE c.n <> 1;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Overloaded projection function - PostgREST cannot resolve it: %.', v_missing;
    END IF;

    -- 7. lot_status kept every column it had, in order, with three appended.
    IF (SELECT count(*) FROM information_schema.columns
         WHERE table_schema='public' AND table_name='lot_status') <> 28 THEN
        RAISE EXCEPTION 'lot_status should now carry 28 columns, has %.',
            (SELECT count(*) FROM information_schema.columns
              WHERE table_schema='public' AND table_name='lot_status');
    END IF;
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_missing
      FROM information_schema.columns
     WHERE table_schema='public' AND table_name='lot_status' AND ordinal_position > 25;
    IF v_missing <> 'anchor_date,anchor_type,days_since_anchor' THEN
        RAISE EXCEPTION 'lot_status columns 26-28 are "%", not the three appended anchor columns.', v_missing;
    END IF;

    -- 8. The coverage default cannot make a sampled draft an anchor.
    IF (SELECT column_default FROM information_schema.columns
         WHERE table_schema='public' AND table_name='weights' AND column_name='coverage')
       NOT LIKE '%sample%' THEN
        RAISE EXCEPTION 'weights.coverage does not default to sample; field drafts would anchor the projection.';
    END IF;

    RAISE NOTICE 'lot_weight_anchor verified: % lots, projected weight unchanged on every one, both views security_invoker, nothing granted to anon.', v_n;
END
$verify$;

drop table if exists _pw_before;

commit;
