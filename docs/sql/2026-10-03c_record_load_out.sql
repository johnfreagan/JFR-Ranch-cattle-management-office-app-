-- STATUS: written 2026-10-03 on John's approval ("Do all 4"). Not yet applied.

-- record_load_out: a NEW load out (delivery receipt) in one transaction.
--
-- Why: the office app saved a load out as five separate client calls -
-- receipt, processing draw, load_out_destinations, lot_pasture_assignments,
-- lot_tags. The pasture step was wrapped so that a failure was only a
-- warning ("Load out saved and tags registered, but pasture auto-assign
-- failed"), which leaves head on the books in no pasture (D8 red). A failed
-- destination or tag insert left the receipt saved with missing children,
-- the duplicate check was skipped if its query failed, and tags were
-- silently not registered when the lot had no fiscal_year.
--
-- This function does the receipt, destinations, pasture head and tags
-- together; any failure rolls back all of it. The processing-medicine draw
-- (med_processing_draw) stays a separate call from the app after this
-- returns: it is inventory, not head math, and it reports its own errors.
--
-- Rules it enforces (all were client-side only before, or not at all):
--   * head > 0; at least one destination; destinations sum to head;
--   * the lot exists and is open;
--   * DUPLICATE LOAD OUT: same lot, date, head and tag range is refused,
--     no override (same rule and wording as the app);
--   * tags need the lot's fiscal_year; a tag already active in that fiscal
--     year stops the save unless the caller passed p_override_reason, in
--     which case the other lot's registration is retired with that reason
--     first (the app's "Register anyway"). "Skip conflicting tags" is the
--     app leaving those tags out of p_register_tags.
--
-- p_destinations: jsonb array of {"pasture_id": uuid, "head_count": int}.
-- p_register_tags: the tag numbers to register (range minus missing, minus
-- any the user chose to skip).
--
-- SECURITY INVOKER like every head-math RPC (docs/database.md rule 6). RLS on
-- delivery_receipts, load_out_destinations, lot_tags and
-- lot_pasture_assignments already limits writes to owner and office.
-- Run supabase/migrations/20260821000300_rls_verify.sql afterwards.

begin;

CREATE OR REPLACE FUNCTION public.record_load_out(
    p_lot_id                uuid,
    p_receipt_date          date,
    p_head_count            integer,
    p_tag_start             integer,
    p_tag_end               integer,
    p_missing_tags          integer[],
    p_receiving_protocol_id uuid,
    p_invoice_id            uuid,
    p_notes                 text,
    p_destinations          jsonb,
    p_register_tags         integer[],
    p_override_reason       text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_lot        record;
    v_receipt_id uuid;
    v_dest       record;
    v_sum        integer;
    v_assign     uuid;
    v_conflicts  integer[];
    v_retired    integer := 0;
    v_tags       integer := 0;
BEGIN
    IF p_head_count IS NULL OR p_head_count <= 0 THEN
        RAISE EXCEPTION 'Head count is required.';
    END IF;
    IF p_receipt_date IS NULL THEN
        RAISE EXCEPTION 'Load out date is required.';
    END IF;

    SELECT id, lot_number, fiscal_year, closed_at INTO v_lot FROM public.lots WHERE id = p_lot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Lot % not found.', p_lot_id;
    END IF;
    IF v_lot.closed_at IS NOT NULL THEN
        RAISE EXCEPTION 'Lot % is closed. Re-open it before adding a load out.', v_lot.lot_number;
    END IF;

    IF p_destinations IS NULL OR jsonb_typeof(p_destinations) <> 'array'
       OR jsonb_array_length(p_destinations) = 0 THEN
        RAISE EXCEPTION 'Pick at least one destination pasture for the load out.';
    END IF;
    SELECT COALESCE(SUM((d->>'head_count')::integer), 0) INTO v_sum
      FROM jsonb_array_elements(p_destinations) d;
    IF v_sum <> p_head_count THEN
        RAISE EXCEPTION 'Destinations total (% hd) must equal head count (% hd).', v_sum, p_head_count;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_destinations) d
               WHERE d->>'pasture_id' IS NULL OR COALESCE((d->>'head_count')::integer, 0) <= 0) THEN
        RAISE EXCEPTION 'Every destination needs a pasture and a head count above zero.';
    END IF;

    IF EXISTS (SELECT 1 FROM public.delivery_receipts r
               WHERE r.lot_id = p_lot_id
                 AND r.receipt_date = p_receipt_date
                 AND r.head_count = p_head_count
                 AND r.tag_start IS NOT DISTINCT FROM p_tag_start
                 AND r.tag_end IS NOT DISTINCT FROM p_tag_end) THEN
        RAISE EXCEPTION 'DUPLICATE LOAD OUT — not saved. A receipt already exists on this lot for % with % head and the same tag range. If this is a correction, edit the existing receipt instead of entering a new one.',
            to_char(p_receipt_date, 'MM/DD/YYYY'), p_head_count;
    END IF;

    INSERT INTO public.delivery_receipts (
        lot_id, receipt_date, head_count, tag_start, tag_end, missing_tags,
        receiving_protocol_id, invoice_id, notes, created_by
    ) VALUES (
        p_lot_id, p_receipt_date, p_head_count, p_tag_start, p_tag_end,
        NULLIF(p_missing_tags, '{}'), p_receiving_protocol_id, p_invoice_id, p_notes, auth.uid()
    ) RETURNING id INTO v_receipt_id;

    FOR v_dest IN
        SELECT (d->>'pasture_id')::uuid AS pasture_id, SUM((d->>'head_count')::integer)::integer AS head_count
          FROM jsonb_array_elements(p_destinations) d
         GROUP BY 1
    LOOP
        INSERT INTO public.load_out_destinations (receipt_id, pasture_id, head_count)
        VALUES (v_receipt_id, v_dest.pasture_id, v_dest.head_count);

        SELECT id INTO v_assign
          FROM public.lot_pasture_assignments
         WHERE lot_id = p_lot_id AND pasture_id = v_dest.pasture_id AND moved_out IS NULL
         FOR UPDATE;
        IF v_assign IS NOT NULL THEN
            UPDATE public.lot_pasture_assignments
               SET head_count = head_count + v_dest.head_count
             WHERE id = v_assign;
        ELSE
            INSERT INTO public.lot_pasture_assignments
                (lot_id, pasture_id, head_count, moved_in, notes, recorded_by)
            VALUES (p_lot_id, v_dest.pasture_id, v_dest.head_count, p_receipt_date,
                    'Auto from load out', auth.uid());
        END IF;
    END LOOP;

    IF COALESCE(array_length(p_register_tags, 1), 0) > 0 THEN
        IF v_lot.fiscal_year IS NULL THEN
            RAISE EXCEPTION 'Lot % has no fiscal year, so its tags cannot be registered. Nothing was saved.', v_lot.lot_number;
        END IF;

        SELECT array_agg(t.tag_number ORDER BY t.tag_number) INTO v_conflicts
          FROM public.lot_tags t
         WHERE t.fiscal_year = v_lot.fiscal_year
           AND t.status = 'active'
           AND t.tag_number = ANY (p_register_tags);

        IF v_conflicts IS NOT NULL THEN
            IF NULLIF(btrim(p_override_reason), '') IS NULL THEN
                RAISE EXCEPTION 'Tag(s) % are already active in fiscal year %. Nothing was saved.',
                    array_to_string(v_conflicts, ', '), v_lot.fiscal_year;
            END IF;
            IF EXISTS (SELECT 1 FROM public.lot_tags t
                       WHERE t.fiscal_year = v_lot.fiscal_year AND t.status = 'active'
                         AND t.lot_id = p_lot_id AND t.tag_number = ANY (p_register_tags)) THEN
                RAISE EXCEPTION 'Some of these tags are already active on lot % itself. Nothing was saved.', v_lot.lot_number;
            END IF;
            UPDATE public.lot_tags
               SET status = 'retired', retired_at = now(),
                   retired_reason = 'Override on registration to lot ' || v_lot.lot_number || ': ' || p_override_reason
             WHERE fiscal_year = v_lot.fiscal_year
               AND status = 'active'
               AND lot_id <> p_lot_id
               AND tag_number = ANY (p_register_tags);
            GET DIAGNOSTICS v_retired = ROW_COUNT;
        END IF;

        INSERT INTO public.lot_tags
            (tag_number, lot_id, delivery_receipt_id, fiscal_year, status, registered_by, notes)
        SELECT t, p_lot_id, v_receipt_id, v_lot.fiscal_year, 'active', auth.uid(),
               CASE WHEN NULLIF(btrim(p_override_reason), '') IS NOT NULL
                    THEN 'Override registration: ' || p_override_reason END
          FROM (SELECT DISTINCT unnest(p_register_tags) AS t) x;
        GET DIAGNOSTICS v_tags = ROW_COUNT;
    END IF;

    RETURN jsonb_build_object(
        'receipt_id',      v_receipt_id,
        'tags_registered', v_tags,
        'tags_retired',    v_retired
    );
END
$function$;

REVOKE ALL ON FUNCTION public.record_load_out(uuid, date, integer, integer, integer, integer[], uuid, uuid, text, jsonb, integer[], text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_load_out(uuid, date, integer, integer, integer, integer[], uuid, uuid, text, jsonb, integer[], text) FROM anon;
GRANT EXECUTE ON FUNCTION public.record_load_out(uuid, date, integer, integer, integer, integer[], uuid, uuid, text, jsonb, integer[], text) TO authenticated;

commit;
