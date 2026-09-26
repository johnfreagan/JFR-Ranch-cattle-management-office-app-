-- 2026-09-25b  Health curves: stop the statement timeout under a real login.
--
-- Found the day they went live. The lot card read "canceling statement due
-- to statement timeout". Run as postgres the views are quick (lot_health_status
-- ~0.4 s). Run as an owner through PostgREST, where `authenticated` carries an
-- 8 s statement_timeout, they were not:
--     health_head_base 1.3 s, health_curve_lot_daily 15 s, lot_health_status 21 s.
-- Every base table's SELECT policy calls can_read_operational() (or
-- can_read_books()) once PER ROW, and the curves read lot_tags,
-- delivery_receipts, doctoring_events and lot_events several times over.
-- health_death_days also looked each death's tag up through a LATERAL
-- subquery, which re-ran the whole head base once per death.
--
-- Two more of the same shape: lot_health_class looked each head's weight
-- band up with a sub-select into health_class_bands (RLS per probe, ~4,100
-- head), and lot_death_capture checked "pulled before death" with a
-- subquery per death over doctoring_events. Both now read each table once.
--
-- The fix reads the four base sets through SECURITY DEFINER functions that
-- check the role gate ONCE per call (an uncorrelated sub-select, planned as
-- an InitPlan) instead of once per row, and joins deaths to the head base
-- with one grouped hash join instead of the lateral. The views keep their
-- names, columns and types, so the app and every view above them are
-- unchanged. health_receipt_weights() is folded into health_head_rows() and
-- dropped.
--
-- Why DEFINER is acceptable here: the functions return operational data
-- that every active role (crew included) can already read row by row -
-- tags, receipt dates, doctoring days, deaths - plus invoice weight and head,
-- which is health_receipt_weights()'s old reason (crew cannot read invoices;
-- the weight class is built from invoice weight). No dollar column leaves any
-- of them. Each returns NOTHING unless can_read_operational() is true, or the
-- caller is not an API role (a migration or the SQL editor); a client cannot
-- change session_user. search_path is pinned; EXECUTE is revoked from public
-- and anon.
--
-- Idempotent. Paste WITHOUT begin/commit into the SQL editor; strip them for
-- apply_migration.
begin;

create or replace function public.health_lot_basis_rows()
returns table (lot_id uuid, lot_number text, receipt_head bigint, receipt_tags bigint, invoice_head bigint,
               estimated_head bigint, basis text, excluded_reason text)
language sql
stable
security definer
set search_path = public
as $$
    select l.id,
           l.lot_number,
           coalesce(r.head, 0),
           coalesce(t.tags, 0),
           coalesce(i.head, 0),
           e.head,
           case when e.head is not null then 'estimated_loads' else 'receipts' end,
           case
               when l.is_test     then 'test lot'
               when l.is_feed_pen then 'feed pen'
               when e.head is not null then null
               when r.head is null then 'no delivery receipts'
               when i.head > 0 and r.head < 0.8 * i.head
                    then format('receipts cover %s of %s hd', r.head, i.head)
               when coalesce(t.tags, 0) = 0 then 'no tags on the receipts'
           end
      from public.lots l
      left join (select dr.lot_id, sum(dr.head_count) as head from public.delivery_receipts dr group by dr.lot_id) r on r.lot_id = l.id
      left join (select lt.lot_id, count(*) as tags
                   from public.lot_tags lt
                   join public.delivery_receipts dr on dr.id = lt.delivery_receipt_id
                  group by lt.lot_id) t on t.lot_id = l.id
      left join (select iv.lot_id, sum(iv.head_count) as head from public.invoices iv group by iv.lot_id) i on i.lot_id = l.id
      left join (select el.lot_id, sum(el.head) as head from public.health_estimated_loads el group by el.lot_id) e on e.lot_id = l.id
     -- the role gate, checked once per call rather than once per row
     where (select public.can_read_operational()
                   or session_user not in ('authenticator', 'anon', 'authenticated'));
