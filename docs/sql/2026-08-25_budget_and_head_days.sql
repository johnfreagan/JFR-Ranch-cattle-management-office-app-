-- =====================================================================
-- Phase 1 of the cost ledger / projection work:
--   1. lot_budgets    - the plan for a lot, frozen the day it starts
--   2. lot_daily_head - exact head on hand, per lot, per day
--   3. lot_head_days  - the monthly rollup that costs get charged against
-- =====================================================================
-- 2026-08-25.
--
-- WHY A FROZEN BUDGET
--
-- The closeout tab keeps its assumptions as columns on `lots`, and Save
-- overwrites them. There is therefore no way to ask the only question that
-- matters when a lot closes: did it do what we said it would? A frozen
-- budget answers that. It is written once, when the lot starts, and nothing
-- can edit it afterwards - re-forecasting happens in the working
-- assumptions on `lots`, which stay freely editable.
--
-- Purchase assumptions are included on purpose. Nothing in the app has ever
-- recorded what you INTENDED to pay for the cattle, only what you did pay,
-- so "did I buy them right?" has not been answerable.
--
-- WHY HEAD-DAYS, AND WHY FROM HEAD MATH RATHER THAN PASTURE ASSIGNMENTS
--
-- A per-head-per-day cost multiplied by today's head count and total days
-- is wrong on any lot that lost or shipped cattle along the way. 37X-1 is
-- carrying 75 head today but averaged 134 through August; charging cost of
-- gain on 75 understates this month by 44%. Head-days fix that, and they
-- also let cost follow cattle that already shipped, which the current
-- closeout explicitly gives up on.
--
-- The obvious source is lot_pasture_assignments, and it is the wrong one.
-- 37X's assignment history begins 2026-04-27 while its first invoice is
-- 2025-12-04 - the April import scar. Building on assignments would drop
-- 144 days x ~340 head, about $36,700 of cost of gain, silently. The head
-- curve below is derived from the same events lot_status uses, so it
-- reconciles to head_current by construction and has no coverage hole.
--
-- The ranch/pasture dimension is deliberately NOT built here. It is only
-- needed to allocate a ranch-level cost, and pasture cost is deferred
-- (John, 2026-08-25 - cost of gain is entered as a rate for now). When it
-- comes back, it joins onto lot_daily_head through the assignments, and
-- the coverage gap above has to be dealt with then.
--
-- Nothing here changes a single existing row, view, function or policy.
--
-- Idempotent: safe to run repeatedly.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Preconditions. Fail loudly rather than half-applying.
-- ---------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regclass('public.lots') IS NULL
       OR to_regclass('public.invoices') IS NULL
       OR to_regclass('public.delivery_receipts') IS NULL
       OR to_regclass('public.lot_events') IS NULL
       OR to_regclass('public.sales') IS NULL
       OR to_regclass('public.lot_status') IS NULL THEN
        RAISE EXCEPTION 'Core tables are missing - wrong database?';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'current_user_role'
    ) THEN
        RAISE EXCEPTION 'current_user_role() is missing - every policy here depends on it.';
    END IF;
END
$pre$;


-- =====================================================================
-- 1. lot_budgets - one frozen plan per lot
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.lot_budgets (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lot_id                  uuid NOT NULL UNIQUE REFERENCES public.lots(id) ON DELETE CASCADE,

    -- Cattle in, as planned
    budget_head             integer,
    budget_avg_weight_in    numeric,
    budget_cost_per_cwt     numeric,

    -- Time and gain, as planned
    target_adg              numeric,
    days_on_feed            integer,
    target_ship_date        date,
    target_ship_weight      numeric,

    -- Sale, as planned
    target_sale_cwt         numeric,

    -- Cost, as planned. Modes mirror the closeout screen: a per-day rate is
    -- multiplied by days on feed, a per-head rate is taken flat.
    cog_mode                text CHECK (cog_mode   IN ('per_day','per_head')),
    cog_value               numeric,
    labor_mode              text CHECK (labor_mode IN ('per_day','per_head')),
    labor_value             numeric,
    med_per_head            numeric,
    death_loss_pct          numeric,   -- decimal, not percent: 6% is 0.06
    interest_pct            numeric,   -- decimal, not percent: 5% is 0.05

    notes                   text,
    frozen_at               timestamptz NOT NULL DEFAULT now(),
    frozen_by               uuid REFERENCES auth.users(id)
);

