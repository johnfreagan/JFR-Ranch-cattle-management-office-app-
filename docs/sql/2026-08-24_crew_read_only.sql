-- ============================================================================
-- 2026-08-24 — Crew becomes read-only in the books.
--
-- Closes two documented gaps in docs/USER-ADMIN-GUIDE.md §8:
--
--   #3  doctoring_event_meds had no ownership check at all — crew could
--       update or delete a medication line on anybody's treatment event,
--       even though the parent doctoring_events row was protected by
--       recorded_by_user_id = auth.uid().
--
--   #4  crew wrote directly into the books. The Part B design (HANDOFF.md)
--       has cowboys writing only to pending_field_entries for office review.
--
-- #4 is the stricter of the two and subsumes #3: crew with no write at all
-- cannot touch another person's med lines by definition.
--
-- AFTER THIS MIGRATION, crew can SELECT everything they could before
-- (i.e. everything except invoices) and INSERT/UPDATE/DELETE nothing.
--
-- When pending_field_entries lands, grant crew INSERT on THAT TABLE ONLY.
-- Do not restore any of the grants revoked here.
--
-- Idempotent: DROP POLICY IF EXISTS + CREATE POLICY. Safe to re-run.
-- Role targeting (TO public vs TO authenticated) is preserved exactly as
-- found, to keep the diff minimal; anon is denied either way because
-- current_user_role() returns NULL without an auth.uid().
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Guard: refuse to run if the world is not as this migration expects.
-- ---------------------------------------------------------------------------
DO $guard$
DECLARE
    v_missing TEXT;
BEGIN
    IF to_regprocedure('public.current_user_role()') IS NULL THEN
        RAISE EXCEPTION 'current_user_role() is missing. Every policy here depends on it.';
    END IF;

    SELECT string_agg(t, ', ') INTO v_missing
    FROM unnest(ARRAY[
        'doctoring_events', 'doctoring_event_meds', 'weights',
        'delivery_receipts', 'delivery_receipt_attachments',
        'load_out_destinations', 'lot_tags', 'lot_pasture_assignments',
        'lot_movements'
    ]) AS t
    WHERE to_regclass('public.' || t) IS NULL;

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Missing expected tables: %', v_missing;
    END IF;

    -- The staging table must NOT exist yet. If it does, someone has started
    -- Part B and this migration is no longer the whole story.
    IF to_regclass('public.pending_field_entries') IS NOT NULL THEN
        RAISE EXCEPTION
            'pending_field_entries exists. Part B has started; grant crew INSERT there and review this file before re-running.';
    END IF;
END
$guard$;

-- ---------------------------------------------------------------------------
-- doctoring_events — crew loses insert, and loses the own-row update/delete.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS doctoring_events_insert ON public.doctoring_events;
CREATE POLICY doctoring_events_insert ON public.doctoring_events
    FOR INSERT TO public
    WITH CHECK (current_user_role() = ANY (ARRAY['owner', 'office']));

DROP POLICY IF EXISTS doctoring_events_update ON public.doctoring_events;
CREATE POLICY doctoring_events_update ON public.doctoring_events
    FOR UPDATE TO public
    USING (current_user_role() = ANY (ARRAY['owner', 'office']));

DROP POLICY IF EXISTS doctoring_events_delete ON public.doctoring_events;
CREATE POLICY doctoring_events_delete ON public.doctoring_events
    FOR DELETE TO public
    USING (current_user_role() = ANY (ARRAY['owner', 'office']));

-- ---------------------------------------------------------------------------
-- doctoring_event_meds — was wide open to all three roles on every verb.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS doctoring_event_meds_insert ON public.doctoring_event_meds;
CREATE POLICY doctoring_event_meds_insert ON public.doctoring_event_meds
    FOR INSERT TO public
    WITH CHECK (current_user_role() = ANY (ARRAY['owner', 'office']));

DROP POLICY IF EXISTS doctoring_event_meds_update ON public.doctoring_event_meds;
CREATE POLICY doctoring_event_meds_update ON public.doctoring_event_meds
    FOR UPDATE TO public
    USING (current_user_role() = ANY (ARRAY['owner', 'office']));

DROP POLICY IF EXISTS doctoring_event_meds_delete ON public.doctoring_event_meds;
CREATE POLICY doctoring_event_meds_delete ON public.doctoring_event_meds
    FOR DELETE TO public
    USING (current_user_role() = ANY (ARRAY['owner', 'office']));

-- ---------------------------------------------------------------------------
-- The remaining crew INSERT grants across the books.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS weights_insert ON public.weights;
CREATE POLICY weights_insert ON public.weights
    FOR INSERT TO public
    WITH CHECK (current_user_role() = ANY (ARRAY['owner', 'office']));

DROP POLICY IF EXISTS delivery_receipts_insert ON public.delivery_receipts;
CREATE POLICY delivery_receipts_insert ON public.delivery_receipts
    FOR INSERT TO public
    WITH CHECK (current_user_role() = ANY (ARRAY['owner', 'office']));

DROP POLICY IF EXISTS dra_insert ON public.delivery_receipt_attachments;
CREATE POLICY dra_insert ON public.delivery_receipt_attachments
    FOR INSERT TO authenticated
    WITH CHECK (current_user_role() = ANY (ARRAY['owner', 'office']));

DROP POLICY IF EXISTS load_out_dests_insert ON public.load_out_destinations;
CREATE POLICY load_out_dests_insert ON public.load_out_destinations
    FOR INSERT TO public
    WITH CHECK (current_user_role() = ANY (ARRAY['owner', 'office']));

DROP POLICY IF EXISTS lot_tags_insert ON public.lot_tags;
CREATE POLICY lot_tags_insert ON public.lot_tags
    FOR INSERT TO public
    WITH CHECK (current_user_role() = ANY (ARRAY['owner', 'office']));

DROP POLICY IF EXISTS lpa_insert ON public.lot_pasture_assignments;
CREATE POLICY lpa_insert ON public.lot_pasture_assignments
    FOR INSERT TO public
    WITH CHECK (current_user_role() = ANY (ARRAY['owner', 'office']));

DROP POLICY IF EXISTS lot_movements_insert ON public.lot_movements;
CREATE POLICY lot_movements_insert ON public.lot_movements
    FOR INSERT TO authenticated
    WITH CHECK (current_user_role() = ANY (ARRAY['owner', 'office']));

-- ---------------------------------------------------------------------------
-- Verify: no policy anywhere in public may still name 'crew' outside a
-- SELECT. If one does, this migration missed it — fail the transaction.
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
    v_leaks TEXT;
BEGIN
    SELECT string_agg(tablename || '.' || policyname || ' (' || cmd || ')', ', ')
    INTO v_leaks
    FROM pg_policies
    WHERE schemaname = 'public'
      AND cmd <> 'SELECT'
      AND (coalesce(qual, '') || ' ' || coalesce(with_check, '')) LIKE '%crew%';

    IF v_leaks IS NOT NULL THEN
        RAISE EXCEPTION 'Crew still has non-SELECT access via: %', v_leaks;
    END IF;

    RAISE NOTICE 'Verified: crew has no write access to any table in public.';
END
$verify$;

COMMIT;
