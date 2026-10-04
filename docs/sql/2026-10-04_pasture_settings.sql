-- 2026-10-04  Pasture head-days, build step 1: the settings.
--
-- Design: docs/pasture-headdays-phase-design.md (D1-D48, build order D47).
-- Step 1 is settings only. Nothing here counts a head-day or charges a dollar;
-- step 3 derives head-day buckets from these rows, step 5 charges them.
--
--   A. ranch_settings.pasture_go_live          D31, D48: Nov 1, 2026.
--   B. pasture_label_history                   D6, D8, D42, D49: dated label and
--                                              farmed/maintained acres per pasture.
--      pasture_label_periods (view)            the same rows with an end date.
--   C. pasture_season_settings                 D7, D9, D20, D42: season start dates
--                                              and the stocking rate per label/season.
--   D. lots.no_precon                          D43: "No precon phase (arrived preconditioned)".
--   E. nonfeed_rates                           D34: the ranch non-feed rate, dated.
--
-- Acres (D49, narrowing D45): ONE acre number per pasture, farmed/maintained
-- acres (oat ground on crop pastures; maintained ground on grass). It is what
-- pasture cost is allocated by and what capacity is built on (acres x stocking
-- rate), so it is dated on the same row as the label, never typed over
-- pastures.usable_acres. Total, ranch and grazable acres are on the Later list.
-- A pasture with no acres still counts head-days later.
--
-- Rules carried from CLAUDE.md:
--   * Never edit a rate in place. A label, season or non-feed rate change is a
--     NEW dated row; a row whose date has passed is frozen by a trigger. The one
--     exception is filling a stocking rate that was never set (NULL -> value),
--     because the seasons below are seeded before John has his numbers.
--   * RLS on every new table, SELECT/INSERT/UPDATE policies, no removal policy
--     (a dated history is corrected by a newer row). Labels and seasons are
--     operational (crew will see head-days and utilization); the non-feed rate
--     is dollars, so it reads through can_read_books() and crew never sees it.
--   * Views are security_invoker. Functions are INVOKER with a pinned
--     search_path; EXECUTE revoked from PUBLIC and anon.
--   * Days use ranch_today(), never CURRENT_DATE.
--
-- Connector note (docs/feed-pb-import.md, 2026-10-03): the Supabase connector
-- stalls on DROP and DELETE statements, so this file has none. Policies are
-- created inside guarded DO blocks instead of being replaced.
--
-- Idempotent. For apply_migration or the CLI, strip the begin;/commit; lines.
begin;

-- =====================================================================
-- A. Go-live date (D48). Head-days, buckets, charges and feed-by-pasture
-- start here. If build steps 1-3 ship after Nov 1, the office moves it to the
-- ship day (one UPDATE of this column, which it may already make).
-- =====================================================================
alter table public.ranch_settings add column if not exists pasture_go_live date;
update public.ranch_settings set pasture_go_live = date '2026-11-01', updated_at = now()
 where pasture_go_live is null;

