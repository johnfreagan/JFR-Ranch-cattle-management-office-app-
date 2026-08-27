-- =====================================================================
-- RLS / grant verification - assert the project's security rules
-- =====================================================================
-- Contract documented in docs/security-model.md section 4. Written
-- 2026-08-27: the file had been referenced from CLAUDE.md, security-model.md
-- and four migrations since August, but was never actually committed. Every
-- instruction to "run rls_verify after any migration" was pointing at
-- nothing.
--
-- READ-ONLY. It changes no data and no grants. It raises one exception
-- listing EVERY finding, rather than dying on the first, so one run tells
-- you the whole story.
--
-- Run it after any migration that adds a table, view, or function.
--
-- NOTE: the SQL editor shows notices in its message pane, not the result
-- grid. If the roster at the end appears missing, look there.
-- =====================================================================

DO $verify$
DECLARE
    problems  text[] := '{}';
    notes     text[] := '{}';
    r         record;
    n         integer;
    n_txt     text;
    total     integer;
BEGIN
    -- ---------------------------------------------------------------
    -- 1. Every public table has RLS enabled.
    -- Extension-owned tables are skipped: they are not ours to police.
    -- ---------------------------------------------------------------
    FOR r IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n2 ON n2.oid = c.relnamespace
        WHERE n2.nspname = 'public' AND c.relkind = 'r'
          AND NOT c.relrowsecurity
          AND NOT EXISTS (SELECT 1 FROM pg_depend d
                          WHERE d.objid = c.oid AND d.deptype = 'e')
        ORDER BY c.relname
    LOOP
        problems := problems || ('RLS DISABLED: public.' || r.relname);
    END LOOP;

    -- ---------------------------------------------------------------
    -- 2. RLS enabled with zero policies is a total lockout, not security.
    -- ---------------------------------------------------------------
    FOR r IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n2 ON n2.oid = c.relnamespace
        WHERE n2.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity
          AND NOT EXISTS (SELECT 1 FROM pg_policies p
                          WHERE p.schemaname = 'public' AND p.tablename = c.relname)
        ORDER BY c.relname
    LOOP
        problems := problems || ('RLS ON BUT NO POLICIES (total lockout): public.' || r.relname);
    END LOOP;

    -- ---------------------------------------------------------------
    -- 3. Which commands each table covers - INFORMATIONAL, not a failure.
    --
    -- security-model.md originally specified this as an assertion ("all
    -- four commands covered"). That was wrong, and user_profiles proves
    -- it: it deliberately has no INSERT policy (profiles are created by
    -- handle_new_user(), a DEFINER trigger - a client inserting its own
    -- profile row is the signup-escalation hole) and no DELETE policy.
    --
    -- A MISSING POLICY DENIES. It is fail-closed. The dangerous states
    -- are RLS off (1), RLS on with no policies at all (2), and anon
    -- holding grants (4) - all of which fail hard above and below.
    -- A gap here is reported so it is visible, and nothing more.
    --
    -- A policy with cmd 'ALL' covers everything - the original design
    -- used one SELECT plus one FOR ALL write policy and that is sound.
    -- ---------------------------------------------------------------
    FOR r IN
        SELECT c.relname,
               bool_or(p.cmd IN ('ALL','SELECT')) AS has_select,
               bool_or(p.cmd IN ('ALL','INSERT')) AS has_insert,
               bool_or(p.cmd IN ('ALL','UPDATE')) AS has_update,
               bool_or(p.cmd IN ('ALL','DELETE')) AS has_delete
        FROM pg_class c
        JOIN pg_namespace n2 ON n2.oid = c.relnamespace
        JOIN pg_policies p ON p.schemaname = 'public' AND p.tablename = c.relname
        WHERE n2.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity
        GROUP BY c.relname
        HAVING NOT (bool_or(p.cmd IN ('ALL','SELECT')) AND bool_or(p.cmd IN ('ALL','INSERT'))
                AND bool_or(p.cmd IN ('ALL','UPDATE')) AND bool_or(p.cmd IN ('ALL','DELETE')))
        ORDER BY c.relname
    LOOP
        notes := notes || ('public.' || r.relname || ' has no policy for:'
            || CASE WHEN NOT r.has_select THEN ' SELECT' ELSE '' END
            || CASE WHEN NOT r.has_insert THEN ' INSERT' ELSE '' END
            || CASE WHEN NOT r.has_update THEN ' UPDATE' ELSE '' END
            || CASE WHEN NOT r.has_delete THEN ' DELETE' ELSE '' END);
    END LOOP;

    -- ---------------------------------------------------------------
    -- 4. anon holds no privilege on any table OR view.
    -- The publishable key is embedded in index.html and is therefore
    -- public. Anything anon can read, the internet can read.
    --
    -- has_table_privilege(), NOT information_schema.role_table_grants -
    -- that view only shows roles the CURRENT user belongs to, so on
    -- hosted Supabase it returns an empty set for anon while anon in
    -- fact holds full grants.
    -- ---------------------------------------------------------------
    FOR r IN
        SELECT c.relname, c.relkind,
               array_to_string(ARRAY(
                   SELECT priv FROM unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE']) AS priv
                   WHERE has_table_privilege('anon', c.oid, priv)
               ), ', ') AS privs
        FROM pg_class c
        JOIN pg_namespace n2 ON n2.oid = c.relnamespace
        WHERE n2.nspname = 'public' AND c.relkind IN ('r','v','m')
          AND NOT EXISTS (SELECT 1 FROM pg_depend d
                          WHERE d.objid = c.oid AND d.deptype = 'e')
        ORDER BY c.relname
    LOOP
        IF r.privs <> '' THEN
            problems := problems || ('anon CAN ' || r.privs || ' public.' || r.relname
                || ' (' || CASE r.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view'
                                          ELSE 'matview' END || ')');
        END IF;
    END LOOP;

    -- ---------------------------------------------------------------
    -- 5. No SECURITY DEFINER function is anon-callable.
    -- A DEFINER function bypasses RLS by design; anon reaching one is
    -- a direct hole. Remember Postgres grants EXECUTE to PUBLIC by
    -- default, so revoking from anon alone does nothing.
    -- ---------------------------------------------------------------
    FOR r IN
        SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p
        JOIN pg_namespace n2 ON n2.oid = p.pronamespace
        WHERE n2.nspname = 'public' AND p.prosecdef
          AND has_function_privilege('anon', p.oid, 'EXECUTE')
        ORDER BY p.proname
    LOOP
        problems := problems || ('anon CAN EXECUTE SECURITY DEFINER public.'
            || r.proname || '(' || r.args || ')');
    END LOOP;

    -- ---------------------------------------------------------------
    -- 6. No view bypasses RLS.
    -- Without security_invoker a view runs as its OWNER and ignores
    -- every policy on the tables underneath it.
    -- ---------------------------------------------------------------
    FOR r IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n2 ON n2.oid = c.relnamespace
        WHERE n2.nspname = 'public' AND c.relkind = 'v'
          AND NOT EXISTS (SELECT 1 FROM pg_depend d
                          WHERE d.objid = c.oid AND d.deptype = 'e')
          AND (c.reloptions IS NULL OR NOT (c.reloptions @> ARRAY['security_invoker=true']))
        ORDER BY c.relname
    LOOP
        problems := problems || ('VIEW BYPASSES RLS (no security_invoker): public.' || r.relname);
    END LOOP;

    -- ---------------------------------------------------------------
    -- 7. Every SECURITY DEFINER function pins search_path.
    -- Without it, a caller can point the function at their own schema
    -- and have it run their code with the definer's privileges.
    -- ---------------------------------------------------------------
    FOR r IN
        SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p
        JOIN pg_namespace n2 ON n2.oid = p.pronamespace
        WHERE n2.nspname = 'public' AND p.prosecdef
          AND NOT EXISTS (
              SELECT 1 FROM unnest(COALESCE(p.proconfig, '{}')) AS cfg
              WHERE cfg LIKE 'search\_path=%'
          )
        ORDER BY p.proname
    LOOP
        problems := problems || ('SECURITY DEFINER WITHOUT PINNED search_path: public.'
            || r.proname || '(' || r.args || ')');
    END LOOP;

    -- ---------------------------------------------------------------
    -- 8. At least one active user, or nobody can get in.
    -- ---------------------------------------------------------------
    IF to_regclass('public.user_profiles') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FROM public.user_profiles WHERE is_active' INTO n;
        IF n = 0 THEN
            problems := problems || 'NO ACTIVE USERS - current_user_role() returns NULL for everyone and every policy denies';
        END IF;
    ELSE
        problems := problems || 'public.user_profiles is missing - the whole role model depends on it';
    END IF;

    -- ---------------------------------------------------------------
    -- 9. The roster. Printed whether or not anything failed.
    -- ---------------------------------------------------------------
    IF array_length(notes, 1) IS NOT NULL THEN
        RAISE NOTICE '--- commands with no policy (fail-closed, not findings) --';
        FOREACH n_txt IN ARRAY notes LOOP
            RAISE NOTICE '  %', n_txt;
        END LOOP;
    END IF;

    RAISE NOTICE '--- policy coverage -------------------------------------';
    total := 0;
    FOR r IN
        SELECT c.relname,
               (SELECT count(*) FROM pg_policies p
                WHERE p.schemaname='public' AND p.tablename=c.relname) AS policies,
               c.relrowsecurity AS rls
        FROM pg_class c
        JOIN pg_namespace n2 ON n2.oid = c.relnamespace
        WHERE n2.nspname='public' AND c.relkind='r'
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=c.oid AND d.deptype='e')
        ORDER BY c.relname
    LOOP
        total := total + 1;
        RAISE NOTICE '  % : % policies, RLS %', rpad(r.relname, 32), r.policies,
            CASE WHEN r.rls THEN 'on' ELSE 'OFF' END;
    END LOOP;
    RAISE NOTICE '  (% tables)', total;

    RAISE NOTICE '--- views ------------------------------------------------';
    FOR r IN
        SELECT c.relname,
               COALESCE(c.reloptions @> ARRAY['security_invoker=true'], false) AS inv
        FROM pg_class c
        JOIN pg_namespace n2 ON n2.oid = c.relnamespace
        WHERE n2.nspname='public' AND c.relkind='v'
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=c.oid AND d.deptype='e')
        ORDER BY c.relname
    LOOP
        RAISE NOTICE '  % : security_invoker %', rpad(r.relname, 32),
            CASE WHEN r.inv THEN 'yes' ELSE 'NO' END;
    END LOOP;

    RAISE NOTICE '--- SECURITY DEFINER functions ---------------------------';
    FOR r IN
        SELECT p.proname,
               EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig,'{}')) AS cfg
                       WHERE cfg LIKE 'search\_path=%') AS pinned
        FROM pg_proc p
        JOIN pg_namespace n2 ON n2.oid = p.pronamespace
        WHERE n2.nspname='public' AND p.prosecdef
        ORDER BY p.proname
    LOOP
        RAISE NOTICE '  % : search_path %', rpad(r.proname, 32),
            CASE WHEN r.pinned THEN 'pinned' ELSE 'NOT PINNED' END;
    END LOOP;

    IF to_regclass('public.user_profiles') IS NOT NULL THEN
        RAISE NOTICE '--- users ------------------------------------------------';
        FOR r IN EXECUTE
            'SELECT COALESCE(full_name, id::text) AS who, role, is_active
               FROM public.user_profiles ORDER BY role, 1'
        LOOP
            RAISE NOTICE '  % : % %', rpad(r.who, 32), rpad(r.role, 8),
                CASE WHEN r.is_active THEN 'active' ELSE 'INACTIVE' END;
        END LOOP;
    END IF;

    -- ---------------------------------------------------------------
    -- Verdict
    -- ---------------------------------------------------------------
    IF array_length(problems, 1) IS NULL THEN
        RAISE NOTICE '==========================================================';
        RAISE NOTICE 'rls_verify: PASS - all 7 assertions hold.';
        RAISE NOTICE '==========================================================';
    ELSE
        RAISE EXCEPTION E'rls_verify FAILED with % finding(s):\n  - %',
            array_length(problems, 1), array_to_string(problems, E'\n  - ');
    END IF;
END
$verify$;