$$;

create or replace function public.health_head_rows()
returns table (lot_id uuid, tag_number integer, arrival_date date, weight_lb numeric, src text)
language sql
stable
security definer
set search_path = public
as $$
    with gate as (
        select (public.can_read_operational()
                or session_user not in ('authenticator', 'anon', 'authenticated')) as ok
    ), b as materialized (
        select * from public.health_lot_basis_rows()
    )
    select lt.lot_id, lt.tag_number, dr.receipt_date, iv.total_weight_lb / nullif(iv.head_count, 0), 'receipt'::text
      from b
      join public.lot_tags lt          on lt.lot_id = b.lot_id
      join public.delivery_receipts dr on dr.id = lt.delivery_receipt_id
      left join public.invoices iv     on iv.id = dr.invoice_id
     where b.excluded_reason is null and b.basis = 'receipts'
       and (select ok from gate)
    union all
    select el.lot_id, g.tag, el.arrival_date, el.avg_weight_lb, 'estimated'
      from public.health_estimated_loads el
      join b on b.lot_id = el.lot_id and b.excluded_reason is null
      cross join lateral generate_series(el.tag_start, el.tag_end) as g(tag)
     where (select ok from gate);
$$;

create or replace function public.health_pull_rows()
returns table (lot_id uuid, tag_number integer, first_pull date, second_pull date, pull_days bigint, entries numeric)
language sql
stable
security definer
set search_path = public
as $$
    with d as (
        select de.lot_id,
               btrim(de.tag_number)::int as tag_number,
               (de.event_datetime at time zone 'America/Chicago')::date as pull_date
          from public.doctoring_events de
         where de.tag_number ~ '^\s*\d{1,9}\s*$'
           and not coalesce(de.no_tag, false)
           and (select public.can_read_operational()
                       or session_user not in ('authenticator', 'anon', 'authenticated'))
    ), days as (
        select d.lot_id, d.tag_number, d.pull_date, count(*) as entries
          from d group by d.lot_id, d.tag_number, d.pull_date
    )
    select days.lot_id, days.tag_number,
           min(days.pull_date),
           (array_agg(days.pull_date order by days.pull_date))[2],
           count(*),
           sum(days.entries)
      from days group by days.lot_id, days.tag_number;
$$;

create or replace function public.health_death_rows()
returns table (event_id uuid, lot_id uuid, event_type text, event_date date, tag_number text, cause text, head_count integer)
language sql
stable
security definer
set search_path = public
as $$
    select e.id, e.lot_id, e.event_type, e.event_date, e.tag_number, e.cause, e.head_count
      from public.lot_events e
     where ((e.event_type = 'death')
            or (e.event_type = 'adjustment' and e.head_count < 0 and lower(btrim(coalesce(e.cause, ''))) = 'missing'))
       and (select public.can_read_operational()
                   or session_user not in ('authenticator', 'anon', 'authenticated'));
$$;

create or replace view public.health_lot_basis with (security_invoker = true) as
select * from public.health_lot_basis_rows();

create or replace view public.health_head_base with (security_invoker = true) as
select * from public.health_head_rows();

create or replace view public.health_pull_days with (security_invoker = true) as
select * from public.health_pull_rows();

create or replace view public.health_death_days with (security_invoker = true) as
with hb as materialized (
    select h.lot_id, h.tag_number, min(h.arrival_date) as arrival_date
      from public.health_head_base h group by h.lot_id, h.tag_number
)
select e.event_id, e.lot_id, e.event_type, e.event_date, e.tag_number, e.cause,
       abs(e.head_count) as head,
       (e.event_type = 'adjustment' or lower(btrim(coalesce(e.cause, ''))) = 'missing from shipping') as is_short,
       ta.arrival_date is not null as tag_matched,
       e.event_date - coalesce(ta.arrival_date, c.weighted_arrival) as death_day,
       coalesce(c.end_date - ta.arrival_date, c.end_date - c.weighted_arrival) as day_reached
  from public.health_death_rows() e
  join public.lot_health_class c on c.lot_id = e.lot_id
  left join hb ta on ta.lot_id = e.lot_id
                 and ta.tag_number = case when e.tag_number ~ '^\s*\d{1,9}\s*$' then btrim(e.tag_number)::int end;

