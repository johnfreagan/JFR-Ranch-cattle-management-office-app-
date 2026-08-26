-- =====================================================================
-- Sales revamp, phase 2
--   1. a truckload names the lot and pasture it was gathered off
--   2. delete_shipment_with_reversal - unwind a shipment AND put the
--      cattle back
--   3. crew can no longer see sale dollars
-- =====================================================================
-- 2026-08-26. John's markup on the entry form, same day.
--
-- 1. LOADS CARRY LOT AND PASTURE
--
-- The first cut had two separate sections: an abstract list of truckloads,
-- and a grid of every open lot/pasture where you typed head against the ones
-- that shipped. That is two places describing one event. Loading a truck IS
-- saying where the cattle came from.
--
-- With lot_id and pasture_id on the load, the allocation stops being an
-- estimate. That load's own gross weight belongs to that lot, so weight is
-- distributed by actual load weight rather than pro-rata by head, and the
-- "did every group's head tie to the lots?" validation disappears - the
-- loads ARE the groups, so it ties by construction.
--
-- load_seq stops being unique on its own. A pot gathered off two pastures is
-- one load number and two lines, so the key becomes (shipment, load, line).
--
-- 2. THE REVERSAL
--
-- Deleting a shipment used to leave the cattle shipped - the same wart
-- single-sale delete still has. This puts them back.
--
-- The subtle part, and the reason this is an RPC and not four statements in
-- the browser: a sale either DECREMENTED an assignment or CLOSED it, and the
-- two reverse differently. A decrement reverses by adding head back. A close
-- reverses by clearing moved_out and touching nothing else, because closing
-- leaves head_count intact - this is the exact double-count that bit
-- delete_death_event (3 head, death of all 3, reversal, lot came back with
-- 6). Sources are aggregated per (lot, pasture) first, or a pasture that
-- appears in two weight groups reopens on the first row and then gets head
-- added on the second.
--
-- INVOKER, like every other head-math RPC. The owner check is explicit
-- rather than inherited so the error says something useful instead of
-- deleting zero rows and reporting success.
--
-- 3. CREW AND DOLLARS
--
-- `sales` and `sale_sources` allowed crew on SELECT, so any cowboy could
-- read price_per_cwt, total_price and now the allocated proceeds. Narrowed
-- to office+owner.
--
-- Deliberately NOT done here (John, 2026-08-26 - "sales tables only"):
-- crew can still read medications.cost_per_unit / cost_per_head /
-- bottle_cost and doctoring_event_meds.cost. Those cannot be closed with a
-- policy - all three roles share the `authenticated` DB role, so column
-- grants cannot tell them apart, and revoking `medications` outright breaks
-- doctoring entry in the field app. Closing them needs dollar-free views for
-- crew to read instead, and its own field-app test pass.
--
-- Idempotent: safe to run repeatedly.
-- Run supabase/migrations/20260821000300_rls_verify.sql afterwards.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Preconditions
-- ---------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regclass('public.shipments') IS NULL
       OR to_regclass('public.shipment_loads') IS NULL
       OR to_regclass('public.sale_sources') IS NULL
       OR to_regclass('public.lot_pasture_assignments') IS NULL THEN
        RAISE EXCEPTION 'Phase 1 (2026-08-26_shipments.sql) has not been applied. Refusing to proceed.';
    END IF;
END
$pre$;

-- ---------------------------------------------------------------------
-- 1. shipment_loads gains lot, pasture and a line sequence
-- ---------------------------------------------------------------------
ALTER TABLE public.shipment_loads
    ADD COLUMN IF NOT EXISTS lot_id uuid REFERENCES public.lots(id) ON DELETE RESTRICT;
ALTER TABLE public.shipment_loads
    ADD COLUMN IF NOT EXISTS pasture_id uuid REFERENCES public.pastures(id) ON DELETE RESTRICT;
ALTER TABLE public.shipment_loads
    ADD COLUMN IF NOT EXISTS line_seq integer NOT NULL DEFAULT 1;

