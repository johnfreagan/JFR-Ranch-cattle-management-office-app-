-- STATUS: Applied 2026-10-03 on John's approval ("Tackle database"). John ran
-- it in the Supabase SQL Editor ("Success"). Verified afterwards: md5(prosrc)
-- matches this file (invoices_refuse_duplicate 367069aa134111d76a97e63a55532d63,
-- delete_receipt_with_reversal 3fa2af2ba385c0d090b95ae847c15844); the seven
-- office DELETE policies and the invoices_refuse_duplicate trigger exist;
-- anon cannot execute either function; rls_verify passes; all open lots tie.

-- Office tap audit, database batch. Four independent pieces, one transaction.
--
-- 1. Office may delete scratch rows that carry no books (additive policies;
--    the owner policies stay as they are):
--      * a DRAFT med count and its lines. saveInvCountDraft replaces a
--        draft's lines by delete-then-insert; with DELETE owner-only the
--        delete silently did nothing for office, so a second save or a post
--        after a draft hit the unique (count_id, medication_id) key, and
--        Delete draft said "deleted" while nothing was.
--      * a DRAFT feed count and its lines: a failed post_feed_count leaves
--        the draft header behind and office could not clear it.
--      * feed recipe lines: a recipe edit replaces its lines the same way.
--        Batches keep their own ingredient records, so this changes no books.
--      * a supply invoice nothing has been matched to (no feed receipt, no
--        receipt link, no price variance points at it): the app's rollback
--        when match_supply_invoice fails, and the "Invoice does not tie" dead
--        end. The RESTRICT foreign keys still refuse a matched one.
--      * a med purchase with no lines: the app's rollback when the line
--        insert fails.
--    Posted counts, matched invoices and purchases with lines stay owner-only.
--
-- 2. Lot purchase invoices: duplicate guard (trigger). Refuses a second
--    invoice on the same lot with the same invoice # (case and spaces
--    ignored), or with the same date, head and total cost. A double entry
--    doubled head in and cost in. None exist today (checked 2026-10-03).
--
-- 3. delete_receipt_with_reversal: CURRENT_DATE -> ranch_today() (the
--    database runs UTC; after 7 pm Central CURRENT_DATE is tomorrow). Live
--    prosrc md5 before this file: e515a1b7a6037177b947a046e3a1dda0; nothing
--    else in the body changes.
--
-- Run supabase/migrations/20260821000300_rls_verify.sql afterwards.

begin;

-- 1. Office cleanup policies --------------------------------------------

DROP POLICY IF EXISTS med_counts_delete_draft_office ON public.med_counts;
CREATE POLICY med_counts_delete_draft_office ON public.med_counts
    FOR DELETE TO authenticated
    USING (public.current_user_role() = 'office' AND status = 'draft');

DROP POLICY IF EXISTS med_count_lines_delete_draft_office ON public.med_count_lines;
CREATE POLICY med_count_lines_delete_draft_office ON public.med_count_lines
    FOR DELETE TO authenticated
    USING (public.current_user_role() = 'office'
           AND EXISTS (SELECT 1 FROM public.med_counts c
                        WHERE c.id = med_count_lines.count_id AND c.status = 'draft'));

DROP POLICY IF EXISTS feed_counts_delete_draft_office ON public.feed_counts;
CREATE POLICY feed_counts_delete_draft_office ON public.feed_counts
    FOR DELETE TO authenticated
    USING (public.current_user_role() = 'office' AND status = 'draft');

DROP POLICY IF EXISTS feed_count_lines_delete_draft_office ON public.feed_count_lines;
CREATE POLICY feed_count_lines_delete_draft_office ON public.feed_count_lines
    FOR DELETE TO authenticated
    USING (public.current_user_role() = 'office'
           AND EXISTS (SELECT 1 FROM public.feed_counts c
                        WHERE c.id = feed_count_lines.count_id AND c.status = 'draft'));

DROP POLICY IF EXISTS feed_recipe_lines_delete_office ON public.feed_recipe_lines;
CREATE POLICY feed_recipe_lines_delete_office ON public.feed_recipe_lines
    FOR DELETE TO authenticated
    USING (public.current_user_role() = 'office');

DROP POLICY IF EXISTS supply_invoices_delete_unmatched_office ON public.supply_invoices;
CREATE POLICY supply_invoices_delete_unmatched_office ON public.supply_invoices
    FOR DELETE TO authenticated
    USING (public.current_user_role() = 'office'
           AND NOT EXISTS (SELECT 1 FROM public.feed_receipts r WHERE r.invoice_id = supply_invoices.id)
           AND NOT EXISTS (SELECT 1 FROM public.supply_invoice_receipts x WHERE x.invoice_id = supply_invoices.id)
           AND NOT EXISTS (SELECT 1 FROM public.feed_price_variance v WHERE v.invoice_id = supply_invoices.id));

DROP POLICY IF EXISTS med_purchases_delete_empty_office ON public.med_purchases;
CREATE POLICY med_purchases_delete_empty_office ON public.med_purchases
    FOR DELETE TO authenticated
    USING (public.current_user_role() = 'office'
           AND NOT EXISTS (SELECT 1 FROM public.med_purchase_lines l WHERE l.purchase_id = med_purchases.id));

-- 2. Lot purchase invoice duplicate guard -------------------------------

