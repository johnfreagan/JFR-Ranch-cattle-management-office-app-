-- ============================================================================
-- 2026-08-24 — Owner-only Users screen support.
--
-- Two things the app cannot do without help:
--
--   1. Show email and sign-in history. `authenticated` has no SELECT on
--      auth.users (verified: has_table_privilege = false), and PostgREST only
--      exposes the public schema. admin_list_users() bridges that, guarded so
--      it returns zero rows to anyone who is not an active owner.
--
--   2. Stop you locking yourself out. Nothing prevented demoting or
--      deactivating the last active owner, which would leave no one able to
--      administer users through the app at all. guard_last_owner() refuses.
--
-- Role changes and activate/deactivate need NO function — the existing
-- user_profiles UPDATE policy already allows owner, and the app writes through
-- it directly so RLS stays the single source of truth.
--
-- Idempotent: CREATE OR REPLACE + DROP TRIGGER IF EXISTS. Safe to re-run.
-- ============================================================================

BEGIN;

DO $guard$
BEGIN
    IF to_regprocedure('public.current_user_role()') IS NULL THEN
        RAISE EXCEPTION 'current_user_role() is missing; both objects below depend on it.';
    END IF;
    IF to_regclass('public.user_profiles') IS NULL THEN
        RAISE EXCEPTION 'user_profiles is missing.';
    END IF;
END
$guard$;

-- ---------------------------------------------------------------------------
-- 1. The roster. SECURITY DEFINER so it can reach auth.users, with the owner
--    check INSIDE the query: a non-owner gets an empty set, never an error and
--    never a row. Fails closed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_users()
RETURNS TABLE (
    id               uuid,
    full_name        text,
    role             text,
    is_active        boolean,
    email            text,
    email_confirmed  boolean,
    last_sign_in_at  timestamptz,
    created_at       timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_catalog'
AS $fn$
    SELECT p.id,
           p.full_name,
           p.role,
           p.is_active,
           u.email::text,
           u.email_confirmed_at IS NOT NULL,
           u.last_sign_in_at,
           p.created_at
    FROM public.user_profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE public.current_user_role() = 'owner'
    ORDER BY p.is_active DESC, p.role, p.full_name;
$fn$;

-- Signed-out callers must not be able to invoke it at all.
REVOKE ALL ON FUNCTION public.admin_list_users() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_users() FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_list_users() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Last-owner guard. Fires on any UPDATE that would take the final active
--    owner away — whether by role change or by deactivation.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_last_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $fn$
BEGIN
    IF (OLD.role = 'owner' AND OLD.is_active)
       AND (NEW.role <> 'owner' OR NEW.is_active = FALSE) THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.user_profiles
            WHERE role = 'owner' AND is_active AND id <> OLD.id
        ) THEN
            RAISE EXCEPTION
                'Refusing to remove the last active owner (%).', OLD.full_name
                USING HINT = 'Promote another user to owner first.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS trg_guard_last_owner ON public.user_profiles;
CREATE TRIGGER trg_guard_last_owner
    BEFORE UPDATE ON public.user_profiles
    FOR EACH ROW EXECUTE FUNCTION public.guard_last_owner();

-- ---------------------------------------------------------------------------
-- Verify.
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
    v_owners INT;
BEGIN
    IF to_regprocedure('public.admin_list_users()') IS NULL THEN
        RAISE EXCEPTION 'admin_list_users() was not created.';
    END IF;

    IF has_function_privilege('anon', 'public.admin_list_users()', 'EXECUTE') THEN
        RAISE EXCEPTION 'anon can still execute admin_list_users(). Revoke failed.';
    END IF;

    IF NOT has_function_privilege('authenticated', 'public.admin_list_users()', 'EXECUTE') THEN
        RAISE EXCEPTION 'authenticated cannot execute admin_list_users(). Grant failed.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'trg_guard_last_owner' AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION 'trg_guard_last_owner was not created.';
    END IF;

    SELECT count(*) INTO v_owners
    FROM public.user_profiles WHERE role = 'owner' AND is_active;

    IF v_owners = 0 THEN
        RAISE EXCEPTION 'No active owner exists. Fix that before relying on this screen.';
    END IF;

    RAISE NOTICE 'Users screen ready. Active owners: %.', v_owners;
END
$verify$;

COMMIT;
