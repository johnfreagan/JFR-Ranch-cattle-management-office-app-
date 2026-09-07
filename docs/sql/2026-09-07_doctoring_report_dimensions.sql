-- ============================================================================
-- Doctoring & Deaths report: comparison dimensions
-- 2026-09-07
--
-- Adds the columns the report needs to COMPARE outcomes across:
--   * the receiving (processing) protocol the animal arrived under
--   * the medications actually given at a pull
--   * the pull protocol (field action) and pull position, which already existed
--
-- Two functions gain columns. Neither changes its ARGUMENT list, so every
-- existing caller keeps working; PostgREST still resolves one function per
-- name. A return type cannot be widened with CREATE OR REPLACE, so both are
-- dropped and recreated.
--
-- Nothing here writes. Both stay STABLE, LANGUAGE sql, INVOKER (so RLS on the
-- base tables still decides what the caller sees) with a pinned search_path.
--
-- Idempotent: safe to run more than once.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Guard: the objects these read must exist and look the way we expect.
-- ---------------------------------------------------------------------------
do $guard$
begin
    if to_regclass('public.doctoring_event_analytics') is null then
        raise exception 'public.doctoring_event_analytics is missing - apply the doctoring analytics migration first';
    end if;
    if to_regclass('public.protocols') is null then
        raise exception 'public.protocols is missing';
    end if;
    if not exists (
        select 1 from information_schema.columns
        where table_schema = 'public'
          and table_name   = 'delivery_receipts'
          and column_name  = 'receiving_protocol_id'
    ) then
        raise exception 'delivery_receipts.receiving_protocol_id is missing - processing protocol is not linked to receipts yet';
    end if;
end
$guard$;

-- ---------------------------------------------------------------------------
-- get_doctoring_analytics
--
-- New columns:
--   receiving_protocol_id    the protocol on the receipt the tag arrived on
--   receiving_protocol_name  name + version label, NULL when the load carried
--                            no protocol (the X lots pre-date every protocol)
--   med_ids / med_names      the meds given at THIS pull, as arrays, so the
--                            report can group by a single med or by the exact
--                            regimen without re-parsing the display string
--
-- The tag -> receipt join is the same DISTINCT ON the function already used to
-- derive animal_arrival_date, widened to carry the receipt's protocol. One
-- join, one truth: a row's arrival date and its protocol always come off the
-- same receipt.
-- ---------------------------------------------------------------------------
drop function if exists public.get_doctoring_analytics(uuid[], date, date, integer, text, uuid);

