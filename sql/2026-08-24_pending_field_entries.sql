-- =====================================================================
-- pending_field_entries — staging table for field app submissions
-- =====================================================================
-- Roadmap item 3 (Field PWA), Part B step 1.
--
-- The field app never writes to the books. It writes here; the office
-- reviews and approves, and approval runs an RPC (built in step 3) that
-- writes the real rows.
--
--     field PWA -> pending_field_entries -> office review -> RPC -> books
--
-- This migration creates ONLY the staging table, its constraints, its
-- RLS policies and its guard triggers. It touches no existing table,
-- no existing view and no existing function. Nothing in the books moves.
--
-- Idempotent: safe to run repeatedly.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Preconditions. Fail loudly rather than half-applying.
-- ---------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regclass('public.user_profiles') IS NULL THEN
        RAISE EXCEPTION 'user_profiles is missing - auth/RLS groundwork must exist first.';
    END IF;
    IF to_regclass('public.field_actions') IS NULL THEN
        RAISE EXCEPTION 'field_actions is missing.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'current_user_role'
    ) THEN
        RAISE EXCEPTION 'current_user_role() is missing - RLS policies depend on it.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'touch_updated_at'
    ) THEN
        RAISE EXCEPTION 'touch_updated_at() is missing - updated_at trigger depends on it.';
    END IF;
END
$pre$;

-- ---------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pending_field_entries (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- What the cowboy submitted, verbatim. NEVER edited by review.
    -- Review writes its decisions into the resolved_* columns below, so
    -- the original submission stays auditable forever.
    entry_type          TEXT        NOT NULL,
    client_id           TEXT        NOT NULL,
    raw                 JSONB       NOT NULL,

    -- Resolved by the reviewer. Nullable until then; an unresolved
    -- column is what the review screen renders as a warning + picker.
    lot_id              UUID        REFERENCES public.lots(id),
    pasture_id          UUID        REFERENCES public.pastures(id),
    to_pasture_id       UUID        REFERENCES public.pastures(id),
    field_action_id     UUID        REFERENCES public.field_actions(id),
    tag_number          TEXT,
    no_tag              BOOLEAN     NOT NULL DEFAULT FALSE,
    event_datetime      TIMESTAMPTZ,
    head_count          INTEGER,

    -- Up to three meds, each either mapped to a medication row or kept
    -- as free text. jsonb rather than nine columns because the shape is
    -- a list and the office screen edits it as one unit. Expected shape:
    --   [{"position":1,"medication_id":"<uuid>|null",
    --     "medication_name_freetext":"...|null","dose_cc":<numeric>|null}]
    resolved_meds       JSONB       NOT NULL DEFAULT '[]'::jsonb,

    -- Review state
    status              TEXT        NOT NULL DEFAULT 'pending',
    review_notes        TEXT,

    -- What approval produced, for audit and for any later reversal:
    --   {"kind":"doctoring_event"|"lot_event"|"lot_movement","id":"<uuid>"}
    -- A death approval writes lot_events (via record_death_with_pasture),
    -- not doctoring_events, so this cannot be a single typed FK.
    approved_ref        JSONB,

    submitted_by        UUID        REFERENCES public.user_profiles(id),
    submitted_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    reviewed_by         UUID        REFERENCES public.user_profiles(id),
    reviewed_at         TIMESTAMPTZ,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Constraints (added separately so re-runs against an existing table
-- still converge)
-- ---------------------------------------------------------------------
DO $c$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conname = 'pfe_entry_type_check'
                     AND conrelid = 'public.pending_field_entries'::regclass) THEN
        ALTER TABLE public.pending_field_entries
            ADD CONSTRAINT pfe_entry_type_check
            CHECK (entry_type IN ('doctoring', 'move'));
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conname = 'pfe_status_check'
                     AND conrelid = 'public.pending_field_entries'::regclass) THEN
        ALTER TABLE public.pending_field_entries
            ADD CONSTRAINT pfe_status_check
            -- 'withdrawn' exists because the field app can delete a saved
            -- record (app.js sends {action:'delete'}). Without it a mistake
            -- the cowboy already deleted would sit in the approval queue.
            CHECK (status IN ('pending', 'approved', 'rejected', 'withdrawn'));
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conname = 'pfe_head_count_check'
                     AND conrelid = 'public.pending_field_entries'::regclass) THEN
        ALTER TABLE public.pending_field_entries
            ADD CONSTRAINT pfe_head_count_check
            CHECK (head_count IS NULL OR head_count >= 0);
    END IF;
END
$c$;

-- Idempotency key for the offline queue. The field app retries the same
-- record until it lands, and a cowboy editing a saved record re-sends it
-- under the SAME client id, so the app's insert is an UPSERT on this
-- constraint, not a plain insert. See the guard trigger below for what
-- stops an edit from rewriting an entry the office already acted on.
CREATE UNIQUE INDEX IF NOT EXISTS pfe_entry_type_client_id_key
    ON public.pending_field_entries (entry_type, client_id);