-- One load number, several lines when a pot was gathered off more than one
-- pasture. The old constraint allowed only one line per load.
ALTER TABLE public.shipment_loads
    DROP CONSTRAINT IF EXISTS shipment_loads_seq_uq;

DO $uq$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'shipment_loads_seq_line_uq'
          AND conrelid = to_regclass('public.shipment_loads')
    ) THEN
        ALTER TABLE public.shipment_loads
            ADD CONSTRAINT shipment_loads_seq_line_uq
            UNIQUE (shipment_id, load_seq, line_seq);
    END IF;
END
$uq$;

CREATE INDEX IF NOT EXISTS shipment_loads_lot_idx     ON public.shipment_loads (lot_id);
CREATE INDEX IF NOT EXISTS shipment_loads_pasture_idx ON public.shipment_loads (pasture_id);

COMMENT ON COLUMN public.shipment_loads.lot_id IS
    'The lot this load was gathered off. Nullable only for rows written before 2026-08-26.';
COMMENT ON COLUMN public.shipment_loads.line_seq IS
    'Distinguishes lines within one load number, for a pot gathered off more than one pasture.';

-- ---------------------------------------------------------------------
-- 2. delete_shipment_with_reversal
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_shipment_with_reversal(p_shipment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_role          text;
    v_sale          record;
    v_src           record;
    v_asg           record;
    v_lots          uuid[] := '{}';
    v_reopened      integer := 0;
    v_incremented   integer := 0;
    v_sales         integer := 0;
    v_lots_reopened integer := 0;
BEGIN
    v_role := public.current_user_role();
    IF v_role IS DISTINCT FROM 'owner' THEN
        RAISE EXCEPTION 'Only an owner can delete a shipment (current role: %).',
            COALESCE(v_role, 'none');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.shipments WHERE id = p_shipment_id) THEN
        RAISE EXCEPTION 'Shipment % not found.', p_shipment_id;
    END IF;

    FOR v_sale IN
        SELECT id, lot_id, sale_date FROM public.sales WHERE shipment_id = p_shipment_id
    LOOP
        v_sales := v_sales + 1;
        IF NOT (v_sale.lot_id = ANY (v_lots)) THEN
            v_lots := v_lots || v_sale.lot_id;
        END IF;

        -- Aggregated per pasture. A pasture appearing in two weight groups is
        -- two sale_sources rows against ONE assignment; handling them
        -- separately would reopen on the first and add head on the second.
        FOR v_src IN
            SELECT pasture_id, SUM(head_count)::integer AS head_count
            FROM public.sale_sources
            WHERE sale_id = v_sale.id
            GROUP BY pasture_id
        LOOP
            -- Case 1: the sale only decremented an assignment that is still
            -- open. Reverse by adding the head back.
            SELECT * INTO v_asg
            FROM public.lot_pasture_assignments
            WHERE lot_id = v_sale.lot_id
              AND pasture_id = v_src.pasture_id
              AND moved_out IS NULL
            ORDER BY moved_in DESC
            LIMIT 1;

            IF FOUND THEN
                UPDATE public.lot_pasture_assignments
                   SET head_count = head_count + v_src.head_count
                 WHERE id = v_asg.id;
                v_incremented := v_incremented + 1;
            ELSE
                -- Case 2: the sale emptied the pasture and closed the row.
                -- Closing left head_count intact, so clearing moved_out
                -- restores the count by itself. Adding head here would double
                -- it - this is the delete_death_event bug.
                SELECT * INTO v_asg
                FROM public.lot_pasture_assignments
                WHERE lot_id = v_sale.lot_id
                  AND pasture_id = v_src.pasture_id
                  AND moved_out = v_sale.sale_date
                ORDER BY moved_in DESC
                LIMIT 1;

                IF NOT FOUND THEN
                    RAISE EXCEPTION
                        'No assignment to reverse for lot % pasture % (% head). These cattle have been moved since the shipment was saved - sort the pastures out by hand, then delete the sale rows individually.',
                        v_sale.lot_id, v_src.pasture_id, v_src.head_count;
                END IF;

                UPDATE public.lot_pasture_assignments
                   SET moved_out = NULL
                 WHERE id = v_asg.id;
                v_reopened := v_reopened + 1;
            END IF;
        END LOOP;
    END LOOP;

    DELETE FROM public.sale_sources
     WHERE sale_id IN (SELECT id FROM public.sales WHERE shipment_id = p_shipment_id);
    DELETE FROM public.sales WHERE shipment_id = p_shipment_id;
    DELETE FROM public.shipments WHERE id = p_shipment_id;

    -- A lot that was closed because this shipment emptied it has cattle
    -- standing in it again and must not stay closed. Guarded on head_current
    -- so a lot closed for some other reason is left alone.
    WITH reopened AS (
        UPDATE public.lots l
           SET closed_at = NULL
         WHERE l.id = ANY (v_lots)
           AND l.closed_at IS NOT NULL
           AND COALESCE((SELECT ls.head_current FROM public.lot_status ls WHERE ls.id = l.id), 0) > 0
        RETURNING 1
    )
    SELECT count(*)::integer INTO v_lots_reopened FROM reopened;

    RETURN jsonb_build_object(
        'sales_deleted',           v_sales,
        'assignments_incremented', v_incremented,
        'assignments_reopened',    v_reopened,
        'lots_reopened',           v_lots_reopened
    );
