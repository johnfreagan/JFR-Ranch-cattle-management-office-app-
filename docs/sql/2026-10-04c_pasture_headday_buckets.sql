-- 2026-10-04c  Pasture head-days, build step 3: head-day buckets (no dollars).
--
-- Design: docs/pasture-headdays-phase-design.md, build step 3 (D4, D28, D29,
-- D30, D32, D37, D43, D44, D49).
--
-- WHY A LOG. D32 says head-days by pasture come from lot_pasture_assignments.
-- Checked 2026-10-04: an assignment does not keep its history. A death or a
-- partial move overwrites head_count on the open row (record_death_with_pasture,
-- record_move_with_pasture and about twenty other writers, plus direct writes
-- from the office app), so "how many head stood in Corner 1 on 11/12" cannot be
-- read back from the table a week later. This file adds an append-only log,
-- written by a trigger on every insert, update and removal of an assignment row,
-- whoever makes it. Head per lot, pasture and day is the running sum of the log.
--
--   A. pasture_head_log               the log; RLS read-only to clients.
--      pasture_head_log_capture()     the trigger (SECURITY DEFINER: see below).
--      ranch_settings.pasture_head_log_from   the day the log starts (install day).
--   B. record_death_with_pasture, record_move_with_pasture: one added line each,
--      so a death or move entered late is logged on the day it happened, not the
--      day it was typed. Every other writer logs on ranch_today(); the books
--      scaling in D covers the difference (see D).
--   C. lot_loads()                    every load of every lot with its arrival
--      date: delivery receipts (invoices where receipts cover fewer head than
--      the invoices), plus transfers in at the source lot's receipt-weighted
--      arrival (D28: the clock travels with the cattle).
--   D. pasture_head_recorded(from, to)        head per lot, pasture and day, from the log.
--      pasture_bucket_on(pasture, day)        label, season and bucket of a pasture on a day.
--      pasture_headday_buckets(from, to)      lot x pasture x day x bucket head-days.
--   E. precon_day75_notices(days_ahead)        the Needs Attention rows (D30, D37).
--   F. pasture_head_log_check (view)          assignments whose log does not sum
--                                             to their head; shown on Anomalies.
--
-- Head-days tie to the books. lot_daily_head is what cost is charged on, so a
-- lot's bucket head-days on a day always add to its lot_daily_head that day.
-- The pasture split comes from the log; when the log's total for the lot
-- differs from the books (a late entry, an office correction, head not placed
-- in any pasture), each pasture's share is scaled to the books total and the
-- row is marked scaled. Head on the books with no pasture at all goes to the
-- bucket 'unplaced'. The existing Anomalies check "Pasture sum <> head current"
-- (D8, D32) shows today's gap; pasture_head_log_check shows a log that has lost
-- track of an assignment.
--
-- Every head-day carries two things, kept apart (John 2026-10-04, after step 3
-- was drafted: precon traps, growyards and dual-use pastures carry different
-- stocking rates and different cost):
--   phase  = precon or grower, from the 75-day clock (where the calf is in life);
--   bucket = the land use of the pasture that day: crop_winter, crop_summer,
--            grass_winter, grass_summer, growyard, other, unlabeled (pasture has
--            no label that day), unplaced (head on the books in no pasture).
-- Pasture cost follows the land (bucket); phase baselines follow the calf.
--
-- The 75-day clock (D4): a load's precon days are its arrival day and the 74
-- days after it, so every calf gets exactly 75 precon days (arrival + 74 is the
-- last). The design's example ("8/11 load: precon through 10/25") counted one
-- day more; it was a drafting slip, and John confirmed arrival + 74 stands
-- (2026-10-04). The rule lives in one place, lot_precon_last_day().
-- Precon applies wherever the calf stands (D2, D33) unless the lot is marked
-- no_precon (D43) or is the feed pen (D29). A pasture holding a lot gets the
-- lot's loads in proportion, limited to loads that had arrived by the day head
-- last came into that pasture (D37).
--
-- Test lots are skipped everywhere (D44). Days before go-live (D48) and before
-- the log started are never counted.
--
-- SECURITY DEFINER, one function: pasture_head_log_capture. Reason: the log is
-- an audit trail that clients must not write. Crew writes assignments (field
-- moves and deaths), and an INVOKER trigger would need an INSERT policy that
-- would also let any crew login forge log rows through the API. DEFINER with a
-- pinned search_path lets only the trigger write; no client role holds INSERT.
-- Everything else is INVOKER. lot_loads() reads lot_transfers, which only
-- can_read_books() roles see; for crew, transferred-in head have no clock (the
-- reports built on this are office and owner).
--
-- No DROP or DELETE statement (connector note, docs/feed-pb-import.md
-- 2026-10-03). Idempotent. For apply_migration or the CLI, strip the
-- begin;/commit; lines.
-- Applied 2026-10-04 on John's approval through apply_migration (begin/commit
-- stripped). Verified live: md5(prosrc) of all nine functions equals a scratch
-- build of this file (pasture_head_log_capture a24a137c..., record_death_with_pasture
-- 9a0a6dc1..., record_move_with_pasture 006edbb9..., lot_loads be2b4cd9...,
-- pasture_headday_buckets cbf347c3...); 24 open assignments seeded from
-- 2026-10-04; pasture_head_log_check empty; trigger enabled; rls_verify
-- assertions 1, 2, 4-7 run as selects with zero findings.
begin;