-- lot_health_class: the weight band and season are looked up per head, and
-- each probe into the table paid its RLS check. Read each table once.
create or replace view public.lot_health_class with (security_invoker = true) as
with bands as materialized (       -- read once: a per-head lookup into the
    select * from public.health_class_bands   -- table itself pays RLS on every probe
), seasons as materialized (
    select * from public.health_seasons
), h as (
    select hb.*, s.season_code as head_season,
           (select c.class_code from bands c
             where hb.weight_lb >= c.min_lb and (c.max_lb is null or hb.weight_lb < c.max_lb)) as head_class,
           min(hb.arrival_date) over (partition by hb.lot_id) as first_arrival
      from public.health_head_base hb
      join seasons s on s.month = extract(month from hb.arrival_date)::int
), agg as (
    select lot_id,
           count(*)                                              as head,
           avg(weight_lb)                                        as weighted_weight_lb,
           min(arrival_date)                                     as first_arrival,
           max(arrival_date)                                     as last_arrival,
           min(first_arrival) + round(avg(arrival_date - first_arrival))::int as weighted_arrival,
           count(distinct head_season)                           as n_seasons,
           count(distinct head_class)                            as n_classes
      from h group by lot_id
), ruled as (
    select a.*,
           (select c.class_code from bands c
             where a.weighted_weight_lb >= c.min_lb and (c.max_lb is null or a.weighted_weight_lb < c.max_lb)) as rule_class,
           (select s.season_code from seasons s
             where s.month = extract(month from a.weighted_arrival)::int) as rule_season
      from agg a
)
select l.id as lot_id,
       l.lot_number,
       l.source                                   as order_buyer,
       (l.closed_at is not null)                  as is_closed,
       least(coalesce(l.closed_at::date, public.ranch_today()), public.ranch_today()) as end_date,
       r.head,
       round(r.weighted_weight_lb, 2)             as weighted_weight_lb,
       r.first_arrival, r.last_arrival, r.weighted_arrival,
       least(coalesce(l.closed_at::date, public.ranch_today()), public.ranch_today()) - r.weighted_arrival as current_day,
       r.rule_class, r.rule_season,
       coalesce(o.class_override,  r.rule_class)  as class_code,
       coalesce(o.season_override, r.rule_season) as season_code,
       cb.label as class_label,
       sd.label as season_label,
       (r.n_classes > 1)                          as class_span_flag,
       (r.n_seasons > 1)                          as season_span_flag,
       (o.lot_id is not null)                     as override_applied,
       o.reason                                   as override_reason,
       ((r.n_classes > 1 and o.class_override is null) or (r.n_seasons > 1 and o.season_override is null)) as needs_review,
       b.basis
  from ruled r
  join public.lots l                     on l.id = r.lot_id
  join public.health_lot_basis b         on b.lot_id = r.lot_id
  left join public.lot_health_overrides o on o.lot_id = r.lot_id
  left join public.health_class_bands cb on cb.class_code = coalesce(o.class_override,  r.rule_class)
  left join public.health_season_defs sd on sd.season_code = coalesce(o.season_override, r.rule_season);