-- =====================================================================
-- B. Pasture labels and acres, dated (D6, D8, D42, D49).
-- crop = Crop, grass = Grass pasture, growyard = Growyard, other = Other.
-- maintained_acres = farmed/maintained acres; NULL = not known yet ("no
-- acres" on screen, never zero). A row holds from effective_from until the
-- next row for the same pasture. A change to either the label or the acres is
-- a new row carrying both. Head-days follow the label day by day.
-- =====================================================================
create table if not exists public.pasture_label_history (
    id              uuid primary key default gen_random_uuid(),
    pasture_id      uuid not null references public.pastures(id),   -- pastures retire (is_active), they are never removed
    label           text not null,
    maintained_acres numeric,
    effective_from  date not null,
    notes           text,
    created_at      timestamptz not null default now(),
    created_by      uuid default auth.uid(),
    constraint pasture_label_history_label_check
        check (label in ('crop', 'grass', 'growyard', 'other')),
    constraint pasture_label_history_acres_check check (maintained_acres is null or maintained_acres >= 0),
    constraint pasture_label_history_one_per_day unique (pasture_id, effective_from)
);
-- for a database where an earlier draft of this table was created
alter table public.pasture_label_history add column if not exists maintained_acres numeric;
do $$
begin
    if not exists (select 1 from pg_constraint where conrelid = 'public.pasture_label_history'::regclass
                    and conname = 'pasture_label_history_acres_check') then
        alter table public.pasture_label_history add constraint pasture_label_history_acres_check
            check (maintained_acres is null or maintained_acres >= 0);
    end if;
end $$;
create index if not exists pasture_label_history_pasture_idx
    on public.pasture_label_history (pasture_id, effective_from desc);

-- A row whose day has come is a fact about the land and stays as written.
-- A future-dated row may be corrected (typed wrong before it took effect).
create or replace function public.pasture_label_history_guard()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
    if old.effective_from <= public.ranch_today()
       and (new.label is distinct from old.label
            or new.maintained_acres is distinct from old.maintained_acres
            or new.effective_from is distinct from old.effective_from
            or new.pasture_id is distinct from old.pasture_id) then
        raise exception 'pasture label: the % label and % acres took effect on % and cannot be changed. Add a new dated row instead.',
            old.label, coalesce(old.maintained_acres::text, 'no'), old.effective_from;
    end if;
    return new;
end;
$$;

do $$
begin
    if not exists (select 1 from pg_trigger where tgrelid = 'public.pasture_label_history'::regclass
                    and tgname = 'pasture_label_history_guard') then
        create trigger pasture_label_history_guard
            before update on public.pasture_label_history
            for each row execute function public.pasture_label_history_guard();
    end if;
end $$;

-- Each label row with the day it ends (the day before the next row), so step 3
-- and the grid can ask "what was this pasture on day d" with one range test.
create or replace view public.pasture_label_periods
with (security_invoker = true) as
select h.id,
       h.pasture_id,
       h.label,
       h.effective_from,
       (lead(h.effective_from) over (partition by h.pasture_id order by h.effective_from) - 1) as effective_to,
       h.notes,
       h.created_at,
       h.created_by,
       h.maintained_acres
  from public.pasture_label_history h;

-- =====================================================================
-- C. Seasons and stocking rates (D7, D9, D20, D42).
-- Only Crop and Grass have seasons; Growyard and Other have none (D21).
-- Each label has two seasons. A row stores the season's START (month, day);
-- a season ends the day before the other season of the same label starts, so
-- the two always tile the year with no gap and no overlap.
-- stocking_rate is head per farmed/maintained acre for that label and season
-- (D20, D49: capacity = maintained_acres x rate x days);
-- NULL means not set yet and shows as "not set", never as zero.
-- A change is a NEW row whose effective_from IS a start of that season
-- (D42: season dates change only from a season start), never an edit.
-- =====================================================================
create table if not exists public.pasture_season_settings (
    id              uuid primary key default gen_random_uuid(),
    label           text not null,
    season          text not null,
    effective_from  date not null,
    start_month     smallint not null,
    start_day       smallint not null,
    stocking_rate   numeric,
    notes           text,
    created_at      timestamptz not null default now(),
    created_by      uuid default auth.uid(),
    constraint pasture_season_settings_label_check  check (label in ('crop', 'grass')),
    constraint pasture_season_settings_season_check check (season in ('winter', 'summer')),
    constraint pasture_season_settings_start_check
        check (start_month between 1 and 12 and start_day between 1 and 31
               and make_date(2001, start_month, start_day) is not null),
    constraint pasture_season_settings_rate_check   check (stocking_rate is null or stocking_rate > 0),
    constraint pasture_season_settings_from_is_start
        check (extract(month from effective_from) = start_month
               and extract(day from effective_from) = start_day),
    constraint pasture_season_settings_one_per_day unique (label, season, effective_from)
);
create index if not exists pasture_season_settings_lookup_idx
    on public.pasture_season_settings (label, season, effective_from desc);

-- Forward only (D9, D42).
--   INSERT: on or after today, so past days keep the season they were sorted
--           into. Before go-live nothing has been sorted yet, so the seed rows
--           and John's first numbers may carry a season start already passed.
--   UPDATE: a row not yet in effect may be corrected freely. A row in effect
--           keeps its dates; its stocking rate may only be FILLED (NULL to a
--           number), never changed - a new season start takes a new row.
create or replace function public.pasture_season_settings_guard()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_go_live date;
begin
    select pasture_go_live into v_go_live from public.ranch_settings limit 1;
    if tg_op = 'INSERT' then
        if new.effective_from < public.ranch_today()
           and v_go_live is not null and public.ranch_today() >= v_go_live then
            raise exception 'season settings: % is in the past. Season dates and stocking rates change forward only, from a season start on or after today.',
                new.effective_from;
        end if;
        return new;
    end if;
    -- UPDATE
    if old.effective_from <= public.ranch_today() then
        if new.label is distinct from old.label or new.season is distinct from old.season
           or new.effective_from is distinct from old.effective_from
           or new.start_month is distinct from old.start_month or new.start_day is distinct from old.start_day then
            raise exception 'season settings: the % % season dated % is already in effect; its dates cannot change. Add a new row from the next season start.',
                old.label, old.season, old.effective_from;
        end if;
        if old.stocking_rate is not null and new.stocking_rate is distinct from old.stocking_rate then
            raise exception 'season settings: the % % stocking rate dated % is already in effect (% head/acre). Add a new row from the next season start.',
                old.label, old.season, old.effective_from, old.stocking_rate;
        end if;
    end if;
    return new;
end;
$$;

do $$
begin
    if not exists (select 1 from pg_trigger where tgrelid = 'public.pasture_season_settings'::regclass
                    and tgname = 'pasture_season_settings_guard') then
        create trigger pasture_season_settings_guard
            before insert or update on public.pasture_season_settings
            for each row execute function public.pasture_season_settings_guard();
    end if;
end $$;

-- D7, John's "best guess for now": Crop winter Sep 1 - May 15, summer May 16 -
-- Aug 31; Grass winter Nov 1 - Apr 1, summer Apr 2 - Oct 31. Each seed row is
-- dated at the most recent start of its season on or before go-live, so every
-- day from go-live on resolves to a row. Stocking rates are John's numbers,
-- typed on the settings screen; left NULL here.
insert into public.pasture_season_settings (label, season, effective_from, start_month, start_day, notes)
values ('crop',  'winter', date '2026-09-01',  9,  1, 'D7 seed 2026-10-04: Sep 1 - May 15 (oats)'),
       ('crop',  'summer', date '2026-05-16',  5, 16, 'D7 seed 2026-10-04: May 16 - Aug 31 (cover crop, residue, volunteer)'),
       ('grass', 'winter', date '2026-11-01', 11,  1, 'D7 seed 2026-10-04: Nov 1 - Apr 1'),
       ('grass', 'summer', date '2026-04-02',  4,  2, 'D7 seed 2026-10-04: Apr 2 - Oct 31')
on conflict (label, season, effective_from) do nothing;

-- =====================================================================
-- D. "No precon phase (arrived preconditioned)" (D43). Off by default. When
-- on, step 3 sends the lot's head-days straight to the pasture buckets from
-- day 1 and leaves it out of precon baselines. The feed pen is always treated
-- this way by rule (D29), so it needs no flag.
-- =====================================================================
alter table public.lots add column if not exists no_precon boolean not null default false;

-- =====================================================================
-- E. Non-feed rate, dated (D34).
-- Replaces ranch_settings.nonfeed_cog_per_day as the ranch default. The
-- closeout charges each head-day after feed_direct_from at the rate in force
-- that day. The existing $0.50 placeholder (pasture included) is carried in
-- as the row from 2026-09-01; John adds the rate WITHOUT pasture from go-live
-- (includes_pasture = false), after which pasture reaches lots only through
-- the head-day charge (step 5). A lot's own assumed_nonfeed_cog_per_day still
-- overrides the ranch rate (no lot sets one today).
-- ranch_settings.nonfeed_cog_per_day / _note stay as they are, for audit; the
-- app stops reading them.
-- =====================================================================
create table if not exists public.nonfeed_rates (
    id                  uuid primary key default gen_random_uuid(),
    effective_from      date not null,
    rate_per_head_day   numeric not null,
    includes_pasture    boolean not null,
    is_placeholder      boolean not null default false,
    notes               text,
    created_at          timestamptz not null default now(),
    created_by          uuid default auth.uid(),
    constraint nonfeed_rates_rate_check check (rate_per_head_day >= 0),
    constraint nonfeed_rates_one_per_day unique (effective_from)
);

-- Never edit a rate in place. A rate in effect is frozen (notes may be
-- appended); a future one may be corrected. A new row may not be back-dated
-- before today, or a closeout already read would move.
create or replace function public.nonfeed_rates_guard()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
    if tg_op = 'INSERT' then
        if new.effective_from < public.ranch_today() then
            raise exception 'non-feed rate: % is in the past. A rate starts today or later; past days keep the rate they were charged.',
                new.effective_from;
        end if;
        return new;
    end if;
    if old.effective_from <= public.ranch_today()
       and (new.effective_from is distinct from old.effective_from
            or new.rate_per_head_day is distinct from old.rate_per_head_day
            or new.includes_pasture is distinct from old.includes_pasture
            or new.is_placeholder is distinct from old.is_placeholder) then
        raise exception 'non-feed rate: the $% rate from % is in effect and cannot be changed. Add a new dated rate.',
            old.rate_per_head_day, old.effective_from;
    end if;
    return new;
end;
$$;

do $$
begin
    if not exists (select 1 from pg_trigger where tgrelid = 'public.nonfeed_rates'::regclass
                    and tgname = 'nonfeed_rates_guard') then
        create trigger nonfeed_rates_guard
            before insert or update on public.nonfeed_rates
            for each row execute function public.nonfeed_rates_guard();
    end if;
end $$;

-- Carry the live placeholder in as history. The guard refuses a past date on
-- INSERT, so it is switched off for this one seed row only.
do $$
declare
    v_rate numeric; v_note text; v_from date;
begin
    if exists (select 1 from public.nonfeed_rates) then
        raise notice 'nonfeed_rates already seeded; left as is';
        return;
    end if;
    select nonfeed_cog_per_day, nonfeed_cog_note, feed_direct_from
      into v_rate, v_note, v_from from public.ranch_settings limit 1;
    if v_rate is null or v_from is null then
        raise exception 'nonfeed_rates seed: ranch_settings has no non-feed rate (%) or no feed_direct_from (%); expected 0.50 from 2026-09-01',
            v_rate, v_from;
    end if;
    alter table public.nonfeed_rates disable trigger nonfeed_rates_guard;
    insert into public.nonfeed_rates (effective_from, rate_per_head_day, includes_pasture, is_placeholder, notes)
    values (v_from, v_rate, true, true,
            'Carried from ranch_settings.nonfeed_cog_per_day on 2026-10-04: ' || coalesce(v_note, ''));
    alter table public.nonfeed_rates enable trigger nonfeed_rates_guard;
end $$;

-- =====================================================================
-- RLS, policies, grants.
-- =====================================================================
alter table public.pasture_label_history   enable row level security;
alter table public.pasture_season_settings enable row level security;
alter table public.nonfeed_rates           enable row level security;

do $$
declare
    t text;
    v_read text;
begin
    foreach t in array array['pasture_label_history', 'pasture_season_settings', 'nonfeed_rates'] loop
        v_read := case when t = 'nonfeed_rates' then 'public.can_read_books()' else 'public.can_read_operational()' end;
        if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = t || '_select') then
            execute format('create policy %I on public.%I for select to authenticated using (%s)', t || '_select', t, v_read);
        end if;
        if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = t || '_insert') then
            execute format('create policy %I on public.%I for insert to authenticated with check (public.current_user_role() = any (array[''owner'',''office'']))',
                           t || '_insert', t);
        end if;
        if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = t || '_update') then
            execute format('create policy %I on public.%I for update to authenticated using (public.current_user_role() = any (array[''owner'',''office''])) with check (public.current_user_role() = any (array[''owner'',''office'']))',
                           t || '_update', t);
        end if;
        execute format('revoke all on public.%I from public, anon, authenticated', t);
        execute format('grant select, insert, update on public.%I to authenticated', t);
    end loop;