COMMENT ON TABLE public.lot_budgets IS
    'The plan for a lot, frozen when it starts. Immutable by trigger - an owner deletes and re-creates if it was entered wrong. Working assumptions that change over the life of the lot live on lots.*, not here.';
COMMENT ON COLUMN public.lot_budgets.death_loss_pct IS 'Decimal, not percent. 6% is stored as 0.06.';
COMMENT ON COLUMN public.lot_budgets.interest_pct   IS 'Decimal, not percent. 5% is stored as 0.05.';

-- ---------------------------------------------------------------------
-- Immutability. The trigger is the real guard; see the UPDATE policy note
-- below for why RLS deliberately lets the statement through to reach it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lot_budgets_frozen()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public'
AS $fn$
BEGIN
    RAISE EXCEPTION
        'A lot budget is frozen and cannot be edited. If it was entered wrong, an owner deletes it and enters a new one.'
        USING ERRCODE = 'check_violation';
END
$fn$;

DROP TRIGGER IF EXISTS lot_budgets_no_update ON public.lot_budgets;
CREATE TRIGGER lot_budgets_no_update
    BEFORE UPDATE ON public.lot_budgets
    FOR EACH ROW EXECUTE FUNCTION public.lot_budgets_frozen();

-- ---------------------------------------------------------------------
-- RLS. This table is cost data: office and owner only, never crew.
-- ---------------------------------------------------------------------
ALTER TABLE public.lot_budgets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lot_budgets_select ON public.lot_budgets;
CREATE POLICY lot_budgets_select ON public.lot_budgets
    FOR SELECT USING (current_user_role() = ANY (ARRAY['owner','office']));

DROP POLICY IF EXISTS lot_budgets_insert ON public.lot_budgets;
CREATE POLICY lot_budgets_insert ON public.lot_budgets
    FOR INSERT WITH CHECK (
        current_user_role() = ANY (ARRAY['owner','office'])
        AND frozen_by = auth.uid()
    );

-- Deliberate: office and owner PASS the RLS check on UPDATE so that the
-- trigger above fires and raises a real error. Denying at the policy layer
-- instead would make PostgREST return an empty result set and the app would
-- report a successful save that changed nothing - the silent-refusal trap in
-- docs/OPEN-ITEMS.md item 3. Crew are refused here and never reach the
-- trigger, which is correct: they cannot see this table at all.
DROP POLICY IF EXISTS lot_budgets_update ON public.lot_budgets;
CREATE POLICY lot_budgets_update ON public.lot_budgets
    FOR UPDATE USING (current_user_role() = ANY (ARRAY['owner','office']))
    WITH CHECK (current_user_role() = ANY (ARRAY['owner','office']));

DROP POLICY IF EXISTS lot_budgets_delete ON public.lot_budgets;
CREATE POLICY lot_budgets_delete ON public.lot_budgets
    FOR DELETE USING (current_user_role() = 'owner');

REVOKE ALL ON public.lot_budgets FROM PUBLIC;
REVOKE ALL ON public.lot_budgets FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.lot_budgets TO authenticated;


-- =====================================================================
-- 2. lot_daily_head - the exact head curve
-- =====================================================================
-- One row per lot per day from first arrival through today (or the close
-- date), carrying head on hand at the end of that day.
--
-- head_in follows lot_status exactly: the GREATEST of head invoiced and
-- head received, applied cumulatively day by day. Cattle are commonly on
-- the place several days before the invoice lands, and the receipt is the
-- honest arrival date.
--
-- Event dates are clamped into [first arrival, today]. A death dated before
-- the first receipt or a sale dated next week is a data error either way;
-- clamping keeps the curve reconciled to head_current instead of quietly
-- disagreeing with it.
--
-- security_invoker is mandatory (CLAUDE.md rule 3). Without it the view runs
-- as its owner and bypasses RLS on the base tables entirely.

DROP VIEW IF EXISTS public.lot_head_days;
DROP VIEW IF EXISTS public.lot_daily_head;

