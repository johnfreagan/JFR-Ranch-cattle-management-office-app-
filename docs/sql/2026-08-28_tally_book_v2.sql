-- =====================================================================
-- Tally Book v2 - reshaped around the artifact's data model
-- =====================================================================
-- 2026-08-28. Run AFTER docs/sql/2026-08-28_tally_book.sql, which it
-- supersedes. App: tally-book/ in this repo.
--
-- WHY THE FIRST SHAPE IS BEING REPLACED
--
-- The first cut modelled a bullet journal as one flat row per bullet
-- (tally_entries). The app John actually uses - the "JFR Tally Book"
-- artifact - carries a good deal more than that: sub-steps under an entry,
-- manual ordering, time of day, work handed to a named person and still
-- outstanding, collections, repeating rules, an unfiled inbox, month and
-- future logs, and numeric trackers like the rain gauge.
--
-- Flattening all of that would have meant rewriting the artifact's 114
-- functions to read flat rows instead of its nested state object - a
-- rewrite of the part that works, not a port of it. So the storage follows
-- the app's shape instead of fighting it.
--
--   tally_days  - ONE ROW PER DAY. { entries: [...], reflect: "..." }
--   tally_book  - the long tail, one row per key: colls, months, rules,
--                 people, inbox, trackers, track, settings, lots.
--
-- WHY PER DAY AND NOT ONE DOCUMENT
--
-- Conflict granularity, and it is the whole reason for the split. A single
-- document is last-writer-wins across the entire book: a phone that has
-- been out of signal all day syncs on the way home and silently overwrites
-- everything typed on the laptop. Per day, a sync only touches the days
-- that actually changed, and a day book is edited today - yesterday is
-- settled. The realistic collision is two devices on the same day, which
-- is small and visible, rather than the whole history.
--
-- WHAT IS BEING DROPPED
--
-- tally_entries (0 rows) and tally_projects (2 rows) both go. The two
-- project rows are the placeholder seed from this morning - literally
-- 'Set status here' - not John's data. The artifact has no project
-- register; it has collections, which are the same shape and already
-- built. A project register comes back as a collection in Lists, not as
-- a table.
--
-- Idempotent. Safe to re-run. Strip begin;/commit; if applying via the CLI.
-- =====================================================================

begin;

-- ─────────────────────────────────────────────────────────────
-- Out with the first shape
-- ─────────────────────────────────────────────────────────────
-- Guarded: refuse to drop tally_entries if anything real ever landed in
-- it. Today it is empty, but a re-run months from now should not quietly
-- destroy a book someone started using.
do $drop_old$
declare
    n integer;
begin
    if to_regclass('public.tally_entries') is not null then
        execute 'select count(*) from public.tally_entries' into n;
        if n > 0 then
            raise exception
                'public.tally_entries holds % row(s) - refusing to drop. Export them first.', n;
        end if;
        drop table public.tally_entries;
        raise notice 'Dropped public.tally_entries (was empty).';
    end if;

    -- tally_projects only ever held the two placeholder seeds. Anything
    -- beyond that means someone used it, so stop and let a human look.
    if to_regclass('public.tally_projects') is not null then
        execute $q$
            select count(*) from public.tally_projects
            where status_line is distinct from 'Set status here'
               or next_action is distinct from 'Set next action here'
               or blocked_on is not null
               or target_date is not null
        $q$ into n;
        if n > 0 then
            raise exception
                'public.tally_projects holds % edited row(s) - refusing to drop.', n;
        end if;
        drop table public.tally_projects;
        raise notice 'Dropped public.tally_projects (placeholder seeds only).';
    end if;
end
$drop_old$;

-- ─────────────────────────────────────────────────────────────
-- tally_days - one row per day
-- ─────────────────────────────────────────────────────────────
create table if not exists public.tally_days (
    user_id     uuid not null default auth.uid()
                     references auth.users (id) on delete cascade,
    day         date not null,
    doc         jsonb not null default '{}'::jsonb,
    updated_at  timestamptz not null default now(),
    primary key (user_id, day)
);

-- The sync pulls "everything of mine touched since I last looked", so this
-- is the access path that matters, not the primary key.
create index if not exists idx_tally_days_user_updated
    on public.tally_days (user_id, updated_at);

-- ─────────────────────────────────────────────────────────────
-- tally_book - the long tail, one row per key
-- ─────────────────────────────────────────────────────────────
-- The CHECK is deliberate. These keys are the app's own state fields, and
-- a typo writing 'collls' would create a row that syncs happily forever
-- and restores as nothing. Adding a key later is one ALTER.
create table if not exists public.tally_book (
    user_id     uuid not null default auth.uid()
                     references auth.users (id) on delete cascade,
    key         text not null check (key in (
                    'colls', 'months', 'rules', 'people', 'inbox',
                    'trackers', 'track', 'settings', 'lots')),
    doc         jsonb not null default 'null'::jsonb,
    updated_at  timestamptz not null default now(),
    primary key (user_id, key)
);

create index if not exists idx_tally_book_user_updated
    on public.tally_book (user_id, updated_at);

-- ─────────────────────────────────────────────────────────────
-- updated_at, reusing the function the first migration created
-- ─────────────────────────────────────────────────────────────
-- It is the row's own updated_at that decides which side of a sync wins,
-- so it must be set by the database and not by whichever client happens
-- to have the wrong clock.
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

drop trigger if exists trg_tally_days_updated_at on public.tally_days;
create trigger trg_tally_days_updated_at
    before update on public.tally_days
    for each row execute function public.tally_set_updated_at();

drop trigger if exists trg_tally_book_updated_at on public.tally_book;
create trigger trg_tally_book_updated_at
    before update on public.tally_book
    for each row execute function public.tally_set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- RLS - CLAUDE.md rules 4 and 5
-- ─────────────────────────────────────────────────────────────
alter table public.tally_days enable row level security;
alter table public.tally_book enable row level security;

drop policy if exists tally_days_own on public.tally_days;
drop policy if exists tally_book_own on public.tally_book;

create policy tally_days_own on public.tally_days
    for all to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

create policy tally_book_own on public.tally_book
    for all to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

revoke all on public.tally_days from public, anon;
revoke all on public.tally_book from public, anon;
grant select, insert, update, delete
    on public.tally_days, public.tally_book to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────
do $verify$
declare
    t text;
    n integer;
begin
    foreach t in array array['tally_days', 'tally_book']
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

        -- Without this the row's updated_at never moves on an UPDATE and
        -- the sync silently stops noticing that anything changed.
        if not exists (
            select 1 from pg_trigger tg
            where tg.tgrelid = ('public.' || t)::regclass
              and not tg.tgisinternal
        ) then
            raise exception 'public.% has no updated_at trigger.', t;
        end if;
    end loop;

    if exists (
        select 1 from pg_policies
        where schemaname = 'public'
          and tablename in ('tally_days', 'tally_book')
          and (qual is null or qual not like '%auth.uid()%')
    ) then
        raise exception 'A tally book policy is not scoped to auth.uid().';
    end if;

    if to_regclass('public.tally_entries') is not null
    or to_regclass('public.tally_projects') is not null then
        raise exception 'The v1 tables are still present - the drop block did not run.';
    end if;

    raise notice 'Tally Book v2: tally_days + tally_book, RLS on, owner-scoped, v1 tables gone. Verified.';
end
$verify$;

commit;
