-- =====================================================================
-- Rename lot_head_days (view) -> lot_head_days_by_month
-- =====================================================================
-- 2026-08-25, immediately after 2026-08-25_budget_and_head_days.sql.
--
-- That migration created a VIEW called lot_head_days without noticing that
-- a FUNCTION lot_head_days(uuid, date) already existed and that the app
-- calls it via supabase.rpc() for the "Hd-days" tile on lot detail.
--
-- Postgres keeps functions and views in separate catalogs so nothing broke
-- - PostgREST serves the view at /lot_head_days and the function at
-- /rpc/lot_head_days - but two different implementations of head-days
-- under one name is a trap for whoever reads this next. The view gets the
-- longer name because the function is the incumbent.
--
-- WHICH ONE IS RIGHT, since they disagree
--
-- The function anchors on lot_weighted_arrival_date(), which is derived
-- from INVOICE dates. The view anchors on the earlier of first receipt and
-- first invoice, and walks arrivals receipt by receipt. On lots where
-- invoices follow receipts closely the two agree within about 1%. On 36-27
-- they do not: weighted arrival is 2026-08-19, the first receipt is
-- 2026-08-11, and the function returns 2,646 head-days against the view's
-- 3,424 - 29% low.
--
-- For cost the view is right. Cattle eat grass and take labor from the day
-- they hit the ground, not from the day the invoice is dated. The function
-- is left alone here: it is correct for what it was built for, and
-- changing a number that shows on lot detail is a separate, visible
-- decision rather than a side effect of a rename.
--
-- Idempotent: safe to run repeatedly.
-- =====================================================================

DO $pre$
BEGIN
    IF to_regclass('public.lot_head_days_by_month') IS NOT NULL THEN
        RAISE NOTICE 'lot_head_days_by_month already exists. Nothing to do.';
        RETURN;
    END IF;

    IF to_regclass('public.lot_head_days') IS NULL THEN
        RAISE EXCEPTION 'Neither lot_head_days nor lot_head_days_by_month exists - apply 2026-08-25_budget_and_head_days.sql first.';
    END IF;

    -- to_regclass resolves views, sequences and tables alike. Confirm this
    -- is the view before renaming it, or a future table of the same name
    -- would be renamed instead.
    IF (SELECT relkind FROM pg_class WHERE oid = to_regclass('public.lot_head_days')) <> 'v' THEN
        RAISE EXCEPTION 'public.lot_head_days is not a view - refusing to rename it.';
    END IF;

    ALTER VIEW public.lot_head_days RENAME TO lot_head_days_by_month;
    RAISE NOTICE 'Renamed view lot_head_days -> lot_head_days_by_month.';
END
$pre$;

COMMENT ON VIEW public.lot_head_days_by_month IS
    'Head-days by lot and month - the quantity any per-head-per-day cost is charged against. Derived from lot_daily_head, which walks arrivals by RECEIPT date. Distinct from the older lot_head_days(uuid,date) FUNCTION, which anchors on the invoice-weighted arrival and reads low on lots whose cattle arrive before their invoices. Excludes today; a day counts once complete.';

DO $post$
DECLARE
    v_opts text[];
BEGIN
    SELECT reloptions INTO v_opts FROM pg_class WHERE oid = 'public.lot_head_days_by_month'::regclass;
    IF v_opts IS NULL OR NOT ('security_invoker=true' = ANY (v_opts)) THEN
        RAISE EXCEPTION 'lot_head_days_by_month lost security_invoker in the rename - it would bypass RLS.';
    END IF;

    IF has_table_privilege('anon', 'public.lot_head_days_by_month', 'SELECT') THEN
        RAISE EXCEPTION 'anon can read lot_head_days_by_month.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname='public' AND p.proname='lot_head_days'
    ) THEN
        RAISE EXCEPTION 'The lot_head_days FUNCTION is gone - the app calls it via rpc for the Hd-days tile.';
    END IF;

    RAISE NOTICE 'Rename complete. View is lot_head_days_by_month; the lot_head_days function is untouched.';
END
$post$;
