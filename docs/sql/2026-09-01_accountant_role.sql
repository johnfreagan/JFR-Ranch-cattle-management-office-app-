-- =====================================================================
-- Accountant role: reads everything, writes nothing.
-- 2026-09-01
--
-- WHY PREDICATES INSTEAD OF ADDING 'accountant' TO 48 ARRAYS
-- A read-only role is not another rung on the owner > office > crew
-- ladder; it is a second axis. John has said this is unlikely to be the
-- last one (a `consultant` layer is deferred, not dropped). Naming the
-- two read sets once means the next role is one line in one function
-- instead of another 48-policy migration.
--
-- WRITE POLICIES ARE NOT TOUCHED. Deliberate. Every write policy is a
-- positive allow-list naming owner and office explicitly, so a role that
-- is not named cannot write -- verified 2026-09-01, there is not one
-- negative test ("anyone who isn't crew") anywhere in the schema.
-- Rewriting them would put the dangerous half of the security layer in
-- the blast radius for no gain. The worst outcome of a mistake in here
-- is someone sees too little and says so; that is not true of writes.
--
-- storage.objects.lot_attachments_read IS included. Without it an
-- accountant reads every invoice row while every attached scan 404s.
--
-- Idempotent. Safe to re-run. No begin/commit: the Supabase SQL editor
-- swallows them and can report success without applying anything. Each
-- statement below is atomic on its own and every one is guarded.
--
-- Run supabase/migrations/20260821000300_rls_verify.sql afterwards.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. The two read predicates.
--    INVOKER (they only wrap current_user_role(), which is the DEFINER
--    gate) with a pinned search_path. coalesce() because a NULL role
--    must be a hard false, not a NULL that some future caller treats
--    as unknown -- RLS denies on NULL, but nothing else promises to.
-- ---------------------------------------------------------------------

create or replace function public.can_read_operational()
returns boolean
language sql
stable
set search_path = public
as $fn$
    select coalesce(
        public.current_user_role() = any (array['owner','office','crew','accountant']),
        false
    );
$fn$;

comment on function public.can_read_operational() is
    'Roles that may READ operational data (lots, weights, tags, doctoring, '
    'pastures, movements, receipts, protocols). Add a new read-only role '
    'here, never to a write policy.';

create or replace function public.can_read_books()
returns boolean
language sql
stable
set search_path = public
as $fn$
    select coalesce(
        public.current_user_role() = any (array['owner','office','accountant']),
        false
    );
$fn$;

comment on function public.can_read_books() is
    'Roles that may READ money (invoices, sales, shipments, feed, vendors, '
    'budgets, supply). Excludes crew by design -- 2026-08-26, John: '
    '"crew cannot see any dollars".';

-- Rule 4: revoke from PUBLIC, not just anon. Postgres grants function
-- EXECUTE to PUBLIC by default, so revoking from anon alone does nothing.
revoke all on function public.can_read_operational() from public;
revoke all on function public.can_read_books()       from public;
grant execute on function public.can_read_operational() to authenticated;
grant execute on function public.can_read_books()       to authenticated;


-- ---------------------------------------------------------------------
-- 2. Let the role exist.
-- ---------------------------------------------------------------------

do $do$
begin
    if exists (
        select 1 from pg_constraint
        where conrelid = 'public.user_profiles'::regclass
          and conname  = 'user_profiles_role_check'
          and pg_get_constraintdef(oid) like '%accountant%'
    ) then
        raise notice 'user_profiles_role_check already allows accountant - skipped';
    else
        alter table public.user_profiles
            drop constraint if exists user_profiles_role_check;
        alter table public.user_profiles
            add constraint user_profiles_role_check
            check (role = any (array['owner','office','crew','accountant']));
        raise notice 'user_profiles_role_check now allows accountant';
    end if;
end
$do$;


-- ---------------------------------------------------------------------
-- 3. Point the SELECT policies at the predicates.
--    Matched on the EXPRESSION, not on a hand-typed list of table and
--    policy names -- policy naming is inconsistent (dra_select,
--    lpa_select, load_out_dests_select), and a typo in a name list
--    silently skips a table. Anything that does not match one of the two
--    known shapes is left strictly alone and reported at the end.
-- ---------------------------------------------------------------------

do $do$
declare
    op_expr constant text :=
        '(current_user_role() = ANY (ARRAY[''owner''::text, ''office''::text, ''crew''::text]))';
    bk_expr constant text :=
        '(current_user_role() = ANY (ARRAY[''owner''::text, ''office''::text]))';
    row_rec record;
    n_op integer;
    n_bk integer;
    n_other integer := 0;