create function public.get_doctoring_analytics(
    p_lot_ids       uuid[]  default null,
    p_date_from     date    default null,
    p_date_to       date    default null,
    p_pull_position integer default null,
    p_diagnosis     text    default null,
    p_action_id     uuid    default null
)
returns table (
    id                      uuid,
    tag_number              text,
    lot_id                  uuid,
    lot_number              text,
    event_date              date,
    event_datetime          timestamptz,
    field_action_id         uuid,
    field_action_name       text,
    pull_position           bigint,
    total_pulls_for_animal  bigint,
    is_last_pull            boolean,
    days_to_next_event      numeric,
    days_since_prev_event   numeric,
    death_date              date,
    days_pull_to_death      integer,
    animal_died             boolean,
    medications             text,
    diagnosis               text,
    notes                   text,
    animal_arrival_date     date,
    receiving_protocol_id   uuid,
    receiving_protocol_name text,
    med_ids                 uuid[],
    med_names               text[]
)
language sql
stable
set search_path to 'public', 'pg_catalog'
as $function$
    with tag_arrival as (
        -- EARLIEST receipt per (lot_id, tag_number). A tag should be on one
        -- receipt per lot; DISTINCT ON guards against re-import duplicates.
        select distinct on (lt.lot_id, lt.tag_number)
            lt.lot_id,
            lt.tag_number::text as tag_number,
            dr.receipt_date          as arrival_date,
            dr.receiving_protocol_id as protocol_id
        from public.lot_tags lt
        join public.delivery_receipts dr on dr.id = lt.delivery_receipt_id
        order by lt.lot_id, lt.tag_number, dr.receipt_date asc
    )
    select
        a.id,
        a.tag_number,
        a.lot_id,
        l.lot_number,
        a.event_date,
        a.event_datetime,
        a.field_action_id,
        fa.name as field_action_name,
        a.pull_position,
        a.total_pulls_for_animal,
        a.is_last_pull,
        a.days_to_next_event,
        a.days_since_prev_event,
        a.death_date,
        a.days_pull_to_death,
        a.animal_died,
        (
            select string_agg(m.name || ' ' || dem.dose_cc || 'cc', ', ' order by dem.position)
            from public.doctoring_event_meds dem
            join public.medications m on m.id = dem.medication_id
            where dem.doctoring_event_id = a.id
        ) as medications,
        case
            when a.notes ~ 'Dx: '
            then substring(a.notes from 'Dx: (.+)$')
            else null
        end as diagnosis,
        a.notes,
        ta.arrival_date as animal_arrival_date,
        ta.protocol_id  as receiving_protocol_id,
        case
            when p.id is null then null
            else p.name || coalesce(' ' || p.version_label, '')
        end as receiving_protocol_name,
        (
            select array_agg(dem.medication_id order by m.name)
            from public.doctoring_event_meds dem
            join public.medications m on m.id = dem.medication_id
            where dem.doctoring_event_id = a.id
        ) as med_ids,
        (
            -- ordered by NAME, not by position, so the same two drugs entered
            -- in either order produce the same regimen key downstream
            select array_agg(m.name order by m.name)
            from public.doctoring_event_meds dem
            join public.medications m on m.id = dem.medication_id
            where dem.doctoring_event_id = a.id
        ) as med_names
    from public.doctoring_event_analytics a
    join public.lots l on l.id = a.lot_id
    left join public.field_actions fa on fa.id = a.field_action_id
    left join tag_arrival ta on ta.lot_id = a.lot_id and ta.tag_number = a.tag_number
    left join public.protocols p on p.id = ta.protocol_id
    where
        (p_lot_ids is null or a.lot_id = any(p_lot_ids))
        and (p_date_from is null or a.event_date >= p_date_from)
        and (p_date_to   is null or a.event_date <= p_date_to)
        and (p_pull_position is null or a.pull_position = p_pull_position)
        and (p_action_id is null or a.field_action_id = p_action_id)
        and (p_diagnosis is null or a.notes ilike '%' || p_diagnosis || '%')
    order by a.event_datetime desc;
$function$;

-- ---------------------------------------------------------------------------
-- get_lot_deaths_with_arrival
--
-- Same two new protocol columns. Deaths must carry the protocol independently
-- of doctoring: an animal that died having never been pulled has no row in the
-- doctoring set at all, and those are the deaths a processing protocol is
-- most on the hook for.
-- ---------------------------------------------------------------------------
drop function if exists public.get_lot_deaths_with_arrival(uuid[]);

create function public.get_lot_deaths_with_arrival(
    p_lot_ids uuid[] default null
)
returns table (
    lot_id                  uuid,
    death_event_id          uuid,
    event_date              date,
    head_count              integer,
    tag_number              text,
    cause                   text,
    arrival_date            date,
    days_from_arrival       integer,
    receiving_protocol_id   uuid,
    receiving_protocol_name text
)
language sql
stable
set search_path to 'public', 'pg_catalog'
as $function$
    with tag_arrival as (
        select distinct on (lt.lot_id, lt.tag_number)
            lt.lot_id,
            lt.tag_number::text as tag_number,
            dr.receipt_date          as arrival_date,
            dr.receiving_protocol_id as protocol_id
        from public.lot_tags lt
        join public.delivery_receipts dr on dr.id = lt.delivery_receipt_id
        order by lt.lot_id, lt.tag_number, dr.receipt_date asc
    )
    select
        le.lot_id,
        le.id as death_event_id,
        le.event_date,
        le.head_count,
        le.tag_number,
        le.cause,
        ta.arrival_date,
        case
            when ta.arrival_date is not null and le.event_date >= ta.arrival_date
            then (le.event_date - ta.arrival_date)
            else null
        end as days_from_arrival,
        ta.protocol_id as receiving_protocol_id,
        case
            when p.id is null then null
            else p.name || coalesce(' ' || p.version_label, '')
        end as receiving_protocol_name
    from public.lot_events le
    left join tag_arrival ta
        on ta.lot_id = le.lot_id
       and ta.tag_number = le.tag_number
    left join public.protocols p on p.id = ta.protocol_id
    where le.event_type = 'death'
      and (p_lot_ids is null or le.lot_id = any(p_lot_ids))
    order by le.event_date;
