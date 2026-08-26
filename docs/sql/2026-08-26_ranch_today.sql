-- =====================================================================
-- Head-days must roll over at midnight in Texas, not midnight UTC
-- =====================================================================
-- 2026-08-26 (filed under the server's date; it was the evening of the
-- 25th in Kosse when this was found).
--
-- The database runs on UTC. CURRENT_DATE therefore becomes tomorrow at
-- 7:00pm Central during CDT, 6:00pm during CST. lot_daily_head and
-- lot_head_days_by_month both used CURRENT_DATE, so every evening they
-- began counting a day that had not happened yet: 36-27 picked up 441
-- head-days at 7:12pm, $882 of cost of gain at its $2.00/head/day, for a
-- Wednesday that was still Tuesday on the ranch.
--
-- Worse than the dollars, it disagreed with the app. The closeout labels
-- its Actual column with the browser's local date, so the header read
-- "to 2026-08-25" above head-days that ran through the 26th.
--
-- Same trap the field app already documents for toISOString(). The ranch
-- is in one place; date boundaries should be that place's.
--
-- ranch_today() is INVOKER and pinned, per CLAUDE.md rule 6 - it reads
-- nothing and needs no elevation.
--
-- Idempotent: safe to run repeatedly.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.ranch_today()
RETURNS date
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'pg_catalog'
AS $fn$
    SELECT (now() AT TIME ZONE 'America/Chicago')::date;
$fn$;

COMMENT ON FUNCTION public.ranch_today() IS
    'Today in Kosse, Texas. The server runs UTC, so CURRENT_DATE rolls over at 7pm Central and counts a day the ranch has not had. Use this for anything that counts days.';

REVOKE ALL ON FUNCTION public.ranch_today() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ranch_today() FROM anon;
GRANT EXECUTE ON FUNCTION public.ranch_today() TO authenticated;

DO $pre$
BEGIN
    IF to_regclass('public.lot_daily_head') IS NULL
       OR to_regclass('public.lot_head_days_by_month') IS NULL THEN
        RAISE EXCEPTION 'Apply the budget/head-days migration and the rename first.';
    END IF;
END
$pre$;

-- lot_head_days_by_month depends on lot_daily_head, so it goes first.
DROP VIEW IF EXISTS public.lot_head_days_by_month;
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
        LEAST(COALESCE(l.closed_at::date, public.ranch_today()), public.ranch_today()) AS end_date
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
    'Head on hand per lot per day, from the same events lot_status derives head_current from. Reconciles to lot_status.head_current on the last day by construction. Days end at midnight in Texas (ranch_today()), not UTC.';

REVOKE ALL ON public.lot_daily_head FROM PUBLIC;
REVOKE ALL ON public.lot_daily_head FROM anon;
GRANT SELECT ON public.lot_daily_head TO authenticated;

CREATE VIEW public.lot_head_days_by_month
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
WHERE as_of_date < public.ranch_today()
GROUP BY lot_id, date_trunc('month', as_of_date)::date;

COMMENT ON VIEW public.lot_head_days_by_month IS
    'Head-days by lot and month - the quantity any per-head-per-day cost is charged against. Derived from lot_daily_head, which walks arrivals by RECEIPT date. Distinct from the older lot_head_days(uuid,date) FUNCTION, which anchors on the invoice-weighted arrival and reads low on lots whose cattle arrive before their invoices. Excludes today in Texas; a day counts once complete.';

REVOKE ALL ON public.lot_head_days_by_month FROM PUBLIC;
REVOKE ALL ON public.lot_head_days_by_month FROM anon;
GRANT SELECT ON public.lot_head_days_by_month TO authenticated;

DO $post$
DECLARE
    v_opts text[];
    v_bad  text;
BEGIN
    FOREACH v_bad IN ARRAY ARRAY['lot_daily_head','lot_head_days_by_month'] LOOP
        SELECT reloptions INTO v_opts FROM pg_class
         WHERE oid = ('public.'||v_bad)::regclass;
        IF v_opts IS NULL OR NOT ('security_invoker=true' = ANY (v_opts)) THEN
            RAISE EXCEPTION '% lost security_invoker - it would bypass RLS.', v_bad;
        END IF;
        IF has_table_privilege('anon', 'public.'||v_bad, 'SELECT') THEN
            RAISE EXCEPTION 'anon can read %.', v_bad;
        END IF;
    END LOOP;

    IF has_function_privilege('anon', 'public.ranch_today()', 'EXECUTE') THEN
        RAISE EXCEPTION 'anon can execute ranch_today().';
    END IF;

    -- The curve must still land on the books.
    SELECT string_agg(format('%s (curve %s, books %s)', x.lot_number, x.c, x.b), '; ')
      INTO v_bad
    FROM (
        SELECT l.lot_number, dh.head_on_hand AS c, ls.head_current AS b
        FROM public.lots l
        JOIN public.lot_status ls ON ls.lot_id = l.id
        JOIN LATERAL (SELECT head_on_hand FROM public.lot_daily_head
                      WHERE lot_id = l.id ORDER BY as_of_date DESC LIMIT 1) dh ON TRUE
        WHERE l.closed_at IS NULL AND COALESCE(l.is_test,false) = false
          AND dh.head_on_hand <> ls.head_current
    ) x;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Head curve disagrees with the books on: %', v_bad;
    END IF;

    RAISE NOTICE 'Head-days now roll over at midnight in Texas. Curve still reconciles to the books.';
END
$post$;
