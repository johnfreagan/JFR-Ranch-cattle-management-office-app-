-- =====================================================================
-- Sales revamp, phase 3
--   1. a load is weighed ONCE and split across lot/pasture lines by head
--   2. loads carry their own date, so a sheet can span several days
-- =====================================================================
-- 2026-08-26.
--
-- 1. ONE SCALE TICKET PER TRUCK
--
-- Phase 2 put lot_id and pasture_id straight on the load, which quietly
-- assumed a load only ever came off one pasture - and when it did not, it
-- asked for a gross weight per pasture. Nobody weighs a pot twice. A truck
-- crosses the scale once and you get one number for whatever is on it.
--
-- So the load and its contents separate:
--
--   shipment_loads       date, head, ONE gross weight        (off the sheet)
--     shipment_load_lines  lot, pasture, head                (what we know)
--
-- and the load's gross is allocated across its lines BY HEAD. The chain runs
-- load gross -> line gross (by head) -> line pay weight (by gross, inside the
-- weight group) -> dollars (by pay weight). Every step is largest-remainder,
-- so a line's share is exact at every level and the sheet still ties.
--
-- head_count stays ON the load because the buyer's sheet states it there.
-- The lines must sum to it, which is a real check: it catches a pot split
-- 30/30 when the sheet said 62.
--
-- 2. MULTI-DAY SHEETS
--
-- One settlement sheet routinely covers loads that left on different days -
-- the 8-21 Thigpen sheet is 9 loads and did not happen in an afternoon.
-- Every load therefore carries load_date, and `shipments.sale_date` goes back
-- to meaning what it says: the date on the paperwork.
--
-- This is not cosmetic. Cattle that left on the 19th ate grass on the 19th
-- and not the 21st, and head-days are what cost of gain and labor are charged
-- against. Posting nine loads on one date would hand the ranch up to two
-- extra days of head-days on cattle that were already gone. The app therefore
-- writes one `sales` row per (lot, load_date) rather than per lot, and closes
-- each pasture out on the date its cattle actually left.
--
-- Nothing had been entered when this ran (0 shipments, 0 loads, 0 sales), so
-- the phase-2 columns are dropped rather than migrated.
--
-- Idempotent: safe to run repeatedly.
-- Run supabase/migrations/20260821000300_rls_verify.sql afterwards.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Preconditions
-- ---------------------------------------------------------------------
DO $pre$
DECLARE
    v_loads bigint;
BEGIN
    IF to_regclass('public.shipment_loads') IS NULL THEN
        RAISE EXCEPTION 'Phase 2 has not been applied. Refusing to proceed.';
    END IF;

    -- The phase-2 shape is being dropped, not converted. Refuse if anyone has
    -- entered a shipment in the meantime rather than silently binning it.
    SELECT count(*) INTO v_loads FROM public.shipment_loads;
    IF v_loads > 0 AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='shipment_loads' AND column_name='lot_id'
    ) THEN
        RAISE EXCEPTION
            'shipment_loads already holds % row(s) in the phase-2 shape. This migration drops lot_id/pasture_id and would lose them. Move the data first.',
            v_loads;
    END IF;
END
$pre$;

-- ---------------------------------------------------------------------
-- 1. The load: one date, one head count, one weighing
-- ---------------------------------------------------------------------
ALTER TABLE public.shipment_loads
    ADD COLUMN IF NOT EXISTS load_date date;

-- Lot and pasture move down to the lines; a load has no single one of either.
ALTER TABLE public.shipment_loads DROP COLUMN IF EXISTS lot_id;
ALTER TABLE public.shipment_loads DROP COLUMN IF EXISTS pasture_id;
ALTER TABLE public.shipment_loads DROP COLUMN IF EXISTS line_seq;

-- With lines in their own table, a load number is unique again.
ALTER TABLE public.shipment_loads DROP CONSTRAINT IF EXISTS shipment_loads_seq_line_uq;