-- The two RPCs this file changes must be the bodies read on 2026-10-04.
do $$
declare v text;
begin
    select md5(prosrc) into v from pg_proc where oid = 'public.record_death_with_pasture(uuid, uuid, integer, text, text, date, text, uuid)'::regprocedure;
    if v <> '43a2f4509b78272878959a5ca29ca7d9' and position('jfr.head_effective_date' in
         (select prosrc from pg_proc where oid = 'public.record_death_with_pasture(uuid, uuid, integer, text, text, date, text, uuid)'::regprocedure)) = 0 then
        raise exception 'record_death_with_pasture changed since 2026-10-04 (md5 %); re-read it before applying', v;
    end if;
    select md5(prosrc) into v from pg_proc where oid = 'public.record_move_with_pasture(uuid, uuid, uuid, integer, date, text, uuid)'::regprocedure;
    if v <> 'fd34f60a06516705dc765f7fe69820af' and position('jfr.head_effective_date' in
         (select prosrc from pg_proc where oid = 'public.record_move_with_pasture(uuid, uuid, uuid, integer, date, text, uuid)'::regprocedure)) = 0 then
        raise exception 'record_move_with_pasture changed since 2026-10-04 (md5 %); re-read it before applying', v;
    end if;
end $$;

-- No assignment may change between the trigger going on and the seed.
lock table public.lot_pasture_assignments in share row exclusive mode;

-- =====================================================================
-- A. The log.
-- One row = "from effective_date on, this lot has head_delta more head in this
-- pasture". Head on a day = sum of head_delta with effective_date <= that day.
-- An assignment counts on the days moved_in <= d < moved_out (a move closes the
-- old row and opens the new one on the same day; the head count in the new
-- pasture that day). in_date, on a positive row, is the day that head came into
-- the pasture (D37).
-- =====================================================================
alter table public.ranch_settings add column if not exists pasture_head_log_from date;

create table if not exists public.pasture_head_log (
    id              bigint generated always as identity primary key,
    assignment_id   uuid not null,      -- no FK: a removed assignment keeps its log, negated
    lot_id          uuid not null,
    pasture_id      uuid not null,
    effective_date  date not null,
    head_delta      integer not null,
    in_date         date,
    reason          text not null,
    logged_at       timestamptz not null default now(),
    logged_by       uuid default auth.uid(),
    constraint pasture_head_log_reason_check check (reason in
        ('seed', 'insert', 'head_change', 'close', 'reopen', 'correction', 'removed'))
);
create index if not exists pasture_head_log_lpd_idx on public.pasture_head_log (lot_id, pasture_id, effective_date);
create index if not exists pasture_head_log_assignment_idx on public.pasture_head_log (assignment_id);

