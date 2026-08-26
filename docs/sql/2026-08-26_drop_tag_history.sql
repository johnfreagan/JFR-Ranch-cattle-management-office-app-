-- =====================================================================
-- Drop public.tag_history — the last object in the API schema reading
-- auth.users
-- =====================================================================
-- 2026-08-26. Applied via the Supabase SQL editor; this file is the
-- record of what was run, not the delivery mechanism.
--
-- Supabase's linter raised auth_users_exposed against public.tag_history.
-- The view resolved a doctoring event's recorder to a person by reaching
-- into auth.users for their EMAIL and labelling it recorded_by_name:
--
--     COALESCE((SELECT u.email FROM auth.users u
--               WHERE u.id = e.recorded_by_user_id), '(unknown)')
--               AS recorded_by_name
--
-- It was NOT leaking when found, and the reason matters. The view carried
-- security_invoker = true, so its base-table checks ran as the caller, and
-- neither anon nor authenticated holds SELECT on auth.users — a signed-in
-- user querying it got 42501, not a roster of email addresses. Before the
-- August hardening, when views ran as their owner, this same view would
-- have handed every user's email to anyone who asked. That is the shape
-- the linter warns about, and it is one dropped reloption away from being
-- true again.
--
-- The view was also entirely orphaned: no reference in index.html, none in
-- field-app/app.js, no dependent views, no function body mentioning it.
-- Dropping it was chosen over repointing it at user_profiles.full_name,
-- because user_profiles_select is "own row OR owner" — under RLS an office
-- or crew user would have seen NULL for everybody else's name anyway. If a
-- tag-history view is wanted later, build it then against a name source
-- that non-owners can actually read.
--
-- Idempotent. Refuses to drop anything that is not a view, or that has
-- dependents. Prints two notices and one verification row.
--
-- Result when applied 2026-08-26:
--   NOTICE: tag_history: dropped.
--   NOTICE: OK: no view in public or graphql_public reads auth.users.
--   28 | 0 | 0 | 11 | 0 | 0
-- Public views went 12 -> 11.
-- =====================================================================

DO $do$
DECLARE
  v_kind "char";
  v_deps int;
BEGIN
  SELECT c.relkind INTO v_kind
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relname = 'tag_history';

  IF v_kind IS NULL THEN
    RAISE NOTICE 'tag_history: already gone, nothing to do.';
  ELSIF v_kind <> 'v' THEN
    RAISE EXCEPTION 'public.tag_history is relkind %, not a view. Refusing to drop.', v_kind;
  ELSE
    SELECT count(*) INTO v_deps
    FROM pg_depend d
    JOIN pg_rewrite rw ON rw.oid = d.objid
    JOIN pg_class dep ON dep.oid = rw.ev_class
    WHERE d.refobjid = 'public.tag_history'::regclass
      AND dep.relname <> 'tag_history';

    IF v_deps > 0 THEN
      RAISE EXCEPTION 'tag_history has % dependent object(s). Refusing to drop.', v_deps;
    END IF;

    DROP VIEW public.tag_history;
    RAISE NOTICE 'tag_history: dropped.';
  END IF;
END
$do$;

-- Assertion: nothing in an API-exposed schema reads auth.users any more.
DO $do$
DECLARE v_left text;
BEGIN
  SELECT string_agg(c.relname, ', ') INTO v_left
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname IN ('public','graphql_public')
    AND c.relkind IN ('v','m')
    AND pg_get_viewdef(c.oid) ILIKE '%auth.users%';

  IF v_left IS NOT NULL THEN
    RAISE EXCEPTION 'Still exposing auth.users through: %', v_left;
  END IF;
  RAISE NOTICE 'OK: no view in public or graphql_public reads auth.users.';
END
$do$;

-- Re-assert CLAUDE.md access-control rules 3, 4 and 5 across the schema.
-- Expected: 28 | 0 | 0 | 11 | 0 | 0
SELECT
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind='r') AS tables_total,
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind='r' AND NOT c.relrowsecurity) AS tables_without_rls,
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity
       AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid=c.oid)) AS rls_on_no_policy,
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind='v') AS views_total,
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind='v'
       AND coalesce((SELECT option_value FROM pg_options_to_table(c.reloptions)
                     WHERE option_name='security_invoker'),'unset') <> 'true') AS views_not_invoker,
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind IN ('r','v','m')
       AND has_table_privilege('anon', c.oid,'SELECT')) AS anon_readable;