$function$;

-- ---------------------------------------------------------------------------
-- Grants. Both are read-only helpers over RLS-protected base tables; every
-- signed-in role may call them, and RLS still decides what comes back.
-- Never anon: the publishable key is public (see CLAUDE.md).
-- ---------------------------------------------------------------------------
revoke all on function public.get_doctoring_analytics(uuid[], date, date, integer, text, uuid) from public;
revoke all on function public.get_lot_deaths_with_arrival(uuid[]) from public;
grant execute on function public.get_doctoring_analytics(uuid[], date, date, integer, text, uuid) to authenticated;
grant execute on function public.get_lot_deaths_with_arrival(uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- Verify: exactly one function of each name (PostgREST resolves by name), the
-- new columns present, search_path pinned, INVOKER, and anon holds nothing.
-- ---------------------------------------------------------------------------
do $verify$
declare
    n int;
    rec record;
begin
    for rec in
        select 'get_doctoring_analytics'::text as fname
        union all select 'get_lot_deaths_with_arrival'
    loop
        select count(*) into n
        from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
        where ns.nspname = 'public' and p.proname = rec.fname;
        if n <> 1 then
            raise exception 'expected exactly 1 public.% - found %', rec.fname, n;
        end if;

        select count(*) into n
        from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
        where ns.nspname = 'public' and p.proname = rec.fname
          and p.prosecdef = false
          and array_to_string(coalesce(p.proconfig, array[]::text[]), ',') like '%search_path%';
        if n <> 1 then
            raise exception 'public.% must be SECURITY INVOKER with a pinned search_path', rec.fname;
        end if;

        if has_function_privilege('anon', (
            select p.oid from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
            where ns.nspname = 'public' and p.proname = rec.fname
        ), 'EXECUTE') then
            raise exception 'anon must not hold EXECUTE on public.%', rec.fname;
        end if;
    end loop;

    -- The new columns actually come back. A RETURNS TABLE function's columns
    -- are OUT parameters, so they live in pg_proc.proargnames -- NOT in
    -- information_schema.columns, which covers only tables and views and
    -- would silently report zero here.
    select count(*) into n
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    cross join lateral unnest(p.proargnames) as an(name)
    where ns.nspname = 'public'
      and p.proname = 'get_doctoring_analytics'
      and an.name in ('receiving_protocol_id', 'receiving_protocol_name', 'med_ids', 'med_names');
    if n <> 4 then
        raise exception 'get_doctoring_analytics is missing comparison columns - found % of 4', n;
    end if;

    select count(*) into n
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    cross join lateral unnest(p.proargnames) as an(name)
    where ns.nspname = 'public'
      and p.proname = 'get_lot_deaths_with_arrival'
      and an.name in ('receiving_protocol_id', 'receiving_protocol_name');
    if n <> 2 then
        raise exception 'get_lot_deaths_with_arrival is missing protocol columns - found % of 2', n;
    end if;

    -- No smoke-test call here on purpose. LANGUAGE sql bodies are already
    -- parsed and planned at CREATE time, so a broken body cannot reach this
    -- point; a PERFORM would only add a way for the migration to roll back
    -- over an EXECUTE grant rather than over anything actually wrong.

    raise notice 'doctoring report dimensions: both functions rebuilt and verified';
end
$verify$;

commit;