DO $uq$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'shipment_loads_seq_uq'
          AND conrelid = to_regclass('public.shipment_loads')
    ) THEN
        ALTER TABLE public.shipment_loads
            ADD CONSTRAINT shipment_loads_seq_uq UNIQUE (shipment_id, load_seq);
    END IF;
END
$uq$;

CREATE INDEX IF NOT EXISTS shipment_loads_date_idx ON public.shipment_loads (load_date);

COMMENT ON COLUMN public.shipment_loads.load_date IS
    'The day this truck actually left. One sheet can span several; head math and head-days follow this, not shipments.sale_date.';
COMMENT ON COLUMN public.shipment_loads.gross_weight_lb IS
    'ONE scale ticket for the whole pot. Allocated across the load''s lines by head.';
COMMENT ON COLUMN public.shipment_loads.head_count IS
    'Head on this truck, as stated on the buyer sheet. The load''s lines must sum to it.';

-- ---------------------------------------------------------------------
-- 2. The lines: what was on the truck and where it came from
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.shipment_load_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    load_id             uuid        NOT NULL REFERENCES public.shipment_loads(id) ON DELETE CASCADE,
    line_seq            integer     NOT NULL DEFAULT 1,

    lot_id              uuid        NOT NULL REFERENCES public.lots(id)     ON DELETE RESTRICT,
    pasture_id          uuid        NOT NULL REFERENCES public.pastures(id) ON DELETE RESTRICT,
    head_count          integer     NOT NULL CHECK (head_count > 0),

    -- The allocated shares, written down so the arithmetic is auditable after
    -- the fact rather than re-derived from a formula that may have changed.
    gross_weight_lb     numeric     CHECK (gross_weight_lb >= 0),
    pay_weight_lb       numeric     CHECK (pay_weight_lb >= 0),

    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT shipment_load_lines_seq_uq UNIQUE (load_id, line_seq)
);

CREATE INDEX IF NOT EXISTS shipment_load_lines_load_idx    ON public.shipment_load_lines (load_id);
CREATE INDEX IF NOT EXISTS shipment_load_lines_lot_idx     ON public.shipment_load_lines (lot_id);
CREATE INDEX IF NOT EXISTS shipment_load_lines_pasture_idx ON public.shipment_load_lines (pasture_id);

COMMENT ON TABLE public.shipment_load_lines IS
    'What was on one truck and where it came from. The load is weighed once; these split that weight by head.';
COMMENT ON COLUMN public.shipment_load_lines.gross_weight_lb IS
    'This line''s share of the load''s single scale ticket, allocated by head. Sums exactly to the load.';

-- ---------------------------------------------------------------------
-- 3. RLS
-- ---------------------------------------------------------------------
ALTER TABLE public.shipment_load_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS shipment_load_lines_select ON public.shipment_load_lines;
DROP POLICY IF EXISTS shipment_load_lines_insert ON public.shipment_load_lines;
DROP POLICY IF EXISTS shipment_load_lines_update ON public.shipment_load_lines;
DROP POLICY IF EXISTS shipment_load_lines_delete ON public.shipment_load_lines;