-- lot_death_capture: 'pulled before death' was a subquery per death over
-- doctoring_events, RLS on every row every time. The first pull per tag
-- is computed once; pulled before = first pull on or before the death.
create or replace view public.lot_death_capture with (security_invoker = true) as
with first_pull as materialized (   -- one pass over doctoring, not one per death
    select d.lot_id, btrim(d.tag_number) as tag, min((d.event_datetime at time zone 'America/Chicago')::date) as first_date
      from public.doctoring_events d
     where d.tag_number is not null
     group by d.lot_id, btrim(d.tag_number)
), ev as (
    select e.lot_id, e.event_date, abs(e.head_count) as head,
           (e.event_type = 'adjustment' or lower(btrim(coalesce(e.cause, ''))) = 'missing from shipping') as is_short,
           (e.tag_number is not null and btrim(e.tag_number) <> '') as tagged,
           coalesce(fp.first_date <= e.event_date, false) as pulled_before
      from public.lot_events e
      join public.lots l on l.id = e.lot_id and not l.is_test
      left join first_pull fp on fp.lot_id = e.lot_id and fp.tag = btrim(e.tag_number)
     where e.event_type = 'death'
        or (e.event_type = 'adjustment' and e.head_count < 0 and lower(btrim(coalesce(e.cause, ''))) = 'missing')
)
select ev.lot_id, l.lot_number, (l.closed_at is not null) as is_closed,
       case when grouping(date_trunc('month', ev.event_date)) = 1 then null
            else date_trunc('month', ev.event_date)::date end                           as month,
       (grouping(date_trunc('month', ev.event_date)) = 1)                               as is_total,
       coalesce(sum(ev.head) filter (where not ev.is_short), 0)::int                     as dead,
       coalesce(sum(ev.head) filter (where not ev.is_short and ev.tagged), 0)::int       as tagged,
       round(100.0 * coalesce(sum(ev.head) filter (where not ev.is_short and ev.tagged), 0)
                   / nullif(sum(ev.head) filter (where not ev.is_short), 0), 1)          as tag_capture_pct,
       coalesce(sum(ev.head) filter (where not ev.is_short and ev.tagged and ev.pulled_before), 0)::int     as tagged_pulled_before,
       coalesce(sum(ev.head) filter (where not ev.is_short and ev.tagged and not ev.pulled_before), 0)::int as tagged_never_pulled,
       coalesce(sum(ev.head) filter (where ev.is_short), 0)::int                          as shorts
  from ev
  join public.lots l on l.id = ev.lot_id
 group by grouping sets ((ev.lot_id, l.lot_number, l.closed_at, date_trunc('month', ev.event_date)),
                         (ev.lot_id, l.lot_number, l.closed_at));

drop function if exists public.health_receipt_weights();

revoke all on function public.health_lot_basis_rows() from public, anon;
revoke all on function public.health_head_rows()      from public, anon;
revoke all on function public.health_pull_rows()      from public, anon;
revoke all on function public.health_death_rows()     from public, anon;
grant execute on function public.health_lot_basis_rows() to authenticated;
grant execute on function public.health_head_rows()      to authenticated;
grant execute on function public.health_pull_rows()      to authenticated;
grant execute on function public.health_death_rows()     to authenticated;

-- verify: views still invoker and read-only, anon locked out of the functions
do $$
declare v_bad text;
begin
    select string_agg(c.relname, ', ') into v_bad
      from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
       and c.relname in ('health_lot_basis','health_head_base','health_pull_days','health_death_days','lot_health_class','lot_death_capture')
       and not coalesce('security_invoker=true' = any (c.reloptions), false);
    if v_bad is not null then raise exception 'view(s) lost security_invoker: %', v_bad; end if;

    select string_agg(p.proname, ', ') into v_bad
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('health_lot_basis_rows','health_head_rows','health_pull_rows','health_death_rows')
       and (has_function_privilege('anon', p.oid, 'execute')
            or not p.prosecdef
            or not coalesce(p.proconfig::text like '%search_path=public%', false));
    if v_bad is not null then raise exception 'function(s) anon-callable, not definer or search_path unpinned: %', v_bad; end if;

    if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'health_receipt_weights') then
        raise exception 'health_receipt_weights() still present';
    end if;
    raise notice 'health curves speed: 4 gated functions, views invoker';
end $$;

commit;
