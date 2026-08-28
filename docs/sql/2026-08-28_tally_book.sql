-- =====================================================================
-- Tally Book - daily bullet journal + project status register
-- =====================================================================
-- 2026-08-28. App lives at tally-book/ in this repo.
--
-- WHAT THIS BUILDS
--
--   tally_entries   - the rapid log. One row per bullet: task, event or
--                     note. A NULL type is an UNTRIAGED capture (the
--                     landing zone for Siri / Reminders / email), typed
--                     during morning triage.
--   tally_projects  - the project status register.
--
-- WHY THIS IS NOT THE MIGRATION THAT WAS HANDED OVER
--
-- The delivered draft ended with "no RLS - single-user app". That is true
-- of a standalone project and false of this one. These tables land in the
-- ranch database, whose `postgres` default ACL grants `authenticated` full
-- arwdDxtm on any new public table. No RLS means every crew cowboy can read
-- and write John's journal through PostgREST. It would also fail
-- supabase/migrations/20260821000300_rls_verify.sql on the next run and
-- break CLAUDE.md rule 5.
--
-- So: RLS on, scoped to the row's own user. `user_id` defaults to
-- auth.uid(), and the policy is USING (user_id = auth.uid()) both ways.
-- The tally book is personal; owner is a ranch role, not a shared diary.
-- Widening it later to all owners is a policy swap, not a rewrite.
--
-- THREE OTHER FIXES TO THE DRAFT
--
--   * `projects` -> `tally_projects`. Nothing collides today (verified
--     2026-08-28: no public.projects, no public.set_updated_at), but
--     `projects` is a broad name to squat in a ranch schema, and the
--     draft's `create or replace function set_updated_at()` would silently
--     rewrite any future one out from under its triggers.
--
--   * The draft's seed was `on conflict do nothing` against a table with no
--     unique constraint, which conflicts with nothing - re-running it
--     duplicates both project rows. There is a real unique index now.
--
--   * `entry_date` defaults to public.ranch_today(), not CURRENT_DATE. The
--     database runs UTC and the ranch does not; CURRENT_DATE rolls over at
--     7pm Central. Every read in this app is keyed on the day boundary, so
--     that is not cosmetic - it is the whole app pointing at tomorrow all
--     evening. Same trap lot_daily_head shipped with.
--
-- Idempotent. Safe to re-run. Strip begin;/commit; if applying via the CLI.
-- =====================================================================

begin;

-- ─────────────────────────────────────────────────────────────
-- tally_entries
-- ─────────────────────────────────────────────────────────────
create table if not exists public.tally_entries (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null default auth.uid()
                     references auth.users (id) on delete cascade,
    entry_date  date not null default public.ranch_today(),
    type        text check (type is null or type in ('task', 'event', 'note')),
    content     text not null,
    priority    boolean not null default false,
    status      text not null default 'open'
                     check (status in ('open', 'done', 'migrated', 'killed')),
    source      text not null default 'manual'
                     check (source in ('manual', 'email', 'reminders', 'siri')),
    created_at  timestamptz not null default now()
);

-- 'killed' is a STATUS, not a DELETE. The draft hard-deleted on kill, which
-- makes a mis-tap on a phone unrecoverable. A struck-through bullet is what
-- a paper tally book does anyway.
do $add_killed$
begin
    if exists (
        select 1 from pg_constraint
        where conrelid = 'public.tally_entries'::regclass
          and conname = 'tally_entries_status_check'
          and pg_get_constraintdef(oid) not like '%killed%'
    ) then
        alter table public.tally_entries drop constraint tally_entries_status_check;
        alter table public.tally_entries add constraint tally_entries_status_check
            check (status in ('open', 'done', 'migrated', 'killed'));
        raise notice 'tally_entries.status widened to include killed.';
    end if;
end
$add_killed$;

create index if not exists idx_tally_entries_user_date
    on public.tally_entries (user_id, entry_date);
create index if not exists idx_tally_entries_user_status
    on public.tally_entries (user_id, status);
create index if not exists idx_tally_entries_search
    on public.tally_entries using gin (to_tsvector('english', content));

