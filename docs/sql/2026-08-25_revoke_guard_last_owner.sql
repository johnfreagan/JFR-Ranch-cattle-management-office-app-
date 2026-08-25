-- =====================================================================
-- Close the last anon-executable function
-- =====================================================================
-- Found by the Supabase security advisor, 2026-08-25:
--
--   Function `public.guard_last_owner()` can be executed by the `anon`
--   role as a SECURITY DEFINER function via /rest/v1/rpc/guard_last_owner
--
-- guard_last_owner() is a TRIGGER function on user_profiles. It has no
-- business being reachable over PostgREST at all, by anyone. It is only
-- exposed because Postgres grants EXECUTE on new functions to PUBLIC by
-- default -- exactly the hole CLAUDE.md rule 4 warns about ("Revoke from
-- PUBLIC, not just anon").
--
-- Impact is low, not zero: called outside a trigger it hits an undefined
-- TG_OP and errors rather than doing anything. But it is a SECURITY
-- DEFINER function on the auth path that an unauthenticated caller can
-- reach, and it is the only one left. Close it.
--
-- Revoking EXECUTE does NOT break the trigger. Postgres checks the
-- TRIGGER privilege on the table when the trigger fires; it does not
-- check EXECUTE on the trigger function. Verified below.
--
-- Idempotent. Safe to re-run.
-- =====================================================================

REVOKE ALL ON FUNCTION public.guard_last_owner() FROM PUBLIC;

DO $g$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        EXECUTE 'REVOKE ALL ON FUNCTION public.guard_last_owner() FROM anon';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        EXECUTE 'REVOKE ALL ON FUNCTION public.guard_last_owner() FROM authenticated';
    END IF;
END
$g$;

-- ---------------------------------------------------------------------
-- Verify: nobody but the owner may call it, and the trigger still exists.
-- ---------------------------------------------------------------------
DO $v$
DECLARE
    v_anon BOOLEAN := false;
    v_auth BOOLEAN := false;
    v_trig INTEGER;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        v_anon := has_function_privilege('anon', 'public.guard_last_owner()', 'EXECUTE');
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        v_auth := has_function_privilege('authenticated', 'public.guard_last_owner()', 'EXECUTE');
    END IF;

    SELECT count(*) INTO v_trig
    FROM pg_trigger
    WHERE NOT tgisinternal
      AND tgfoid = 'public.guard_last_owner()'::regprocedure;

    IF v_anon OR v_auth THEN
        RAISE EXCEPTION 'guard_last_owner is still executable (anon=%, authenticated=%).', v_anon, v_auth;
    END IF;
    IF v_trig = 0 THEN
        RAISE EXCEPTION 'guard_last_owner is no longer attached to any trigger - check before shipping.';
    END IF;

    RAISE NOTICE 'OK: guard_last_owner is owner-only and still wired to % trigger(s).', v_trig;
END
$v$;
