-- =====================================================================
-- Crew read EVERY staged field entry, not only their own
-- =====================================================================
-- 2026-08-25.
--
-- Why: the field app's daily report exists so the head man can stay
-- current with what the whole crew did that day. At the moment he looks,
-- most of that work has not been approved yet, so it lives in
-- pending_field_entries rather than in the books. Crew could previously
-- SELECT only rows they submitted themselves, which is exactly the data
-- the report needs and exactly the data that was hidden.
--
-- Scope: SELECT only. INSERT, UPDATE and DELETE are left untouched, so a
-- crew member still writes only their own pending rows and still cannot
-- alter anyone else's. Widening SELECT does not widen UPDATE - each
-- command's policy is evaluated on its own USING clause.
--
-- What this exposes to crew: every cowboy's staged tag, lot, location,
-- medications, doses and notes, plus the office's review notes. There is
-- no cost or margin data on this table, and no write path is opened.
--
-- Idempotent: safe to run repeatedly.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Preconditions. Fail loudly rather than half-applying.
-- ---------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regclass('public.pending_field_entries') IS NULL THEN
        RAISE EXCEPTION 'pending_field_entries is missing - wrong database?';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_class
        WHERE oid = 'public.pending_field_entries'::regclass
          AND relrowsecurity
    ) THEN
        RAISE EXCEPTION 'Row level security is NOT enabled on pending_field_entries - stopping.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename  = 'pending_field_entries'
          AND policyname = 'pending_field_entries_select'
    ) THEN
        RAISE EXCEPTION 'Policy pending_field_entries_select is missing - RLS is not in the expected state.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'current_user_role'
    ) THEN
        RAISE EXCEPTION 'current_user_role() is missing - every policy here depends on it.';
    END IF;
END
$pre$;

-- ---------------------------------------------------------------------
-- The change. Read for any active role; an inactive or unknown user gets
-- NULL from current_user_role(), and NULL = ANY(...) is not true, so the
-- policy still fails closed.
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS pending_field_entries_select ON public.pending_field_entries;

CREATE POLICY pending_field_entries_select
    ON public.pending_field_entries
    FOR SELECT
    USING (current_user_role() = ANY (ARRAY['owner', 'office', 'crew']));

-- ---------------------------------------------------------------------
-- Prove the read widened AND that the write side is untouched. If any of
-- these fail, the whole transaction rolls back and nothing changed.
-- ---------------------------------------------------------------------
DO $post$
DECLARE
    sel_qual  TEXT;
    upd_qual  TEXT;
    ins_check TEXT;
    del_qual  TEXT;
BEGIN
    SELECT qual       INTO sel_qual  FROM pg_policies
      WHERE schemaname='public' AND tablename='pending_field_entries' AND cmd='SELECT';
    SELECT qual       INTO upd_qual  FROM pg_policies
      WHERE schemaname='public' AND tablename='pending_field_entries' AND cmd='UPDATE';
    SELECT with_check INTO ins_check FROM pg_policies
      WHERE schemaname='public' AND tablename='pending_field_entries' AND cmd='INSERT';
    SELECT qual       INTO del_qual  FROM pg_policies
      WHERE schemaname='public' AND tablename='pending_field_entries' AND cmd='DELETE';

    -- The read must now cover crew without an own-row restriction.
    IF sel_qual IS NULL OR sel_qual NOT LIKE '%crew%' THEN
        RAISE EXCEPTION 'SELECT policy did not take - crew is not covered.';
    END IF;
    IF sel_qual LIKE '%submitted_by%' THEN
        RAISE EXCEPTION 'SELECT policy still restricts crew to their own rows.';
    END IF;

    -- The write side must still pin crew to their own rows. If one of
    -- these is no longer true, something outside this migration changed
    -- it and a human should look before this is applied.
    IF upd_qual IS NULL OR upd_qual NOT LIKE '%submitted_by%' THEN
        RAISE EXCEPTION 'UPDATE policy no longer restricts crew to their own rows - stopping.';
    END IF;
    IF ins_check IS NULL OR ins_check NOT LIKE '%submitted_by%' THEN
        RAISE EXCEPTION 'INSERT policy no longer pins submitted_by to the caller - stopping.';
    END IF;
    IF del_qual IS NULL OR del_qual NOT LIKE '%owner%' THEN
        RAISE EXCEPTION 'DELETE policy is no longer owner-only - stopping.';
    END IF;

    RAISE NOTICE 'pending_field_entries: crew now read all staged entries. Write side verified unchanged.';
END
$post$;

COMMIT;

-- =====================================================================
-- After applying, this should show four policies: SELECT open to all
-- three roles, INSERT/UPDATE still carrying submitted_by, DELETE owner.
--
--   SELECT cmd, policyname, qual, with_check
--   FROM pg_policies
--   WHERE schemaname = 'public' AND tablename = 'pending_field_entries'
--   ORDER BY cmd;
-- =====================================================================
