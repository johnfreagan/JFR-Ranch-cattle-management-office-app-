-- =====================================================================
-- A checkout records the size of bottle that left the room
-- =====================================================================
-- 2026-10-01. John, on being asked which bottle size Excede's catalog
-- entry should carry: "some cowboys like 100 ml and some like 250 ml.
-- We use a checkout sheet in med room for what they get that should
-- state size."
--
-- That sentence is the bug report. The Checkouts screen converted
-- bottles to units off the medication's ONE catalog size, with no way to
-- say otherwise:
--
--     const size = Number(med && med.bottle_size) || 0;   // catalog
--     qty_units: bottles * size
--
-- So the paper sheet says "2 x 100 mL Excede", somebody types 2 bottles,
-- and the app records 500 mL instead of 200. Two and a half times wrong.
-- med_checkout_log then divided back by the same catalog size, so the
-- Bottles column could not recover it either.
--
-- HOW BAD: bounded, and worth saying so. A checkout carries direction 0
-- - custody only. It moves no stock, prices nothing, and reaches no
-- lot. What it got wrong is WHO HAS WHAT, which is the single thing that
-- screen exists to answer.
--
-- PURCHASES AND COUNTS ALREADY DO THIS RIGHT. med_purchase_lines and
-- med_count_lines each snapshot their own bottle_size, exactly so a
-- later catalog change cannot rewrite what was received or counted.
-- Checkouts were the one place that read the catalog live. This makes
-- the three consistent.
--
-- Zero checkouts exist, so there is nothing to backfill and no way for
-- this to disturb a figure anybody has seen. NULL keeps meaning "use
-- the catalog", which is what every checkout entered before today would
-- have meant anyway.
--
-- This does NOT settle which size the Excede catalog entry should hold -
-- docs/OPEN-ITEMS.md item 0f. It makes that question stop mattering at
-- the point where it was doing damage: the catalog is now only a default
-- in a box somebody can change.
-- =====================================================================

begin;

-- 1. The snapshot. NULL = the catalog's size, which is what the screen
--    will send whenever nobody overrides the box.
ALTER TABLE public.med_txns
    ADD COLUMN IF NOT EXISTS bottle_size numeric(12,4);

COMMENT ON COLUMN public.med_txns.bottle_size IS
    'The size of container the bottles were counted in, snapshotted. NULL means use the medication''s catalog size. Set on a checkout so "2 bottles" off the med-room sheet means the size that actually left the room, not whichever one the catalog happens to hold.';

DO $guard$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM public.med_txns
     WHERE bottle_size IS NOT NULL AND bottle_size <= 0;
    IF n > 0 THEN
        RAISE EXCEPTION '% txns carry a bottle_size of zero or less', n;
    END IF;
END
$guard$;

ALTER TABLE public.med_txns
    DROP CONSTRAINT IF EXISTS med_txns_bottle_size_ck;
ALTER TABLE public.med_txns
    ADD CONSTRAINT med_txns_bottle_size_ck
    CHECK (bottle_size IS NULL OR bottle_size > 0);

-- 2. The log divides by what was recorded, falling back to the catalog.
--    security_invoker is repeated because CREATE OR REPLACE clears
--    reloptions - CLAUDE.md rule.
CREATE OR REPLACE VIEW public.med_checkout_log
WITH (security_invoker = true) AS
SELECT
    t.id, t.txn_date,
    cm.name AS crew_member, t.crew_member_id,
    m.name  AS medication_name, m.generic_category, t.medication_id,
    CASE WHEN COALESCE(t.bottle_size, m.bottle_size, 0) > 0
         THEN round(t.qty_units / COALESCE(t.bottle_size, m.bottle_size), 2)
    END AS bottles,
    t.qty_units,
    COALESCE(m.bottle_size_unit, 'mL') AS unit,
    CASE WHEN t.qty_units < 0 THEN 'return' ELSE 'out' END AS direction_label,
    t.notes, t.created_at,
    -- What the bottles were counted in, so the log can say "2 x 100 mL"
    -- rather than making a reader assume. APPENDED LAST on purpose:
    -- CREATE OR REPLACE VIEW cannot insert a column in the middle - it
    -- reads that as renaming qty_units - and dropping the view to
    -- reorder would drop its grants with it.
    COALESCE(t.bottle_size, m.bottle_size) AS bottle_size
FROM public.med_txns t
JOIN public.medications m            ON m.id  = t.medication_id
LEFT JOIN public.med_crew_members cm ON cm.id = t.crew_member_id
WHERE t.txn_type = 'checkout';

DO $verify$
DECLARE
    n integer;
    v text;
BEGIN
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='med_txns' AND column_name='bottle_size';
    IF n <> 1 THEN RAISE EXCEPTION 'med_txns.bottle_size did not get added'; END IF;

    SELECT count(*) INTO n FROM pg_constraint
     WHERE conrelid = 'public.med_txns'::regclass AND conname = 'med_txns_bottle_size_ck';
    IF n <> 1 THEN RAISE EXCEPTION 'the bottle_size check constraint is missing'; END IF;

    -- the view must still be security_invoker after the replace
    SELECT array_to_string(c.reloptions, ',') INTO v
      FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'public' AND c.relname = 'med_checkout_log';
    IF v IS NULL OR v NOT LIKE '%security_invoker=true%' THEN
        RAISE EXCEPTION 'med_checkout_log lost security_invoker (reloptions: %)', coalesce(v,'none');
    END IF;

    -- and it must not have picked up anon along the way
    SELECT count(*) INTO n FROM information_schema.role_table_grants
     WHERE table_schema='public' AND table_name='med_checkout_log' AND grantee='anon';
    IF n <> 0 THEN RAISE EXCEPTION 'med_checkout_log is granted to anon'; END IF;

    SELECT count(*) INTO n FROM public.med_txns;
    IF n <> 0 THEN RAISE EXCEPTION 'the ledger is no longer empty (% txns) - re-check this before trusting the no-backfill claim', n; END IF;

    RAISE NOTICE 'VERIFIED: med_txns.bottle_size added, checked, med_checkout_log divides by it and is still security_invoker, not granted to anon.';
END
$verify$;

commit;
