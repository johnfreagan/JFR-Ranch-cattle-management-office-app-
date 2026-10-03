-- STATUS: Applied 2026-10-03 on John's approval ("A": retire the lot sale
-- modal; Delete sale owner-only and puts the head back). John ran it in the
-- Supabase SQL Editor ("Success"). Verified afterwards: md5(prosrc)
-- 0a2d1aa76b93faae6be0268777f2e19e matches this file; SECURITY INVOKER,
-- search_path public, pg_catalog; anon cannot execute, authenticated can;
-- rls_verify passes.

-- delete_sale_with_reversal(p_sale_id): owner-only reversal of ONE sale that
-- was entered on the lot screen (shipment_id IS NULL).
--
-- Why: the lot sale modal's "Delete sale" raw-deleted the sales row and said
-- "this does NOT restore cattle to pastures". sales DELETE is open to owner
-- AND office under RLS, so office could take head off the books for good
-- while the pastures stayed short - against the head-math rule that sales and
-- their reversals go through atomic RPCs. 15 such lot sales exist
-- (2026-04-20 to 2026-08-11); every open lot tied on 2026-10-03.
--
-- Same shape as delete_shipment_with_reversal, for one sale:
--   * owner only (checked here, so the message is plain, and again by RLS);
--   * a shipment's sale is refused: delete the shipment instead, which
--     reverses all its rows together;
--   * per source pasture: add the head back to the open assignment, or, if
--     the sale emptied and closed it on the sale date, clear moved_out
--     (closing left head_count intact, so adding would double it);
--   * delete sale_sources, then the sale, row-checked;
--   * reopen the lot if it was closed and now has head standing.
-- The lot_tags_retire_on_sale trigger un-retires the sale's tags on DELETE,
-- and feed_pen_cleanup_sale removes any feed-pen removal pointing at it.
-- SECURITY INVOKER, like every head-math RPC (docs/database.md rule 6).
--
-- Run supabase/migrations/20260821000300_rls_verify.sql afterwards.

begin;

CREATE OR REPLACE FUNCTION public.delete_sale_with_reversal(p_sale_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_role        text;
    v_sale        record;
    v_src         record;
    v_asg         record;
    v_n           integer;
    v_incremented integer := 0;
    v_reopened    integer := 0;
    v_lot_reopen  integer := 0;
BEGIN
    v_role := public.current_user_role();
    IF v_role IS DISTINCT FROM 'owner' THEN
        RAISE EXCEPTION 'Only the owner can delete a sale (current role: %).', COALESCE(v_role, 'none')
            USING ERRCODE = '42501';
    END IF;

    SELECT id, lot_id, sale_date, shipment_id, head_count INTO v_sale
      FROM public.sales WHERE id = p_sale_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sale % not found.', p_sale_id;
    END IF;
    IF v_sale.shipment_id IS NOT NULL THEN
        RAISE EXCEPTION 'This sale belongs to a shipment. Delete the shipment instead; that reverses all of its sales together.';
    END IF;
    -- Head goes back to the pastures the sale came from. If the sources do not
    -- add up to the sale's head, some head would land on the books with no
    -- pasture (D8 red), so refuse. All 15 lot sales tied on 2026-10-03.
    SELECT COALESCE(SUM(head_count), 0)::integer INTO v_n FROM public.sale_sources WHERE sale_id = p_sale_id;
    IF v_n <> v_sale.head_count THEN
        RAISE EXCEPTION 'This sale''s source pastures hold % head but the sale is % head. Fix the sources first; nothing was changed.',
            v_n, v_sale.head_count;
    END IF;

    FOR v_src IN
        SELECT pasture_id, SUM(head_count)::integer AS head_count
          FROM public.sale_sources
         WHERE sale_id = p_sale_id
         GROUP BY pasture_id
    LOOP
        SELECT * INTO v_asg
          FROM public.lot_pasture_assignments
         WHERE lot_id = v_sale.lot_id AND pasture_id = v_src.pasture_id AND moved_out IS NULL
         ORDER BY moved_in DESC LIMIT 1;

        IF FOUND THEN
            UPDATE public.lot_pasture_assignments
               SET head_count = head_count + v_src.head_count
             WHERE id = v_asg.id;
            v_incremented := v_incremented + 1;
        ELSE
            SELECT * INTO v_asg
              FROM public.lot_pasture_assignments
             WHERE lot_id = v_sale.lot_id AND pasture_id = v_src.pasture_id
               AND moved_out = v_sale.sale_date
             ORDER BY moved_in DESC LIMIT 1;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'No pasture assignment to put % head back into (pasture %). The cattle have been moved since this sale; sort the pastures out first.',
                    v_src.head_count, v_src.pasture_id;
            END IF;
            UPDATE public.lot_pasture_assignments
               SET moved_out = NULL
             WHERE id = v_asg.id;
            v_reopened := v_reopened + 1;
        END IF;
    END LOOP;

    DELETE FROM public.sale_sources WHERE sale_id = p_sale_id;
    DELETE FROM public.sales WHERE id = p_sale_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'Not deleted: the sale row was refused. Nothing was changed.'
            USING ERRCODE = '42501';
    END IF;

    WITH reopened AS (
        UPDATE public.lots l
           SET closed_at = NULL
         WHERE l.id = v_sale.lot_id
           AND l.closed_at IS NOT NULL
           AND COALESCE((SELECT ls.head_current FROM public.lot_status ls WHERE ls.lot_id = l.id), 0) > 0
        RETURNING 1
    )
    SELECT count(*)::integer INTO v_lot_reopen FROM reopened;

    RETURN jsonb_build_object(
        'head_restored',           v_sale.head_count,
        'assignments_incremented', v_incremented,
        'assignments_reopened',    v_reopened,
        'lot_reopened',            v_lot_reopen > 0
    );
END
$function$;

REVOKE ALL ON FUNCTION public.delete_sale_with_reversal(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_sale_with_reversal(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_sale_with_reversal(uuid) TO authenticated;

commit;