create or replace function public.pasture_head_log_capture()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    -- The day a head change happened: set by the RPCs that know it
    -- (record_death_with_pasture, record_move_with_pasture), else today.
    v_eff date := coalesce(nullif(current_setting('jfr.head_effective_date', true), '')::date, public.ranch_today());
    v_e   date;
begin
    if tg_op = 'INSERT' then
        if new.head_count <> 0 then
            insert into pasture_head_log (assignment_id, lot_id, pasture_id, effective_date, head_delta, in_date, reason)
            values (new.id, new.lot_id, new.pasture_id, new.moved_in, new.head_count, new.moved_in, 'insert');
            if new.moved_out is not null then
                insert into pasture_head_log (assignment_id, lot_id, pasture_id, effective_date, head_delta, in_date, reason)
                values (new.id, new.lot_id, new.pasture_id, new.moved_out, -new.head_count, null, 'close');
            end if;
        end if;
        return null;
    end if;

    if tg_op = 'DELETE' then
        -- the row never existed: cancel everything logged for it
        insert into pasture_head_log (assignment_id, lot_id, pasture_id, effective_date, head_delta, in_date, reason)
        select g.assignment_id, g.lot_id, g.pasture_id, g.effective_date, -g.head_delta, null, 'removed'
          from pasture_head_log g where g.assignment_id = old.id;
        return null;
    end if;

    -- UPDATE. A change of lot, pasture or move-in day is a correction: the
    -- row's logged history is cancelled and it is logged again as it now stands.
    if new.lot_id is distinct from old.lot_id or new.pasture_id is distinct from old.pasture_id
       or new.moved_in is distinct from old.moved_in then
        insert into pasture_head_log (assignment_id, lot_id, pasture_id, effective_date, head_delta, in_date, reason)
        select g.assignment_id, g.lot_id, g.pasture_id, g.effective_date, -g.head_delta, null, 'correction'
          from pasture_head_log g where g.assignment_id = old.id;
        if new.head_count <> 0 then
            insert into pasture_head_log (assignment_id, lot_id, pasture_id, effective_date, head_delta, in_date, reason)
            values (new.id, new.lot_id, new.pasture_id, new.moved_in, new.head_count, new.moved_in, 'correction');
            if new.moved_out is not null then
                insert into pasture_head_log (assignment_id, lot_id, pasture_id, effective_date, head_delta, in_date, reason)
                values (new.id, new.lot_id, new.pasture_id, new.moved_out, -new.head_count, null, 'correction');
            end if;
        end if;
        return null;
    end if;

    if new.head_count = old.head_count and new.moved_out is not distinct from old.moved_out then
        return null;   -- notes, recorded_by, updated_at: nothing about head
    end if;

    -- 1. undo the old closing, if there was one
    if old.moved_out is not null then
        insert into pasture_head_log (assignment_id, lot_id, pasture_id, effective_date, head_delta, in_date, reason)
        values (old.id, old.lot_id, old.pasture_id, old.moved_out, old.head_count, old.moved_in, 'reopen');
    end if;
    -- 2. the head change, from the day it happened (never before move-in; a
    --    change dated after the row closes is a correction from move-in)
    if new.head_count <> old.head_count then
        v_e := greatest(v_eff, new.moved_in);
        if new.moved_out is not null and v_e >= new.moved_out then v_e := new.moved_in; end if;
        insert into pasture_head_log (assignment_id, lot_id, pasture_id, effective_date, head_delta, in_date, reason)
        values (new.id, new.lot_id, new.pasture_id, v_e, new.head_count - old.head_count,
                case when new.head_count > old.head_count then v_e end, 'head_change');
    end if;
    -- 3. the new closing, if there is one
    if new.moved_out is not null then
        insert into pasture_head_log (assignment_id, lot_id, pasture_id, effective_date, head_delta, in_date, reason)
        values (new.id, new.lot_id, new.pasture_id, new.moved_out, -new.head_count, null, 'close');
    end if;
    return null;
end;
$$;

