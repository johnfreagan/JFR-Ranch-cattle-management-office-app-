-- =====================================================================
-- Fix: delete_shipment_with_reversal referenced lot_status.id
-- =====================================================================
-- 2026-08-26. Found by John on the first real reversal:
--   "Delete failed, nothing was changed: column ls.id does not exist"
--
-- The view's primary key column is `lot_id`, not `id`. The reversal's last
-- step - reopening a lot that was closed because the shipment emptied it -
-- joined on ls.id and threw.
--
-- Nothing was lost. A PL/pgSQL function is one transaction, so the whole
-- reversal rolled back and the shipment, its sales and its pasture
-- assignments were left exactly as they were. The error message was accurate.
--
-- Worth noting for next time: this is the one line in the function that was
-- never exercised by anything. Every other branch runs on a plain reversal;
-- the lot-reopen only runs when a lot was closed out, which the test case
-- did not do. An untested line in a function that is otherwise correct.
--
-- Idempotent: CREATE OR REPLACE, safe to run repeatedly.
-- =====================================================================

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
    --
    -- lot_status's key column is lot_id. It is NOT `id` - that was this
    -- function's one bug, and the only line in it nothing had exercised.
    WITH reopened AS (
        UPDATE public.lots l
           SET closed_at = NULL
         WHERE l.id = ANY (v_lots)
           AND l.closed_at IS NOT NULL
           AND COALESCE((SELECT ls.head_current
                           FROM public.lot_status ls
                          WHERE ls.lot_id = l.id), 0) > 0
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

-- ---------------------------------------------------------------------
-- Verify: the function must now compile against lot_status for real.
-- CREATE OR REPLACE only parses; it does not resolve column references in
-- SQL inside plpgsql until execution. So check the column exists, which is
-- the thing that was actually wrong.
-- ---------------------------------------------------------------------
DO $verify$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='lot_status' AND column_name='lot_id'
    ) THEN
        RAISE EXCEPTION 'lot_status.lot_id does not exist - the fix is wrong too.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='lot_status' AND column_name='id'
    ) THEN
        RAISE EXCEPTION 'lot_status now HAS an id column; re-check which one the function should use.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname='public' AND p.proname='delete_shipment_with_reversal'
          AND p.prosrc LIKE '%ls.id%'
    ) THEN
        RAISE EXCEPTION 'The function body still references ls.id.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname='public' AND p.proname='delete_shipment_with_reversal'
          AND p.prosrc LIKE '%ls.lot_id%'
    ) THEN
        RAISE EXCEPTION 'The function body does not reference ls.lot_id.';
    END IF;

    RAISE NOTICE 'delete_shipment_with_reversal fixed: lot_status keyed on lot_id.';
END
$verify$;