-- Review queue: newest-first within a status.
CREATE INDEX IF NOT EXISTS pfe_status_submitted_at_idx
    ON public.pending_field_entries (status, submitted_at DESC);

-- A cowboy reading back their own entries (to see rejections).
CREATE INDEX IF NOT EXISTS pfe_submitted_by_idx
    ON public.pending_field_entries (submitted_by, submitted_at DESC);

-- ---------------------------------------------------------------------
-- updated_at, matching the convention used across the schema
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS pending_field_entries_touch_updated_at
    ON public.pending_field_entries;
CREATE TRIGGER pending_field_entries_touch_updated_at
    BEFORE UPDATE ON public.pending_field_entries
    FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- ---------------------------------------------------------------------
-- Guard: an entry the office already acted on is frozen.
--
-- The field app's offline queue can deliver a stale edit AFTER approval
-- (cowboy edits on a dead phone, comes back on signal an hour later).
-- Without this, that late write would silently rewrite an entry whose
-- rows are already in the books, and the audit trail would lie.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pfe_guard_settled()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $guard$
BEGIN
    -- Legal status transitions. Without this, an entry the cowboy
    -- withdrew could still be approved straight into the books, which is
    -- exactly the entry most likely to be a mistake he caught himself.
    -- Reinstating it is allowed, but it has to go back through 'pending'
    -- so a reviewer looks at it again.
    --
    --   pending   -> approved | rejected | withdrawn
    --   withdrawn -> pending            (office reinstates)
    --   rejected  -> pending            (office reopens)
    --   approved  -> (terminal)
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT (
               (OLD.status = 'pending'   AND NEW.status IN ('approved','rejected','withdrawn'))
            OR (OLD.status = 'withdrawn' AND NEW.status = 'pending')
            OR (OLD.status = 'rejected'  AND NEW.status = 'pending')
        ) THEN
            RAISE EXCEPTION 'pfe_status: illegal transition % -> % for entry %.', OLD.status, NEW.status, OLD.id
                USING ERRCODE = 'raise_exception';
        END IF;
    END IF;

    -- Stamp the reviewer on a real review decision.
    -- Deliberately NOT on 'withdrawn': a withdrawal is the cowboy pulling
    -- his own entry back, and stamping him as reviewed_by would make the
    -- office screen read "reviewed by <cowboy>" for something nobody
    -- reviewed. Reopening clears the stamp so it reflects the live state.
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NEW.status IN ('approved', 'rejected') THEN
            NEW.reviewed_at := COALESCE(NEW.reviewed_at, now());
            NEW.reviewed_by := COALESCE(NEW.reviewed_by, auth.uid());
        ELSIF NEW.status = 'pending' THEN
            NEW.reviewed_at := NULL;
            NEW.reviewed_by := NULL;
        END IF;
    END IF;

    -- An approved entry is terminal. Only review_notes may still change
    -- (so the office can annotate after the fact).
    IF OLD.status = 'approved' THEN
        IF NEW.entry_type   IS DISTINCT FROM OLD.entry_type
        OR NEW.client_id    IS DISTINCT FROM OLD.client_id
        OR NEW.raw          IS DISTINCT FROM OLD.raw
        OR NEW.status       IS DISTINCT FROM OLD.status
        OR NEW.approved_ref IS DISTINCT FROM OLD.approved_ref
        OR NEW.lot_id       IS DISTINCT FROM OLD.lot_id
        OR NEW.pasture_id   IS DISTINCT FROM OLD.pasture_id
        OR NEW.to_pasture_id IS DISTINCT FROM OLD.to_pasture_id
        OR NEW.field_action_id IS DISTINCT FROM OLD.field_action_id
        OR NEW.tag_number   IS DISTINCT FROM OLD.tag_number
        OR NEW.head_count   IS DISTINCT FROM OLD.head_count
        OR NEW.resolved_meds IS DISTINCT FROM OLD.resolved_meds
        THEN
            RAISE EXCEPTION 'pfe_settled: entry % is approved and cannot be modified (only review_notes may change). Reverse the posted rows first.', OLD.id
                USING ERRCODE = 'raise_exception';
        END IF;
    END IF;

    -- The submission itself is immutable once anything has been decided.
    IF OLD.status <> 'pending' AND NEW.raw IS DISTINCT FROM OLD.raw THEN
        RAISE EXCEPTION 'pfe_settled: raw payload of entry % is immutable after review.', OLD.id
            USING ERRCODE = 'raise_exception';
    END IF;

    -- client_id/entry_type are the idempotency key. Never reassignable.
    IF NEW.client_id IS DISTINCT FROM OLD.client_id
    OR NEW.entry_type IS DISTINCT FROM OLD.entry_type THEN
        RAISE EXCEPTION 'pfe_settled: entry_type/client_id form the idempotency key and cannot be changed.'
            USING ERRCODE = 'raise_exception';
    END IF;

    RETURN NEW;
END
$guard$;