CREATE VIEW public.lot_daily_head
WITH (security_invoker = true) AS
WITH bounds AS (
    SELECT
        l.id AS lot_id,
        LEAST(
            COALESCE((SELECT min(r.receipt_date) FROM public.delivery_receipts r WHERE r.lot_id = l.id), DATE '9999-12-31'),
            COALESCE((SELECT min(i.invoice_date) FROM public.invoices        i WHERE i.lot_id = l.id), DATE '9999-12-31')
        ) AS start_date,
        LEAST(COALESCE(l.closed_at::date, CURRENT_DATE), CURRENT_DATE) AS end_date
    FROM public.lots l
),
live AS (
    SELECT * FROM bounds
    WHERE start_date < DATE '9999-12-31' AND end_date >= start_date
),
raw_events AS (
    SELECT i.lot_id, i.invoice_date AS d, i.head_count AS inv_in, 0 AS rcpt_in, 0 AS delta
      FROM public.invoices i
    UNION ALL
    SELECT r.lot_id, r.receipt_date, 0, r.head_count, 0
      FROM public.delivery_receipts r
    UNION ALL
    SELECT e.lot_id, e.event_date, 0, 0,
           CASE e.event_type
               WHEN 'death'        THEN -abs(e.head_count)
               WHEN 'sold'         THEN -abs(e.head_count)
               WHEN 'transfer_out' THEN -abs(e.head_count)
               WHEN 'transfer_in'  THEN  abs(e.head_count)
               WHEN 'adjustment'   THEN  e.head_count
               ELSE 0
           END
      FROM public.lot_events e
    UNION ALL
    SELECT s.lot_id, s.sale_date, 0, 0, -s.head_count
      FROM public.sales s
),
clamped AS (
    SELECT
        v.lot_id,
        LEAST(GREATEST(re.d, v.start_date), v.end_date) AS d,
        sum(re.inv_in)  AS inv_in,
        sum(re.rcpt_in) AS rcpt_in,
        sum(re.delta)   AS delta
    FROM raw_events re
    JOIN live v ON v.lot_id = re.lot_id
    WHERE re.d IS NOT NULL
    GROUP BY v.lot_id, LEAST(GREATEST(re.d, v.start_date), v.end_date)
),
days AS (
    SELECT v.lot_id, gs::date AS as_of_date
    FROM live v
    CROSS JOIN LATERAL generate_series(v.start_date::timestamp, v.end_date::timestamp, INTERVAL '1 day') gs
)
SELECT
    d.lot_id,
    d.as_of_date,
    GREATEST(
        0,
        GREATEST(
            sum(COALESCE(c.inv_in, 0))  OVER w,
            sum(COALESCE(c.rcpt_in, 0)) OVER w
        ) + sum(COALESCE(c.delta, 0))   OVER w
    )::integer AS head_on_hand
FROM days d
LEFT JOIN clamped c ON c.lot_id = d.lot_id AND c.d = d.as_of_date
WINDOW w AS (PARTITION BY d.lot_id ORDER BY d.as_of_date ROWS UNBOUNDED PRECEDING);

COMMENT ON VIEW public.lot_daily_head IS
    'Head on hand per lot per day, from the same events lot_status derives head_current from. Reconciles to lot_status.head_current on the last day by construction.';

REVOKE ALL ON public.lot_daily_head FROM PUBLIC;
REVOKE ALL ON public.lot_daily_head FROM anon;
GRANT SELECT ON public.lot_daily_head TO authenticated;


-- =====================================================================
-- 3. lot_head_days - the monthly rollup
-- =====================================================================
-- Today is excluded: a day is counted once it is complete, the same
-- convention lot_status.days_on_feed uses. A lot that arrived today has
-- zero days on feed and zero head-days, and the two agree.

CREATE VIEW public.lot_head_days
WITH (security_invoker = true) AS
SELECT
    lot_id,
    date_trunc('month', as_of_date)::date AS month_start,
    sum(head_on_hand)::numeric            AS head_days,
    count(*)::integer                     AS days_counted,
    min(as_of_date)                       AS first_day,
    max(as_of_date)                       AS last_day,
    round(avg(head_on_hand), 1)           AS avg_head_on_hand
FROM public.lot_daily_head
WHERE as_of_date < CURRENT_DATE
GROUP BY lot_id, date_trunc('month', as_of_date)::date;

COMMENT ON VIEW public.lot_head_days IS
    'Head-days by lot and month - the quantity any per-head-per-day cost is charged against. Excludes today; a day counts once complete, matching lot_status.days_on_feed.';

REVOKE ALL ON public.lot_head_days FROM PUBLIC;
REVOKE ALL ON public.lot_head_days FROM anon;
GRANT SELECT ON public.lot_head_days TO authenticated;