-- ─────────────────────────────────────────────────────────────
-- tally_projects
-- ─────────────────────────────────────────────────────────────
create table if not exists public.tally_projects (
    id           uuid primary key default gen_random_uuid(),
    user_id      uuid not null default auth.uid()
                      references auth.users (id) on delete cascade,
    name         text not null,
    status_line  text not null default '',
    next_action  text not null default '',
    blocked_on   text,
    target_date  date,
    sort_order   integer not null default 0,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now()
);

create unique index if not exists uq_tally_projects_user_name
    on public.tally_projects (user_id, name);

create or replace function public.tally_set_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $fn$
begin
    new.updated_at = now();
    return new;
end
$fn$;

drop trigger if exists trg_tally_projects_updated_at on public.tally_projects;
create trigger trg_tally_projects_updated_at
    before update on public.tally_projects
    for each row execute function public.tally_set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- RLS - CLAUDE.md rules 4 and 5
-- ─────────────────────────────────────────────────────────────
alter table public.tally_entries  enable row level security;
alter table public.tally_projects enable row level security;

drop policy if exists tally_entries_own  on public.tally_entries;
drop policy if exists tally_projects_own on public.tally_projects;

-- One FOR ALL policy covers all four commands; rls_verify accepts cmd='ALL'.
-- WITH CHECK as well as USING, or a row could be inserted or updated INTO
-- someone else's book while remaining invisible to the one who wrote it.
create policy tally_entries_own on public.tally_entries
    for all to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

create policy tally_projects_own on public.tally_projects
    for all to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

-- Revoke from PUBLIC, not just anon - Postgres grants to PUBLIC by default
-- and `revoke ... from anon` alone silently does nothing (CLAUDE.md rule 4).
revoke all on public.tally_entries  from public, anon;
revoke all on public.tally_projects from public, anon;
grant select, insert, update, delete
    on public.tally_entries, public.tally_projects to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Seed the project register
-- ─────────────────────────────────────────────────────────────
-- auth.uid() is NULL in the SQL editor (it runs as postgres, not as a
-- logged-in user), so the owner has to be named explicitly or the seed rows
-- land unreachable behind their own policy.
do $seed$
declare
    v_uid uuid;
begin
    select id into v_uid from auth.users where email = 'johnfreagan@gmail.com';
    if v_uid is null then
        raise exception 'No auth.users row for johnfreagan@gmail.com - cannot seed the project register.';
    end if;

    insert into public.tally_projects (user_id, name, status_line, next_action, sort_order)
    values
        (v_uid, 'cattle-management-app', 'Set status here', 'Set next action here', 10),
        (v_uid, 'beta-cattle-tracker',   'Set status here', 'Set next action here', 20)
    on conflict (user_id, name) do nothing;
end
$seed$;

-- ─────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────
do $verify$
declare
    t text;
    n integer;
begin
    foreach t in array array['tally_entries', 'tally_projects']
    loop
        if to_regclass('public.' || t) is null then
            raise exception 'public.% was not created.', t;
        end if;

        if not (select relrowsecurity from pg_class
                where oid = ('public.' || t)::regclass) then
            raise exception 'public.% does not have RLS enabled.', t;
        end if;

        select count(*) into n from pg_policies
        where schemaname = 'public' and tablename = t;
        if n = 0 then
            raise exception 'public.% has RLS on and no policy - total lockout.', t;
        end if;

        if has_table_privilege('anon', 'public.' || t, 'SELECT')
        or has_table_privilege('anon', 'public.' || t, 'INSERT')
        or has_table_privilege('anon', 'public.' || t, 'UPDATE')
        or has_table_privilege('anon', 'public.' || t, 'DELETE') then
            raise exception 'anon holds a grant on public.% - CLAUDE.md rule 4.', t;
        end if;

        if not has_table_privilege('authenticated', 'public.' || t, 'SELECT') then
            raise exception 'authenticated cannot SELECT public.% - the app would see zero rows.', t;
        end if;
    end loop;

    -- The whole point: a signed-in user must not reach another user's rows.
    if exists (
        select 1 from pg_policies
        where schemaname = 'public'
          and tablename in ('tally_entries', 'tally_projects')
          and (qual is null or qual not like '%auth.uid()%')
    ) then
        raise exception 'A tally book policy is not scoped to auth.uid().';
    end if;

    select count(*) into n from public.tally_projects;
    raise notice 'Tally Book: 2 tables, RLS on, owner-scoped, % project rows. Verified.', n;
end
$verify$;

commit;
