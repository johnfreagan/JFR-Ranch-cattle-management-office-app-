-- =====================================================================
-- RLS roster - the same picture rls_verify prints, as ROWS
-- =====================================================================
-- The Supabase dashboard SQL editor does not surface RAISE NOTICE, so
-- rls_verify's roster is invisible there on a pass. This returns it as a
-- result set instead. Read-only.
--
-- Anything with *** stars *** is a finding. Everything else is fine.
-- =====================================================================
SELECT * FROM (
    SELECT 1 AS grp, 'TABLE' AS kind, c.relname::text AS name,
           CASE WHEN NOT c.relrowsecurity THEN '*** RLS OFF ***'
                WHEN (SELECT count(*) FROM pg_policies p
                       WHERE p.schemaname='public' AND p.tablename=c.relname) = 0
                     THEN '*** RLS ON, NO POLICIES ***'
                ELSE (SELECT count(*)::text FROM pg_policies p
                       WHERE p.schemaname='public' AND p.tablename=c.relname) || ' policies'
           END AS status,
           CASE WHEN has_table_privilege('anon', c.oid, 'SELECT')
                THEN '*** anon CAN READ ***' ELSE 'anon: no' END AS anon
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname='public' AND c.relkind='r'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=c.oid AND d.deptype='e')

    UNION ALL
    SELECT 2, 'VIEW', c.relname::text,
           CASE WHEN COALESCE(c.reloptions @> ARRAY['security_invoker=true'], false)
                THEN 'security_invoker yes' ELSE '*** BYPASSES RLS ***' END,
           CASE WHEN has_table_privilege('anon', c.oid, 'SELECT')
                THEN '*** anon CAN READ ***' ELSE 'anon: no' END
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname='public' AND c.relkind='v'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=c.oid AND d.deptype='e')

    UNION ALL
    SELECT 3, 'DEFINER FN',
           (p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')')::text,
           CASE WHEN EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig,'{}')) cfg
                              WHERE cfg LIKE 'search\_path=%')
                THEN 'search_path pinned' ELSE '*** NOT PINNED ***' END,
           CASE WHEN has_function_privilege('anon', p.oid, 'EXECUTE')
                THEN '*** anon CAN EXECUTE ***' ELSE 'anon: no' END
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname='public' AND p.prosecdef

    UNION ALL
    SELECT 4, 'USER', COALESCE(u.full_name, u.id::text)::text,
           u.role::text,
           CASE WHEN u.is_active THEN 'active' ELSE '*** INACTIVE ***' END
      FROM public.user_profiles u
) x
ORDER BY grp, name;