END
$fn$;

REVOKE ALL ON FUNCTION public.delete_shipment_with_reversal(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_shipment_with_reversal(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_shipment_with_reversal(uuid) TO authenticated;

COMMENT ON FUNCTION public.delete_shipment_with_reversal(uuid) IS
    'Owner-only. Deletes a shipment and its sales, and returns the cattle to their pastures. A decremented assignment gets head added back; a closed one is only reopened, because closing left head_count intact.';

-- ---------------------------------------------------------------------
-- 3. Crew loses sale dollars
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS sales_select ON public.sales;
CREATE POLICY sales_select ON public.sales
    FOR SELECT TO authenticated
    USING (public.current_user_role() = ANY (ARRAY['owner','office']));

DROP POLICY IF EXISTS sale_sources_select ON public.sale_sources;
CREATE POLICY sale_sources_select ON public.sale_sources
    FOR SELECT TO authenticated
    USING (public.current_user_role() = ANY (ARRAY['owner','office']));

-- ---------------------------------------------------------------------
-- 4. Verify
-- ---------------------------------------------------------------------
DO $verify$
DECLARE
    v_cols integer;
BEGIN
    SELECT count(*) INTO v_cols
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'shipment_loads'
      AND column_name IN ('lot_id', 'pasture_id', 'line_seq');
    IF v_cols <> 3 THEN
        RAISE EXCEPTION 'shipment_loads is missing lot_id/pasture_id/line_seq (found % of 3).', v_cols;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'shipment_loads_seq_uq'
          AND conrelid = to_regclass('public.shipment_loads')
    ) THEN
        RAISE EXCEPTION 'The old single-line-per-load constraint is still present.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'shipment_loads_seq_line_uq'
          AND conrelid = to_regclass('public.shipment_loads')
    ) THEN
        RAISE EXCEPTION 'shipment_loads_seq_line_uq was not created.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'delete_shipment_with_reversal'
    ) THEN
        RAISE EXCEPTION 'delete_shipment_with_reversal was not created.';
    END IF;

    -- It must NOT be SECURITY DEFINER: it has to obey the caller's RLS the
    -- way every other head-math RPC does.
    IF EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'delete_shipment_with_reversal'
          AND p.prosecdef
    ) THEN
        RAISE EXCEPTION 'delete_shipment_with_reversal is SECURITY DEFINER; it must be INVOKER.';
    END IF;

    IF has_function_privilege('anon', 'public.delete_shipment_with_reversal(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'anon can EXECUTE delete_shipment_with_reversal.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename IN ('sales', 'sale_sources')
          AND cmd = 'SELECT' AND qual::text ILIKE '%crew%'
    ) THEN
        RAISE EXCEPTION 'crew can still SELECT sales or sale_sources.';
    END IF;

    RAISE NOTICE 'Phase 2 applied: loads carry lot/pasture, reversal RPC live, crew off sale dollars.';
END
$verify$;