DROP TRIGGER IF EXISTS pending_field_entries_guard_settled
    ON public.pending_field_entries;
CREATE TRIGGER pending_field_entries_guard_settled
    BEFORE UPDATE ON public.pending_field_entries
    FOR EACH ROW EXECUTE FUNCTION public.pfe_guard_settled();

-- ---------------------------------------------------------------------
-- RLS. This table is the field app's ONLY write surface.
-- Policy shape follows the existing convention: role via
-- current_user_role(), no direct grants to the anon role.
-- ---------------------------------------------------------------------
ALTER TABLE public.pending_field_entries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pending_field_entries_select ON public.pending_field_entries;
CREATE POLICY pending_field_entries_select
    ON public.pending_field_entries FOR SELECT
    USING (
        current_user_role() = ANY (ARRAY['owner', 'office'])
        OR (current_user_role() = 'crew' AND submitted_by = auth.uid())
    );

DROP POLICY IF EXISTS pending_field_entries_insert ON public.pending_field_entries;
CREATE POLICY pending_field_entries_insert
    ON public.pending_field_entries FOR INSERT
    WITH CHECK (
        current_user_role() = ANY (ARRAY['owner', 'office', 'crew'])
        -- Cannot submit as someone else, and cannot submit pre-approved.
        AND submitted_by = auth.uid()
        AND status = 'pending'
    );

DROP POLICY IF EXISTS pending_field_entries_update ON public.pending_field_entries;
CREATE POLICY pending_field_entries_update
    ON public.pending_field_entries FOR UPDATE
    USING (
        current_user_role() = ANY (ARRAY['owner', 'office'])
        OR (current_user_role() = 'crew'
            AND submitted_by = auth.uid()
            AND status = 'pending')
    )
    WITH CHECK (
        current_user_role() = ANY (ARRAY['owner', 'office'])
        -- A cowboy may edit or withdraw their own pending entry.
        -- They may NOT approve or reject it.
        OR (current_user_role() = 'crew'
            AND submitted_by = auth.uid()
            AND status IN ('pending', 'withdrawn'))
    );

DROP POLICY IF EXISTS pending_field_entries_delete ON public.pending_field_entries;
CREATE POLICY pending_field_entries_delete
    ON public.pending_field_entries FOR DELETE
    -- Rejected entries are never deleted; they surface back to the cowboy.
    -- Owner-only, as an escape hatch for genuine junk.
    USING (current_user_role() = 'owner');

-- ---------------------------------------------------------------------
-- Grants.
--
-- RLS gates the rows; grants gate the table. Every other table in this
-- schema carries exactly {authenticated, service_role} and deliberately
-- NOT anon, so a logged-out visitor cannot reach the field queue at all.
-- Stated explicitly rather than left to ALTER DEFAULT PRIVILEGES, which
-- resolves differently depending on which role runs this file.
-- ---------------------------------------------------------------------
REVOKE ALL ON public.pending_field_entries FROM PUBLIC;
DO $g$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        EXECUTE 'REVOKE ALL ON public.pending_field_entries FROM anon';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON public.pending_field_entries TO authenticated';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        EXECUTE 'GRANT ALL ON public.pending_field_entries TO service_role';
    END IF;
END
$g$;

-- ---------------------------------------------------------------------
-- Documentation
-- ---------------------------------------------------------------------
COMMENT ON TABLE public.pending_field_entries IS
    'Staging queue for field app (PWA) submissions. Nothing here is in the books until an office review approves it and the approval RPC posts the real rows. raw is the cowboy submission verbatim and is never edited.';
COMMENT ON COLUMN public.pending_field_entries.client_id IS
    'The field app''s own record id (String(Date.now()), or "M-"+ts for moves). Unique with entry_type; this is the idempotency key the offline queue upserts on.';
COMMENT ON COLUMN public.pending_field_entries.raw IS
    'Field payload verbatim. Immutable once reviewed.';
COMMENT ON COLUMN public.pending_field_entries.resolved_meds IS
    'Array of {position, medication_id, medication_name_freetext, dose_cc}. Cost is NOT stored here - it is priced at approval time and frozen into doctoring_event_meds.';
COMMENT ON COLUMN public.pending_field_entries.approved_ref IS
    '{"kind":"doctoring_event"|"lot_event"|"lot_movement","id":uuid} - what approval actually wrote.';
COMMENT ON COLUMN public.pending_field_entries.status IS
    'pending | approved | rejected | withdrawn. withdrawn = the cowboy deleted it in the field app before review.';

COMMIT;

-- =====================================================================
-- Verification (read-only; run after the migration)
-- =====================================================================
-- SELECT count(*) AS policies FROM pg_policies
--  WHERE schemaname='public' AND tablename='pending_field_entries';      -- expect 4
-- SELECT relrowsecurity FROM pg_class
--  WHERE oid='public.pending_field_entries'::regclass;                   -- expect t
-- SELECT count(*) AS rows FROM public.pending_field_entries;             -- expect 0