do $$
begin
    if not exists (select 1 from pg_trigger where tgrelid = 'public.lot_pasture_assignments'::regclass
                    and tgname = 'lot_pasture_assignments_head_log') then
        create trigger lot_pasture_assignments_head_log
            after insert or update or delete on public.lot_pasture_assignments
            for each row execute function public.pasture_head_log_capture();
    end if;
end $$;

-- Seed: every open assignment's head from today. Days before the log starts
-- are never counted (go-live is later), so this is all the history needed.
do $$
declare n integer;
begin
    update public.ranch_settings set pasture_head_log_from = public.ranch_today(), updated_at = now()
     where pasture_head_log_from is null;
    insert into public.pasture_head_log (assignment_id, lot_id, pasture_id, effective_date, head_delta, in_date, reason)
    select a.id, a.lot_id, a.pasture_id, (select pasture_head_log_from from public.ranch_settings limit 1),
           a.head_count, a.moved_in, 'seed'
      from public.lot_pasture_assignments a
     where a.moved_out is null and a.head_count <> 0
       and not exists (select 1 from public.pasture_head_log g where g.assignment_id = a.id);
    get diagnostics n = row_count;
    raise notice 'pasture_head_log: % open assignment(s) seeded', n;
end $$;

alter table public.pasture_head_log enable row level security;
do $$
begin
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'pasture_head_log'
                    and policyname = 'pasture_head_log_select') then
        create policy pasture_head_log_select on public.pasture_head_log
            for select to authenticated using (public.can_read_operational());
    end if;
end $$;
-- read-only to every client role: only the trigger writes
revoke all on public.pasture_head_log from public, anon, authenticated;
grant select on public.pasture_head_log to authenticated;
revoke all on function public.pasture_head_log_capture() from public, anon, authenticated;