end $$;

revoke all on public.pasture_label_periods from public, anon, authenticated;
grant select on public.pasture_label_periods to authenticated;

revoke all on function public.pasture_label_history_guard()   from public, anon;
revoke all on function public.pasture_season_settings_guard() from public, anon;
revoke all on function public.nonfeed_rates_guard()           from public, anon;

-- =====================================================================
-- Verify.
-- =====================================================================
do $$
declare
    t text; n integer; v_rls boolean; v_opts text[];
begin
    foreach t in array array['pasture_label_history', 'pasture_season_settings', 'nonfeed_rates'] loop
        select relrowsecurity into v_rls from pg_class where oid = ('public.' || t)::regclass;
        if not v_rls then raise exception '% has RLS off', t; end if;
        select count(*) into n from pg_policies where schemaname = 'public' and tablename = t;
        if n <> 3 then raise exception '% has % policies, expected 3', t, n; end if;
        if has_table_privilege('anon', ('public.' || t)::regclass, 'SELECT') then
            raise exception 'anon can read %', t;
        end if;
    end loop;
    select reloptions into v_opts from pg_class where oid = 'public.pasture_label_periods'::regclass;
    if v_opts is null or not (v_opts @> array['security_invoker=true']) then
        raise exception 'pasture_label_periods is not security_invoker';
    end if;
    select count(*) into n from public.pasture_season_settings;
    if n < 4 then raise exception 'expected the 4 D7 season rows, found %', n; end if;
    select count(*) into n from public.nonfeed_rates;
    if n < 1 then raise exception 'nonfeed_rates seed row missing'; end if;
    if (select pasture_go_live from public.ranch_settings limit 1) is null then
        raise exception 'ranch_settings.pasture_go_live not set';
    end if;
    if not exists (select 1 from information_schema.columns where table_schema = 'public'
                    and table_name = 'lots' and column_name = 'no_precon') then
        raise exception 'lots.no_precon missing';
    end if;
    raise notice 'pasture settings: 3 tables with RLS and 3 policies each, view security_invoker, seeds present';
end $$;

commit;