-- =====================================================================
-- Verify. CLAUDE.md rule 7 says to run the RLS verify script after any
-- migration that adds a table, view or function. That script is referenced
-- in the docs but does not exist in the repo, so the assertions it would
-- make are made here instead, scoped to what this migration added - plus
-- the one that actually matters for cost: the head curve must agree with
-- the books.
-- =====================================================================
DO $post$
DECLARE
    v_opts     text[];
    v_bad      text;
    v_n        integer;
BEGIN
    -- Rule 5: RLS enabled AND policies present.
    IF NOT EXISTS (
        SELECT 1 FROM pg_class WHERE oid = 'public.lot_budgets'::regclass AND relrowsecurity
    ) THEN
        RAISE EXCEPTION 'lot_budgets: row level security is not enabled.';
    END IF;

    SELECT count(*) INTO v_n FROM pg_policies
     WHERE schemaname='public' AND tablename='lot_budgets';
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'lot_budgets: expected 4 policies, found %.', v_n;
    END IF;

    -- Rule 3: both views must be security_invoker.
    SELECT reloptions INTO v_opts FROM pg_class WHERE oid = 'public.lot_daily_head'::regclass;
    IF v_opts IS NULL OR NOT ('security_invoker=true' = ANY (v_opts)) THEN
        RAISE EXCEPTION 'lot_daily_head was not created WITH (security_invoker = true) - it would bypass RLS.';
    END IF;

    SELECT reloptions INTO v_opts FROM pg_class WHERE oid = 'public.lot_head_days'::regclass;
    IF v_opts IS NULL OR NOT ('security_invoker=true' = ANY (v_opts)) THEN
        RAISE EXCEPTION 'lot_head_days was not created WITH (security_invoker = true) - it would bypass RLS.';
    END IF;

    -- Rule 4: nothing readable by anon. information_schema lies about grants
    -- on hosted Supabase; has_table_privilege does not.
    IF has_table_privilege('anon', 'public.lot_budgets',    'SELECT')
    OR has_table_privilege('anon', 'public.lot_daily_head', 'SELECT')
    OR has_table_privilege('anon', 'public.lot_head_days',  'SELECT') THEN
        RAISE EXCEPTION 'anon can read one of the new objects - the publishable key is public, so this would be too.';
    END IF;

    -- The freeze actually freezes.
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'public.lot_budgets'::regclass
          AND tgname  = 'lot_budgets_no_update' AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION 'lot_budgets: the immutability trigger is missing.';
    END IF;

    -- The head curve must land on head_current for every open lot. If it
    -- does not, every cost figure built on head-days is wrong, so this is
    -- worth failing the whole migration over.
    SELECT string_agg(format('%s (curve %s, books %s)', x.lot_number, x.curve_head, x.book_head), '; ')
      INTO v_bad
    FROM (
        SELECT l.lot_number, dh.head_on_hand AS curve_head, ls.head_current AS book_head
        FROM public.lots l
        JOIN public.lot_status ls ON ls.lot_id = l.id
        JOIN LATERAL (
            SELECT head_on_hand FROM public.lot_daily_head
            WHERE lot_id = l.id ORDER BY as_of_date DESC LIMIT 1
        ) dh ON TRUE
        WHERE l.closed_at IS NULL
          AND COALESCE(l.is_test, false) = false
          AND dh.head_on_hand <> ls.head_current
    ) x;

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Head curve disagrees with the books on: %', v_bad;
    END IF;

    RAISE NOTICE 'lot_budgets, lot_daily_head and lot_head_days created. RLS on, anon locked out, budget frozen, head curve reconciled to the books.';
END
$post$;

COMMIT;

-- =====================================================================
-- Sanity check after applying - head-days this month by lot, next to the
-- naive figure the old math would have used. Where they differ, the lot
-- lost or shipped cattle during the month and the naive number is wrong.
--
--   SELECT l.lot_number,
--          hd.head_days                                        AS head_days,
--          hd.avg_head_on_hand,
--          ls.head_current * (CURRENT_DATE - hd.month_start)    AS naive
--   FROM lot_head_days hd
--   JOIN lots l       ON l.id = hd.lot_id
--   JOIN lot_status ls ON ls.lot_id = hd.lot_id
--   WHERE hd.month_start = date_trunc('month', CURRENT_DATE)::date
--   ORDER BY l.lot_number;
-- =====================================================================