-- =====================================================================
-- B. Date the log by the event day in the two RPCs that know it. Bodies are
-- the live ones of 2026-10-04 with one PERFORM added after BEGIN.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.record_death_with_pasture(p_lot_id uuid, p_pasture_id uuid, p_head_count integer, p_tag_number text DEFAULT NULL::text, p_cause text DEFAULT NULL::text, p_event_date date DEFAULT CURRENT_DATE, p_notes text DEFAULT NULL::text, p_created_by uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_event_id UUID;
    v_assignment_id UUID;
    v_assignment_head INTEGER;
    v_new_head INTEGER;
BEGIN
    -- 2026-10-04c: the pasture head log dates this change on the death day.
    PERFORM set_config('jfr.head_effective_date', coalesce(p_event_date::text, ''), true);

    IF p_head_count <= 0 THEN
        RAISE EXCEPTION 'Head count must be positive (got %).', p_head_count;
    END IF;

    -- Find the active assignment row for this (lot, pasture)
    SELECT id, head_count INTO v_assignment_id, v_assignment_head
    FROM public.lot_pasture_assignments
    WHERE lot_id = p_lot_id
      AND pasture_id = p_pasture_id
      AND moved_out IS NULL;

    IF v_assignment_id IS NULL THEN
        RAISE EXCEPTION 'No active pasture assignment for lot % at pasture %.',
            p_lot_id, p_pasture_id;
    END IF;

    IF p_head_count > v_assignment_head THEN
        RAISE EXCEPTION 'Cannot record % deaths from pasture with only % active head.',
            p_head_count, v_assignment_head;
    END IF;

    -- Insert the death event with negative head_count (project convention)
    INSERT INTO public.lot_events (
        lot_id, event_type, event_date, head_count, tag_number, cause,
        pasture_id, notes, created_by
    ) VALUES (
        p_lot_id, 'death', p_event_date, -p_head_count, p_tag_number, p_cause,
        p_pasture_id, p_notes, p_created_by
    )
    RETURNING id INTO v_event_id;

    -- Decrement assignment
    v_new_head := v_assignment_head - p_head_count;
    IF v_new_head = 0 THEN
        UPDATE public.lot_pasture_assignments
        SET moved_out = p_event_date
        WHERE id = v_assignment_id;
    ELSE
        UPDATE public.lot_pasture_assignments
        SET head_count = v_new_head
        WHERE id = v_assignment_id;
    END IF;

    RETURN v_event_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_move_with_pasture(p_lot_id uuid, p_from_pasture_id uuid, p_to_pasture_id uuid, p_head_count integer, p_move_date date DEFAULT CURRENT_DATE, p_notes text DEFAULT NULL::text, p_recorded_by uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_move_id     UUID;
    v_from_assign UUID;
    v_from_head   INTEGER;
    v_to_assign   UUID;
BEGIN
    -- 2026-10-04c: the pasture head log dates this change on the move day.
    PERFORM set_config('jfr.head_effective_date', coalesce(p_move_date::text, ''), true);

    IF p_head_count IS NULL OR p_head_count <= 0 THEN
        RAISE EXCEPTION 'Head count must be positive (got %).', p_head_count;
    END IF;
    IF p_to_pasture_id IS NULL THEN
        RAISE EXCEPTION 'A destination pasture is required.';
    END IF;
    IF p_from_pasture_id IS NOT NULL AND p_from_pasture_id = p_to_pasture_id THEN
        RAISE EXCEPTION 'From and to pasture are the same.';
    END IF;

    -- A NULL source means head arriving from outside the pasture system
    -- (the office uses this for receipts). Nothing to decrement then.
    IF p_from_pasture_id IS NOT NULL THEN
        SELECT id, head_count INTO v_from_assign, v_from_head
        FROM public.lot_pasture_assignments
        WHERE lot_id = p_lot_id
          AND pasture_id = p_from_pasture_id
          AND moved_out IS NULL;

        IF v_from_assign IS NULL THEN
            RAISE EXCEPTION 'No active pasture assignment for lot % at the from-pasture.', p_lot_id;
        END IF;
        IF p_head_count > v_from_head THEN
            RAISE EXCEPTION 'Cannot move % head out of a pasture holding %.', p_head_count, v_from_head;
        END IF;
    END IF;

    INSERT INTO public.lot_movements (
        lot_id, move_date, from_pasture_id, to_pasture_id, head_count, notes, recorded_by
    ) VALUES (
        p_lot_id, p_move_date, p_from_pasture_id, p_to_pasture_id, p_head_count, p_notes, p_recorded_by
    )
    RETURNING id INTO v_move_id;

    -- Source: close it when the last head leaves, matching the death path.
    IF v_from_assign IS NOT NULL THEN
        IF v_from_head - p_head_count = 0 THEN
            UPDATE public.lot_pasture_assignments
               SET moved_out = p_move_date
             WHERE id = v_from_assign;
        ELSE
            UPDATE public.lot_pasture_assignments
               SET head_count = v_from_head - p_head_count
             WHERE id = v_from_assign;
        END IF;
    END IF;

    -- Destination: add to the open assignment, or open one.
    SELECT id INTO v_to_assign
    FROM public.lot_pasture_assignments
    WHERE lot_id = p_lot_id
      AND pasture_id = p_to_pasture_id
      AND moved_out IS NULL;

    IF v_to_assign IS NULL THEN
        INSERT INTO public.lot_pasture_assignments (
            lot_id, pasture_id, head_count, moved_in, recorded_by
        ) VALUES (
            p_lot_id, p_to_pasture_id, p_head_count, p_move_date, p_recorded_by
        );
    ELSE
        UPDATE public.lot_pasture_assignments
           SET head_count = head_count + p_head_count
         WHERE id = v_to_assign;
    END IF;

    RETURN v_move_id;
END;
$function$;

-- =====================================================================
-- C. Loads and the 75-day clock (D4, D28).
-- =====================================================================
create or replace function public.lot_precon_last_day(p_arrival date)
returns date
language sql
immutable
set search_path = public, pg_temp
as $$
    -- D4: exactly 75 precon days, the arrival day being day 1.
    select p_arrival + 74
$$;

create or replace function public.lot_loads()
returns table (lot_id uuid, arrival date, head integer, source text)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
    -- A lot's loads are its delivery receipts, unless its receipts cover fewer
    -- head than its invoices (cattle invoiced before receipts were kept, e.g.
    -- 37X: 361 head invoiced Dec 2025, one 8-head catch-up receipt 2026-09-03);
    -- then its loads are its invoices. Using the receipts there would date most
    -- of the lot's calves by a bookkeeping catch-up.
    with tot as (
        select l.id as lot_id,
               (select coalesce(sum(r.head_count), 0) from delivery_receipts r where r.lot_id = l.id and r.head_count > 0) as rcpt,
               (select coalesce(sum(i.head_count), 0) from invoices i where i.lot_id = l.id and i.head_count > 0) as inv
          from lots l
    )
    select r.lot_id, r.receipt_date, r.head_count, 'receipt'
      from delivery_receipts r join tot on tot.lot_id = r.lot_id
     where r.head_count > 0 and r.receipt_date is not null and tot.rcpt >= tot.inv
    union all
    select i.lot_id, i.invoice_date, i.head_count, 'invoice'
      from invoices i join tot on tot.lot_id = i.lot_id
     where i.head_count > 0 and i.invoice_date is not null and tot.rcpt < tot.inv
    union all
    -- D28: transferred head keep the source lot's clock: its receipt-weighted
    -- arrival (the load date itself when the source had one load), else the
    -- transfer date when the source has no receipts.
    select t.dest_lot_id,
           coalesce((select date '2000-01-01'
                            + round(sum(r.head_count * (r.receipt_date - date '2000-01-01'))::numeric
                                    / nullif(sum(r.head_count), 0))::integer
                       from delivery_receipts r
                      where r.lot_id = t.source_lot_id and r.head_count > 0),
                    t.transfer_date),
           t.head_count, 'transfer'
      from lot_transfers t
     where t.head_count > 0 and t.dest_lot_id is not null
$$;

-- =====================================================================
-- D. Head per pasture per day, and the buckets.
-- =====================================================================
create or replace function public.pasture_head_recorded(p_from date, p_to date)
returns table (lot_id uuid, pasture_id uuid, day date, head integer, last_in date)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
    with days as (
        select gs::date as day from generate_series(p_from, p_to, interval '1 day') gs
    ), lp as (
        select distinct g.lot_id, g.pasture_id from pasture_head_log g where g.effective_date <= p_to
    )
    select lp.lot_id, lp.pasture_id, d.day,
           (select coalesce(sum(g.head_delta), 0) from pasture_head_log g
             where g.lot_id = lp.lot_id and g.pasture_id = lp.pasture_id and g.effective_date <= d.day)::integer,
           (select max(g.in_date) from pasture_head_log g
             where g.lot_id = lp.lot_id and g.pasture_id = lp.pasture_id and g.effective_date <= d.day
               and g.head_delta > 0)
      from lp cross join days d
$$;

-- Label, season and bucket of a pasture on a day (D7, D8, D42, D49).
create or replace function public.pasture_bucket_on(p_pasture uuid, p_day date)
returns table (label text, season text, bucket text)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
    with lab as (
        select h.label from pasture_label_history h
         where h.pasture_id = p_pasture and h.effective_from <= p_day
         order by h.effective_from desc limit 1
    ), starts as (
        -- the most recent start of each season of that label, on or before the day
        select s.season,
               case when make_date(extract(year from p_day)::int, s.start_month, s.start_day) <= p_day
                    then make_date(extract(year from p_day)::int, s.start_month, s.start_day)
                    else make_date(extract(year from p_day)::int - 1, s.start_month, s.start_day) end as last_start
          from lab,
               lateral (select distinct on (x.season) x.season, x.start_month, x.start_day
                          from pasture_season_settings x
                         where x.label = lab.label and x.effective_from <= p_day
                         order by x.season, x.effective_from desc) s
    ), cur as (
        select season from starts order by last_start desc limit 1
    )
    select lab.label,
           case when lab.label in ('crop', 'grass') then (select season from cur) end,
           case when lab.label in ('crop', 'grass') then lab.label || '_' || coalesce((select season from cur), 'unknown')
                else lab.label end
      from lab
    union all
    select null, null, 'unlabeled' where not exists (select 1 from lab)
$$;

create or replace function public.pasture_headday_buckets(p_from date, p_to date)
returns table (lot_id uuid, pasture_id uuid, day date, phase text, bucket text, label text, season text,
               head numeric, books_head integer, recorded_head integer, scaled boolean, is_feed_pen boolean)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
    with s as (
        select pasture_go_live, pasture_head_log_from from ranch_settings limit 1
    ), rng as (
        select greatest(p_from, coalesce(s.pasture_go_live, p_from), coalesce(s.pasture_head_log_from, p_from)) as d0,
               least(p_to, ranch_today()) as d1
          from s
    ), lots_in as (
        select l.id, coalesce(l.no_precon, false) as no_precon, coalesce(l.is_feed_pen, false) as is_feed_pen
          from lots l where not coalesce(l.is_test, false)
    ), books as (
        select h.lot_id, h.as_of_date as day, h.head_on_hand
          from lot_daily_head h join lots_in l on l.id = h.lot_id, rng
         where h.as_of_date between rng.d0 and rng.d1 and h.head_on_hand > 0
    ), rec as (
        select r.lot_id, r.pasture_id, r.day, r.head, r.last_in
          from rng, lateral pasture_head_recorded(rng.d0, rng.d1) r
         where r.head > 0 and r.lot_id in (select id from lots_in)
    ), rec_tot as (
        select r.lot_id, r.day, sum(r.head) as tot from rec r group by 1, 2
    ), placed as (
        select b.lot_id, r.pasture_id, b.day, b.head_on_hand as books_head, r.head as recorded_head, r.last_in,
               b.head_on_hand::numeric * r.head / t.tot as head, (t.tot <> b.head_on_hand) as scaled
          from books b
          join rec_tot t on t.lot_id = b.lot_id and t.day = b.day
          join rec r on r.lot_id = b.lot_id and r.day = b.day
        union all
        select b.lot_id, null::uuid, b.day, b.head_on_hand, 0, null::date, b.head_on_hand::numeric, true
          from books b
         where not exists (select 1 from rec_tot t where t.lot_id = b.lot_id and t.day = b.day)
    ), withfrac as (
        select p.*, l.is_feed_pen,
               case when l.no_precon or l.is_feed_pen then 0::numeric
                    else coalesce((
                        select sum(ld.head) filter (where p.day <= lot_precon_last_day(ld.arrival))::numeric
                               / nullif(sum(ld.head), 0)
                          from lot_loads() ld
                         where ld.lot_id = p.lot_id and ld.arrival <= p.day
                           and ld.arrival <= coalesce(p.last_in, p.day)), 0)
               end as precon_frac
          from placed p join lots_in l on l.id = p.lot_id
    ), landed as (
        -- the land use of the pasture that day, whatever the phase
        select w.*, case when w.pasture_id is null then 'unplaced' else b.bucket end as bucket, b.label, b.season
          from withfrac w
          left join lateral pasture_bucket_on(w.pasture_id, w.day) b on w.pasture_id is not null
    ), split as (
        select x.lot_id, x.pasture_id, x.day, 'precon'::text as phase, x.bucket, x.label, x.season,
               x.head * x.precon_frac as head, x.books_head, x.recorded_head, x.scaled, x.is_feed_pen
          from landed x where x.precon_frac > 0
        union all
        select x.lot_id, x.pasture_id, x.day, 'grower'::text, x.bucket, x.label, x.season,
               x.head * (1 - x.precon_frac), x.books_head, x.recorded_head, x.scaled, x.is_feed_pen
          from landed x where x.precon_frac < 1
    )
    select * from split where head > 0
$$;

-- =====================================================================
-- E. Needs Attention: a lot's last calves reaching day 75 (D30, D37).
-- Shows from days_ahead days before the lot's last precon day until that day
-- passes; nothing to acknowledge.
-- =====================================================================
create or replace function public.precon_day75_notices(p_days_ahead integer default 7)
returns table (lot_id uuid, lot_number text, last_arrival date, last_precon_day date,
               days_until integer, pastures text)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
    select l.id, l.lot_number, x.last_arrival, lot_precon_last_day(x.last_arrival),
           (lot_precon_last_day(x.last_arrival) - ranch_today())::integer,
           (select string_agg(distinct r.name || ' ' || p.name, ', ')
              from lot_pasture_assignments a
              join pastures p on p.id = a.pasture_id
              join ranches r on r.id = p.ranch_id
             where a.lot_id = l.id and a.moved_out is null and a.head_count > 0)
      from lots l
      join (select ld.lot_id, max(ld.arrival) as last_arrival from lot_loads() ld group by 1) x on x.lot_id = l.id
     where l.closed_at is null
       and not coalesce(l.is_test, false)
       and not coalesce(l.is_feed_pen, false)
       and not coalesce(l.no_precon, false)
       and lot_precon_last_day(x.last_arrival) between ranch_today() and ranch_today() + p_days_ahead
$$;

-- =====================================================================
-- F. Log integrity: every assignment's log sums to its head today (open) or
-- to zero (closed or removed). Anything listed means a write the trigger did
-- not see the way it should have; it shows on Anomalies.
-- =====================================================================
create or replace view public.pasture_head_log_check
with (security_invoker = true) as
with logged as (
    select g.assignment_id, g.lot_id, g.pasture_id,
           sum(g.head_delta) filter (where g.effective_date <= ranch_today()) as log_head
      from pasture_head_log g group by 1, 2, 3
)
select coalesce(a.id, lg.assignment_id) as assignment_id,
       coalesce(a.lot_id, lg.lot_id) as lot_id,
       coalesce(a.pasture_id, lg.pasture_id) as pasture_id,
       case when a.id is not null and a.moved_out is null and a.moved_in <= ranch_today() then a.head_count else 0 end as head_now,
       coalesce(lg.log_head, 0)::integer as log_head
  from lot_pasture_assignments a
  full join logged lg on lg.assignment_id = a.id
 where coalesce(lg.log_head, 0)
       <> case when a.id is not null and a.moved_out is null and a.moved_in <= ranch_today() then a.head_count else 0 end;

revoke all on public.pasture_head_log_check from public, anon, authenticated;
grant select on public.pasture_head_log_check to authenticated;

revoke all on function public.lot_precon_last_day(date) from public, anon;
revoke all on function public.lot_loads() from public, anon;
revoke all on function public.pasture_head_recorded(date, date) from public, anon;
revoke all on function public.pasture_bucket_on(uuid, date) from public, anon;
revoke all on function public.pasture_headday_buckets(date, date) from public, anon;
revoke all on function public.precon_day75_notices(integer) from public, anon;
grant execute on function public.lot_precon_last_day(date), public.lot_loads(),
      public.pasture_head_recorded(date, date), public.pasture_bucket_on(uuid, date),
      public.pasture_headday_buckets(date, date), public.precon_day75_notices(integer) to authenticated;

-- =====================================================================
-- Verify.
-- =====================================================================
do $$
declare n integer; v_rls boolean; v_opts text[];
begin
    select relrowsecurity into v_rls from pg_class where oid = 'public.pasture_head_log'::regclass;
    if not v_rls then raise exception 'pasture_head_log has RLS off'; end if;
    if has_table_privilege('authenticated', 'public.pasture_head_log', 'INSERT') then
        raise exception 'authenticated can write pasture_head_log';
    end if;
    if has_table_privilege('anon', 'public.pasture_head_log', 'SELECT') then
        raise exception 'anon can read pasture_head_log';
    end if;
    select reloptions into v_opts from pg_class where oid = 'public.pasture_head_log_check'::regclass;
    if v_opts is null or not (v_opts @> array['security_invoker=true']) then
        raise exception 'pasture_head_log_check is not security_invoker';
    end if;
    if not exists (select 1 from pg_proc where oid = 'public.pasture_head_log_capture()'::regprocedure
                    and prosecdef and proconfig is not null) then
        raise exception 'pasture_head_log_capture is not SECURITY DEFINER with a pinned search_path';
    end if;
    select count(*) into n from public.pasture_head_log_check;
    if n <> 0 then raise exception 'pasture_head_log_check lists % assignment(s) right after the seed', n; end if;
    raise notice 'pasture head-day buckets: log seeded and consistent, read-only to clients';
end $$;

commit;