begin
    for row_rec in
        select c.relname as tbl,
               p.polname as pol,
               pg_get_expr(p.polqual, p.polrelid) as q
        from pg_policy p
        join pg_class     c  on c.oid  = p.polrelid
        join pg_namespace ns on ns.oid = c.relnamespace
        where ns.nspname = 'public'
          and p.polcmd = 'r'
        order by c.relname
    loop
        if row_rec.q = op_expr then
            execute format(
                'alter policy %I on public.%I using (public.can_read_operational())',
                row_rec.pol, row_rec.tbl);
        elsif row_rec.q = bk_expr then
            execute format(
                'alter policy %I on public.%I using (public.can_read_books())',
                row_rec.pol, row_rec.tbl);
        elsif row_rec.q like '%can_read_operational%'
           or row_rec.q like '%can_read_books%' then
            null;  -- already converted by an earlier run
        else
            n_other := n_other + 1;
            raise notice 'left alone: %.% -> %', row_rec.tbl, row_rec.pol, row_rec.q;
        end if;
    end loop;

    select count(*) into n_op
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and p.polcmd = 'r'
      and pg_get_expr(p.polqual, p.polrelid) like '%can_read_operational%';

    select count(*) into n_bk
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and p.polcmd = 'r'
      and pg_get_expr(p.polqual, p.polrelid) like '%can_read_books%';

    -- Audited 2026-09-01: 22 operational, 26 books, 2 deliberately other
    -- (user_profiles own-row-or-owner, ranch_settings any-active-role).
    if n_op <> 22 then
        raise exception 'expected 22 operational SELECT policies, found %', n_op;
    end if;
    if n_bk <> 26 then
        raise exception 'expected 26 books SELECT policies, found %', n_bk;
    end if;
    if n_other <> 2 then
        raise exception 'expected 2 hand-written SELECT policies, found %', n_other;
    end if;

    raise notice 'SELECT policies: 22 operational, 26 books, 2 left alone';
end
$do$;


-- ---------------------------------------------------------------------
-- 4. The invoice scans. Without this an accountant reads every invoice
--    row and every attached PDF 404s.
-- ---------------------------------------------------------------------

do $do$
declare
    cur text;
begin
    select pg_get_expr(p.polqual, p.polrelid) into cur
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'storage' and c.relname = 'objects'
      and p.polname = 'lot_attachments_read';

    if cur is null then
        raise exception 'storage policy lot_attachments_read not found';
    elsif cur like '%can_read_operational%' then
        raise notice 'lot_attachments_read already converted - skipped';
    else
        alter policy lot_attachments_read on storage.objects
            using (bucket_id = 'lot-attachments' and public.can_read_operational());
        raise notice 'lot_attachments_read now uses can_read_operational()';
    end if;
end
$do$;


-- ---------------------------------------------------------------------
-- 5. Verify. Raises if any of it is wrong.
-- ---------------------------------------------------------------------

do $do$
declare
    bad integer;
begin
    -- (a) the read predicates and the word accountant must appear in
    --     NO write policy anywhere, in either schema.
    select count(*) into bad
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname in ('public','storage')
      and p.polcmd <> 'r'
      and (coalesce(pg_get_expr(p.polqual,     p.polrelid), '') ~ 'accountant|can_read_'
        or coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') ~ 'accountant|can_read_');
    if bad > 0 then
        raise exception 'accountant reached % write policy/policies - migration is unsafe', bad;
    end if;

    -- (b) predicates must be INVOKER with a pinned search_path (rule 6).
    select count(*) into bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('can_read_operational','can_read_books')
      and (p.prosecdef
        or p.proconfig is null
        or not (p.proconfig::text like '%search_path=public%'));
    if bad > 0 then
        raise exception '% predicate(s) are SECURITY DEFINER or lack a pinned search_path', bad;
    end if;

    -- (c) nothing granted to anon (rule 4). anon inherits PUBLIC, so
    --     this catches a stray PUBLIC grant too.
    select count(*) into bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('can_read_operational','can_read_books')
      and has_function_privilege('anon', p.oid, 'EXECUTE');
    if bad > 0 then
        raise exception '% predicate(s) are EXECUTE-able by anon', bad;
    end if;

    -- (d) the role is actually accepted.
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.user_profiles'::regclass
          and conname  = 'user_profiles_role_check'
          and pg_get_constraintdef(oid) like '%accountant%'
    ) then
        raise exception 'user_profiles still rejects accountant';
    end if;

    raise notice 'VERIFIED: accountant reads 48 tables + attachments, writes nothing';
end
$do$;