CREATE OR REPLACE FUNCTION public.invoices_refuse_duplicate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_hit record;
BEGIN
    IF NULLIF(btrim(NEW.invoice_number), '') IS NOT NULL THEN
        SELECT invoice_date INTO v_hit FROM public.invoices i
         WHERE i.lot_id = NEW.lot_id
           AND i.id IS DISTINCT FROM NEW.id
           AND lower(btrim(i.invoice_number)) = lower(btrim(NEW.invoice_number))
         LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'DUPLICATE INVOICE — not saved. This lot already has invoice # % (dated %). If this is a correction, open the existing invoice instead.',
                btrim(NEW.invoice_number), to_char(v_hit.invoice_date, 'MM/DD/YYYY');
        END IF;
    END IF;
    IF EXISTS (SELECT 1 FROM public.invoices i
                WHERE i.lot_id = NEW.lot_id
                  AND i.id IS DISTINCT FROM NEW.id
                  AND i.invoice_date = NEW.invoice_date
                  AND i.head_count = NEW.head_count
                  AND i.total_cost = NEW.total_cost) THEN
        RAISE EXCEPTION 'DUPLICATE INVOICE — not saved. This lot already has an invoice dated % for % head and $%. If this is a correction, open the existing invoice instead.',
            to_char(NEW.invoice_date, 'MM/DD/YYYY'), NEW.head_count, NEW.total_cost;
    END IF;
    RETURN NEW;
END
$function$;

REVOKE ALL ON FUNCTION public.invoices_refuse_duplicate() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.invoices_refuse_duplicate() FROM anon;

DROP TRIGGER IF EXISTS invoices_refuse_duplicate ON public.invoices;
CREATE TRIGGER invoices_refuse_duplicate
    BEFORE INSERT OR UPDATE OF lot_id, invoice_number, invoice_date, head_count, total_cost
    ON public.invoices
    FOR EACH ROW EXECUTE FUNCTION public.invoices_refuse_duplicate();

-- 3. delete_receipt_with_reversal: ranch day, not UTC -------------------

CREATE OR REPLACE FUNCTION public.delete_receipt_with_reversal(p_receipt_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_receipt RECORD;
    v_dest RECORD;
    v_assign RECORD;
    v_tags_deleted INTEGER := 0;
    v_dests_deleted INTEGER := 0;
    v_pastures_touched INTEGER := 0;
BEGIN
    SELECT * INTO v_receipt FROM delivery_receipts WHERE id = p_receipt_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Load out % not found', p_receipt_id;
    END IF;

    -- 1. Reverse pasture assignment head, destination by destination
    FOR v_dest IN
        SELECT lod.id, lod.pasture_id, lod.head_count,
               (SELECT rn.name FROM pastures p JOIN ranches rn ON rn.id = p.ranch_id WHERE p.id = lod.pasture_id)
                 || ' / ' || (SELECT name FROM pastures WHERE id = lod.pasture_id) AS location
        FROM load_out_destinations lod
        WHERE lod.receipt_id = p_receipt_id
    LOOP
        SELECT * INTO v_assign
        FROM lot_pasture_assignments
        WHERE lot_id = v_receipt.lot_id
          AND pasture_id = v_dest.pasture_id
          AND moved_out IS NULL
        ORDER BY moved_in DESC
        LIMIT 1
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Cannot reverse: no open pasture assignment for % on this lot. Cattle were likely moved since this load out — reconcile pastures manually, then delete.', v_dest.location;
        END IF;

        IF v_assign.head_count < v_dest.head_count THEN
            RAISE EXCEPTION 'Cannot reverse: open assignment at % has % head but this load out contributed %. Cattle were likely moved since — reconcile pastures manually, then delete.', v_dest.location, v_assign.head_count, v_dest.head_count;
        END IF;

        IF v_assign.head_count = v_dest.head_count THEN
            UPDATE lot_pasture_assignments
            SET head_count = 0,
                moved_out = ranch_today(),
                notes = COALESCE(notes || ' / ', '')
                      || 'closed ' || ranch_today() || ' — load out deleted (reversal of ' || v_dest.head_count || ' hd)'
            WHERE id = v_assign.id;
        ELSE
            UPDATE lot_pasture_assignments
            SET head_count = head_count - v_dest.head_count,
                notes = COALESCE(notes || ' / ', '')
                      || 'reduced by ' || v_dest.head_count || ' hd on ' || ranch_today() || ' — load out deleted'
            WHERE id = v_assign.id;
        END IF;
        v_pastures_touched := v_pastures_touched + 1;
    END LOOP;

    -- 2. Delete tags registered by this receipt
    DELETE FROM lot_tags WHERE delivery_receipt_id = p_receipt_id;
    GET DIAGNOSTICS v_tags_deleted = ROW_COUNT;

    -- 3. Delete destinations, then the receipt
    DELETE FROM load_out_destinations WHERE receipt_id = p_receipt_id;
    GET DIAGNOSTICS v_dests_deleted = ROW_COUNT;

    DELETE FROM delivery_receipts WHERE id = p_receipt_id;

    RETURN jsonb_build_object(
        'receipt_date', v_receipt.receipt_date,
        'head_count', v_receipt.head_count,
        'pastures_reversed', v_pastures_touched,
        'destinations_deleted', v_dests_deleted,
        'tags_deleted', v_tags_deleted
    );
END $function$;

commit;