CREATE POLICY shipment_load_lines_select ON public.shipment_load_lines
    FOR SELECT TO authenticated
    USING (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipment_load_lines_insert ON public.shipment_load_lines
    FOR INSERT TO authenticated
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipment_load_lines_update ON public.shipment_load_lines
    FOR UPDATE TO authenticated
    USING (public.current_user_role() = ANY (ARRAY['owner','office']))
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipment_load_lines_delete ON public.shipment_load_lines
    FOR DELETE TO authenticated
    USING (public.current_user_role() = 'owner');

REVOKE ALL ON public.shipment_load_lines FROM PUBLIC;
REVOKE ALL ON public.shipment_load_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shipment_load_lines TO authenticated;

-- ---------------------------------------------------------------------
-- 4. Reconciliation gains a load-level check
-- ---------------------------------------------------------------------
-- Two things can now drift apart that could not before: a load's lines can
-- stop summing to the load's own head, and the loads can stop summing to the
-- sheet. Both are silent - the money still allocates, just against the wrong
-- split - so they get their own view rather than living only in the
-- browser's save-time validation.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.shipment_load_reconciliation
WITH (security_invoker = true) AS
SELECT
    l.shipment_id,
    l.id                                    AS load_id,
    l.load_seq,
    l.load_date,
    l.head_count                            AS load_head,
    l.gross_weight_lb                       AS load_gross_lb,
    COALESCE(ln.head_count, 0)              AS lines_head,
    COALESCE(ln.gross_weight_lb, 0)         AS lines_gross_lb,
    l.head_count - COALESCE(ln.head_count, 0)                       AS head_variance,
    l.gross_weight_lb - COALESCE(ln.gross_weight_lb, 0)             AS gross_variance,
    COALESCE(ln.line_count, 0)              AS line_count
FROM public.shipment_loads l
LEFT JOIN (
    SELECT load_id,
           SUM(head_count)      AS head_count,
           SUM(gross_weight_lb) AS gross_weight_lb,
           COUNT(*)             AS line_count
    FROM public.shipment_load_lines
    GROUP BY load_id
) ln ON ln.load_id = l.id;

COMMENT ON VIEW public.shipment_load_reconciliation IS
    'Per load: does the sum of its lot/pasture lines still match the head and weight on the scale ticket?';

REVOKE ALL ON public.shipment_load_reconciliation FROM PUBLIC;
REVOKE ALL ON public.shipment_load_reconciliation FROM anon;
GRANT SELECT ON public.shipment_load_reconciliation TO authenticated;

-- ---------------------------------------------------------------------
-- 5. Verify
-- ---------------------------------------------------------------------
DO $verify$
DECLARE
    v_pol integer;
BEGIN
    IF to_regclass('public.shipment_load_lines') IS NULL THEN
        RAISE EXCEPTION 'shipment_load_lines was not created.';
    END IF;

    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.shipment_load_lines')) THEN
        RAISE EXCEPTION 'RLS is not enabled on shipment_load_lines.';
    END IF;

    SELECT count(*) INTO v_pol FROM pg_policies
     WHERE schemaname='public' AND tablename='shipment_load_lines';
    IF v_pol <> 4 THEN
        RAISE EXCEPTION 'shipment_load_lines has % policies, expected 4.', v_pol;
    END IF;

    IF has_table_privilege('anon','public.shipment_load_lines','SELECT') THEN
        RAISE EXCEPTION 'anon can SELECT shipment_load_lines.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='shipment_loads' AND column_name='load_date'
    ) THEN
        RAISE EXCEPTION 'shipment_loads.load_date was not added.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='shipment_loads'
          AND column_name IN ('lot_id','pasture_id','line_seq')
    ) THEN
        RAISE EXCEPTION 'The phase-2 lot/pasture columns are still on shipment_loads.';
    END IF;

    IF to_regclass('public.shipment_load_reconciliation') IS NULL THEN
        RAISE EXCEPTION 'shipment_load_reconciliation was not created.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_class c
        WHERE c.oid = to_regclass('public.shipment_load_reconciliation')
          AND c.reloptions @> ARRAY['security_invoker=true']
    ) THEN
        RAISE EXCEPTION 'shipment_load_reconciliation lacks security_invoker - it would bypass RLS.';
    END IF;

    IF has_table_privilege('anon','public.shipment_load_reconciliation','SELECT') THEN
        RAISE EXCEPTION 'anon can SELECT shipment_load_reconciliation.';
    END IF;

    RAISE NOTICE 'Phase 3 applied: one scale ticket per load, lines split it by head, loads carry their own date.';
END
$verify$;
