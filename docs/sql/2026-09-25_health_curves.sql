-- 2026-09-25  Health curves: pull / re-pull / death baselines by weight class
-- and season, and each lot measured against its own cell with itself left out.
--
-- Design and every rule: docs/health-curves.md. Decided by John 2026-09-25.
-- Summary of the rules this file enforces:
--   * Class and season are per LOT: head-weighted average invoice weight and
--     head-weighted arrival date. Bands are half-open [min_lb, max_lb), so
--     650.73 lb is 551-650. A lot whose loads straddle a band or a season is
--     FLAGGED; lot_health_overrides wins.
--   * Day on ranch is per head: event date (America/Chicago) - that head's
--     receipt date. An untagged death takes the lot's weighted arrival.
--   * First pull = a tag's first doctoring DAY; second pull = any later day.
--     Several entries on one day count once and show on health_anomalies.
--   * Cumulative, per head received. A head counts toward day d only once it
--     has reached day d (today, or the lot's close). Dead and sold head stay
--     in the denominator - this is incidence per head received.
--   * A lot is never part of its own baseline (lot_health_status subtracts
--     the lot's own counts from its cell).
--   * Shorts (cause 'missing from shipping', or an adjustment with cause
--     'missing') are NOT deaths on any curve - they have no day on ranch.
--     They are counted on their own and in loss % hd at close.
--   * Estimates are stored at the checkpoints and interpolated linearly per
--     day. Seeded by borrowing from the nearest OTHER measured cell. Measured
--     replaces an estimate day by day; estimate rows are never deleted.
--   * 37X: its receipts cover 8 of 369 hd, so its loads are ESTIMATED from
--     tag order and invoice dates in health_estimated_loads. Delete those
--     rows and 37X drops out again with its reason on health_excluded_lots.
--
-- Access: every table reads through can_read_operational() (no dollars;
-- crew need the lot Health card and the death capture report); every write
-- is owner only. health_receipt_weights() is SECURITY DEFINER for the same
-- reason lot_projected_weight is: crew cannot read invoices, and the weight
-- class is built from invoice weight. It returns weight per receipt and
-- nothing else, and nothing at all to a caller who cannot read operations.
--
-- Touches NO existing table. Idempotent. Paste WITHOUT begin/commit into the
-- SQL editor; strip them for apply_migration.
begin;

-- ---------------------------------------------------------------- settings

create table if not exists public.health_class_bands (
    class_code  text primary key,
    label       text not null,
    min_lb      numeric not null,
    max_lb      numeric,                         -- exclusive; NULL = no ceiling
    sort_order  integer not null unique,
    updated_by  uuid default auth.uid(),
    updated_at  timestamptz not null default now(),
    constraint health_class_bands_range check (max_lb is null or max_lb > min_lb)
);
insert into public.health_class_bands (class_code, label, min_lb, max_lb, sort_order) values
    ('200-400', '200–400',   0, 401, 1),
    ('401-550', '401–550', 401, 551, 2),
    ('551-650', '551–650', 551, 651, 3),
    ('651+',    '651+',    651, null, 4)
on conflict (class_code) do nothing;

create table if not exists public.health_season_defs (
    season_code  text primary key,
    label        text not null,
    cycle_order  integer not null unique        -- position round the year; nearest = cyclic distance
);
insert into public.health_season_defs (season_code, label, cycle_order) values
    ('dec-mar', 'Dec–Mar', 1),
    ('apr-may', 'Apr–May', 2),
    ('jun-sep', 'Jun–Sep', 3),
    ('oct-nov', 'Oct–Nov', 4)
on conflict (season_code) do nothing;

create table if not exists public.health_seasons (
    month        integer primary key check (month between 1 and 12),
    season_code  text not null references public.health_season_defs(season_code) on update cascade,
    updated_by   uuid default auth.uid(),
    updated_at   timestamptz not null default now()
);
insert into public.health_seasons (month, season_code) values
    (12,'dec-mar'),(1,'dec-mar'),(2,'dec-mar'),(3,'dec-mar'),
    (4,'apr-may'),(5,'apr-may'),
    (6,'jun-sep'),(7,'jun-sep'),(8,'jun-sep'),(9,'jun-sep'),
    (10,'oct-nov'),(11,'oct-nov')
on conflict (month) do nothing;

create table if not exists public.lot_health_overrides (
    lot_id           uuid primary key references public.lots(id) on delete cascade,
    class_override   text references public.health_class_bands(class_code) on update cascade,
    season_override  text references public.health_season_defs(season_code) on update cascade,
    reason           text not null check (btrim(reason) <> ''),
    set_by           uuid default auth.uid(),
    set_at           timestamptz not null default now(),
    constraint lot_health_overrides_something check (class_override is not null or season_override is not null)
);

create table if not exists public.health_estimated_loads (
    id             uuid primary key default gen_random_uuid(),
    lot_id         uuid not null references public.lots(id) on delete cascade,
    invoice_id     uuid references public.invoices(id) on delete set null,
    arrival_date   date not null,
    tag_start      integer not null,
    tag_end        integer not null,
    head           integer not null,
    avg_weight_lb  numeric not null check (avg_weight_lb > 0),
    basis          text not null check (btrim(basis) <> ''),
    set_by         uuid default auth.uid(),
    set_at         timestamptz not null default now(),
    constraint health_estimated_loads_range check (tag_end >= tag_start and head = tag_end - tag_start + 1)
);
create index if not exists health_estimated_loads_lot_idx on public.health_estimated_loads (lot_id);

create table if not exists public.health_baseline_estimates (
    id               uuid primary key default gen_random_uuid(),
    class_code       text not null references public.health_class_bands(class_code) on update cascade,
    season_code      text not null references public.health_season_defs(season_code) on update cascade,
    metric           text not null check (metric in ('pull1_pct_head','pull2_pct_pull1','dead_pct_pull1','dead_pct_head','loss_pct_head')),
    checkpoint       text not null check (checkpoint in ('7','14','21','30','45','60','90','120','180','close')),
    value_pct        numeric not null check (value_pct >= 0),
    source           text not null check (source in ('borrowed','john')),
    borrowed_class   text,
    borrowed_season  text,
    borrowed_lots    integer,
    borrowed_head    integer,
    set_by           uuid default auth.uid(),
    set_at           timestamptz not null default now(),
    superseded_at    timestamptz,
    superseded_by    uuid,
    constraint health_baseline_estimates_borrowed check (source = 'john' or (borrowed_class is not null and borrowed_season is not null)),
    constraint health_baseline_estimates_loss_at_close check (metric <> 'loss_pct_head' or checkpoint = 'close')
);
create unique index if not exists health_baseline_estimates_active_uniq
    on public.health_baseline_estimates (class_code, season_code, metric, checkpoint)
    where superseded_at is null;

create table if not exists public.health_flag_thresholds (
    metric        text primary key check (metric in ('pull1_pct_head','pull2_pct_pull1','dead_pct_pull1','dead_pct_head','loss_pct_head')),
    threshold_pp  numeric check (threshold_pp is null or threshold_pp > 0),   -- percentage points ABOVE baseline; NULL = never flag
    set_by        uuid default auth.uid(),
    set_at        timestamptz not null default now()
);
insert into public.health_flag_thresholds (metric) values
    ('pull1_pct_head'),('pull2_pct_pull1'),('dead_pct_pull1'),('dead_pct_head'),('loss_pct_head')
on conflict (metric) do nothing;

-- 37X: loads estimated from tag order. Tags went on in sequence at
-- processing, so the three real invoices (12-04 177 hd, 12-07 78 hd, 12-21
-- 106 hd) take 4213-4389, 4390-4467 and 4468-4573 in that order. Checked
-- 2026-09-25 against the pulls: no tag pulled before its estimated arrival.
-- The 8 hd 'internal' invoice of 2026-09-03 is a book correction, not an
-- arrival, and is left out.
do $$
declare v_lot uuid; rec record; v_start integer := 4213;
begin
    select id into v_lot from public.lots where lot_number = '37X';
    if v_lot is null then
        raise notice '37X not found - no estimated loads seeded';
        return;
    end if;
    if exists (select 1 from public.health_estimated_loads where lot_id = v_lot) then
        raise notice '37X estimated loads already present - left alone';
        return;
    end if;
    for rec in
        select i.id, i.invoice_date, i.head_count, i.total_weight_lb / i.head_count as w
          from public.invoices i
         where i.lot_id = v_lot and coalesce(i.invoice_number, '') <> 'internal'
         order by i.invoice_date, i.id
    loop
        insert into public.health_estimated_loads
            (lot_id, invoice_id, arrival_date, tag_start, tag_end, head, avg_weight_lb, basis)
        values
            (v_lot, rec.id, rec.invoice_date, v_start, v_start + rec.head_count - 1, rec.head_count, rec.w,
             'Estimated 2026-09-25 from tag order and invoice dates: receipts cover 8 of 369 hd. '
             || 'Tags assumed applied in sequence from 4213.');
        v_start := v_start + rec.head_count;
    end loop;
    if v_start - 1 <> 4573 then
        raise exception '37X estimated loads ended at tag %, expected 4573 - invoices changed, review before seeding', v_start - 1;
    end if;
end $$;

-- ---------------------------------------------------------------- weights

-- Weight per receipt, for a caller who may not read invoices (crew).
-- DEFINER: same reason as lot_projected_weight. Returns weight only.
create or replace function public.health_receipt_weights()
returns table (delivery_receipt_id uuid, avg_weight_lb numeric)
language sql
stable
security definer
set search_path = public
as $$
    select r.id, i.total_weight_lb / nullif(i.head_count, 0)
      from public.delivery_receipts r
      join public.invoices i on i.id = r.invoice_id
     where public.can_read_operational()
        -- a migration or the SQL editor (no API role) sees the weights too;
        -- session_user cannot be changed by a client
        or session_user not in ('authenticator', 'anon', 'authenticated');
$$;

-- ---------------------------------------------------------------- views

-- Which lots are in, and on what basis.
create or replace view public.health_lot_basis with (security_invoker = true) as
select l.id as lot_id,
       l.lot_number,
       coalesce(r.head, 0)  as receipt_head,
       coalesce(t.tags, 0)  as receipt_tags,
       coalesce(i.head, 0)  as invoice_head,
       e.head               as estimated_head,
       case when e.head is not null then 'estimated_loads' else 'receipts' end as basis,
       case
           when l.is_test     then 'test lot'
           when l.is_feed_pen then 'feed pen'
           when e.head is not null then null
           when r.head is null then 'no delivery receipts'
           when i.head > 0 and r.head < 0.8 * i.head
                then format('receipts cover %s of %s hd', r.head, i.head)
           when coalesce(t.tags, 0) = 0 then 'no tags on the receipts'
       end as excluded_reason
  from public.lots l
  left join (select lot_id, sum(head_count) as head from public.delivery_receipts group by lot_id) r on r.lot_id = l.id
  left join (select t.lot_id, count(*) as tags
               from public.lot_tags t
               join public.delivery_receipts dr on dr.id = t.delivery_receipt_id
              group by t.lot_id) t on t.lot_id = l.id
  left join (select lot_id, sum(head_count) as head from public.invoices group by lot_id) i on i.lot_id = l.id
  left join (select lot_id, sum(head) as head from public.health_estimated_loads group by lot_id) e on e.lot_id = l.id;

create or replace view public.health_excluded_lots with (security_invoker = true) as
select lot_id, lot_number,
       case when excluded_reason is not null then 'excluded' else 'included — estimated loads' end as status,
       coalesce(excluded_reason,
                format('receipts cover %s of %s hd; %s hd placed on loads estimated from tag order',
                       receipt_head, invoice_head, estimated_head)) as reason
  from public.health_lot_basis
 where excluded_reason is not null or basis = 'estimated_loads';

-- One row per head received, with its own arrival and weight.
create or replace view public.health_head_base with (security_invoker = true) as
select b.lot_id, t.tag_number, r.receipt_date as arrival_date, w.avg_weight_lb as weight_lb, 'receipt'::text as src
  from public.health_lot_basis b
  join public.lot_tags t          on t.lot_id = b.lot_id
  join public.delivery_receipts r on r.id = t.delivery_receipt_id
  left join public.health_receipt_weights() w on w.delivery_receipt_id = r.id
 where b.excluded_reason is null and b.basis = 'receipts'
union all
select e.lot_id, g.tag, e.arrival_date, e.avg_weight_lb, 'estimated'
  from public.health_estimated_loads e
  join public.health_lot_basis b on b.lot_id = e.lot_id and b.excluded_reason is null
  cross join lateral generate_series(e.tag_start, e.tag_end) as g(tag);

-- Per lot: class, season, flags, override.
create or replace view public.lot_health_class with (security_invoker = true) as
with h as (
    select hb.*, s.season_code as head_season,
           (select c.class_code from public.health_class_bands c
             where hb.weight_lb >= c.min_lb and (c.max_lb is null or hb.weight_lb < c.max_lb)) as head_class,
           min(hb.arrival_date) over (partition by hb.lot_id) as first_arrival
      from public.health_head_base hb
      join public.health_seasons s on s.month = extract(month from hb.arrival_date)::int
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
           (select c.class_code from public.health_class_bands c
             where a.weighted_weight_lb >= c.min_lb and (c.max_lb is null or a.weighted_weight_lb < c.max_lb)) as rule_class,
           (select s.season_code from public.health_seasons s
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

-- Pull days per (lot, tag): first day, second day, and how many entries.
create or replace view public.health_pull_days with (security_invoker = true) as
with d as (
    select de.lot_id,
           btrim(de.tag_number)::int as tag_number,
           (de.event_datetime at time zone 'America/Chicago')::date as pull_date
      from public.doctoring_events de
     where de.tag_number ~ '^\s*\d{1,9}\s*$'
       and not coalesce(de.no_tag, false)
), days as (
    select lot_id, tag_number, pull_date, count(*) as entries
      from d group by lot_id, tag_number, pull_date
)
select lot_id, tag_number,
       min(pull_date)                                       as first_pull,
       (array_agg(pull_date order by pull_date))[2]         as second_pull,
       count(*)                                             as pull_days,
       sum(entries)                                         as entries
  from days group by lot_id, tag_number;

-- One row per head: its days reached and its pull days.
create or replace view public.health_head_days with (security_invoker = true) as
select h.lot_id, c.class_code, c.season_code, h.tag_number, h.arrival_date,
       c.end_date - h.arrival_date   as day_reached,
       p.first_pull  - h.arrival_date as pull1_day,
       p.second_pull - h.arrival_date as pull2_day
  from public.health_head_base h
  join public.lot_health_class c on c.lot_id = h.lot_id
  left join public.health_pull_days p on p.lot_id = h.lot_id and p.tag_number = h.tag_number;

-- Deaths and shorts on included lots, each with its day on ranch.
create or replace view public.health_death_days with (security_invoker = true) as
select e.id as event_id, e.lot_id, e.event_type, e.event_date, e.tag_number, e.cause,
       abs(e.head_count) as head,
       (e.event_type = 'adjustment' or lower(btrim(coalesce(e.cause, ''))) = 'missing from shipping') as is_short,
       ta.arrival_date is not null as tag_matched,
       e.event_date - coalesce(ta.arrival_date, c.weighted_arrival) as death_day,
       coalesce(c.end_date - ta.arrival_date, c.end_date - c.weighted_arrival) as day_reached
  from public.lot_events e
  join public.lot_health_class c on c.lot_id = e.lot_id
  left join lateral (
      select min(h.arrival_date) as arrival_date
        from public.health_head_base h
       where h.lot_id = e.lot_id
         and e.tag_number ~ '^\s*\d{1,9}\s*$'
         and h.tag_number = btrim(e.tag_number)::int
  ) ta on true
 where (e.event_type = 'death')
    or (e.event_type = 'adjustment' and e.head_count < 0 and lower(btrim(coalesce(e.cause, ''))) = 'missing');

-- Each lot's own cumulative counts: days 0-180, and a close row for a closed lot.
-- The base views are pulled once each (MATERIALIZED) - inlined, every
-- reference would recompute the whole head pipeline.
create or replace view public.health_curve_lot_daily with (security_invoker = true) as
with c as materialized (
    select lot_id, class_code, season_code, is_closed from public.lot_health_class
), h as materialized (
    select lot_id, day_reached, pull1_day, pull2_day from public.health_head_days
), x as materialized (
    select lot_id, head, is_short, death_day, day_reached from public.health_death_days
), hd as (
    select h.lot_id, g.d,
           count(*)                                        as head,
           count(*) filter (where h.pull1_day <= g.d)      as pull1,
           count(*) filter (where h.pull2_day <= g.d)      as pull2
      from h
      join generate_series(0, 180) as g(d) on h.day_reached >= g.d
     group by h.lot_id, g.d
), dd as (
    select x.lot_id, g.d, sum(x.head) as dead
      from x
      join generate_series(0, 180) as g(d) on x.day_reached >= g.d and x.death_day <= g.d
     where not x.is_short
     group by x.lot_id, g.d
), h_close as (
    select lot_id, count(*) as head,
           count(*) filter (where pull1_day is not null) as pull1,
           count(*) filter (where pull2_day is not null) as pull2
      from h group by lot_id
), x_close as (
    select lot_id,
           coalesce(sum(head) filter (where not is_short), 0) as dead,
           coalesce(sum(head) filter (where is_short), 0)     as shorts
      from x group by lot_id
), strays as (
    select lot_id, sum(head_count) as back
      from public.lot_events
     where event_type = 'adjustment' and head_count > 0 and lower(btrim(coalesce(cause, ''))) = 'stray_return'
     group by lot_id
)
select c.lot_id, c.class_code, c.season_code, false as is_close, hd.d as day,
       hd.head::int, hd.pull1::int, hd.pull2::int, coalesce(dd.dead, 0)::int as dead, 0 as shorts
  from hd
  join c on c.lot_id = hd.lot_id
  left join dd on dd.lot_id = hd.lot_id and dd.d = hd.d
union all
select c.lot_id, c.class_code, c.season_code, true, null,
       hc.head::int, hc.pull1::int, hc.pull2::int, coalesce(xc.dead, 0)::int,
       greatest(0, coalesce(xc.shorts, 0) - coalesce(st.back, 0))::int
  from c
  join h_close hc on hc.lot_id = c.lot_id
  left join x_close xc on xc.lot_id = c.lot_id
  left join strays st on st.lot_id = c.lot_id
 where c.is_closed;

-- The cells: sums of the lots, with the rates.
create or replace view public.health_curve_measured with (security_invoker = true) as
select d.class_code, d.season_code, d.is_close, d.day,
       count(*) filter (where d.head > 0)                          as lots,
       sum(d.head)::int                                            as head,
       sum(d.pull1)::int as pull1, sum(d.pull2)::int as pull2,
       sum(d.dead)::int  as dead,  sum(d.shorts)::int as shorts,
       round(100.0 * sum(d.pull1) / nullif(sum(d.head), 0), 2)     as pull1_pct_head,
       round(100.0 * sum(d.pull2) / nullif(sum(d.pull1), 0), 2)    as pull2_pct_pull1,
       round(100.0 * sum(d.dead)  / nullif(sum(d.pull1), 0), 2)    as dead_pct_pull1,
       round(100.0 * sum(d.dead)  / nullif(sum(d.head), 0), 2)     as dead_pct_head,
       case when d.is_close then round(100.0 * (sum(d.dead) + sum(d.shorts)) / nullif(sum(d.head), 0), 2) end as loss_pct_head,
       string_agg(l.lot_number, ', ' order by l.lot_number) filter (where d.head > 0) as lot_numbers
  from public.health_curve_lot_daily d
  join public.lots l on l.id = d.lot_id
 group by d.class_code, d.season_code, d.is_close, d.day;

-- Active estimates, with the day each checkpoint stands for and its label.
create or replace view public.health_estimate_points with (security_invoker = true) as
select e.class_code, e.season_code, e.metric, e.checkpoint,
       case when e.checkpoint = 'close' then null else e.checkpoint::int end as cp_day,
       e.value_pct, e.source, e.borrowed_class, e.borrowed_season, e.borrowed_lots, e.borrowed_head,
       case when e.source = 'john' then 'Assumed — John'
            else 'Assumed — borrowed from ' || coalesce(bc.label, e.borrowed_class) || ' ' || coalesce(bs.label, e.borrowed_season)
                 || coalesce(' · ' || e.borrowed_lots || case when e.borrowed_lots = 1 then ' lot, ' else ' lots, ' end
                             || to_char(e.borrowed_head, 'FM999,999,999') || ' hd', '')
       end as provenance,
       e.set_at, e.set_by
  from public.health_baseline_estimates e
  left join public.health_class_bands bc on bc.class_code  = e.borrowed_class
  left join public.health_season_defs bs on bs.season_code = e.borrowed_season
 where e.superseded_at is null;

-- Estimates per day: straight line between the two nearest checkpoints, 0 at day 0.
create or replace view public.health_estimate_daily with (security_invoker = true) as
with pts as materialized (
    select class_code, season_code, metric, cp_day, value_pct, provenance
      from public.health_estimate_points where cp_day is not null
    union all
    select distinct class_code, season_code, metric, 0, 0::numeric, null::text
      from public.health_estimate_points where cp_day is not null
), seg as (
    select p.*,
           lead(cp_day)     over w as next_day,
           lead(value_pct)  over w as next_value,
           lead(provenance) over w as next_provenance
      from pts p
    window w as (partition by class_code, season_code, metric order by cp_day)
)
select s.class_code, s.season_code, s.metric, g.d as day,
       case when s.next_day is null or g.d = s.cp_day then s.value_pct
            else s.value_pct + (s.next_value - s.value_pct) * (g.d - s.cp_day) / (s.next_day - s.cp_day)
       end as value_pct,
       case when s.provenance is null then s.next_provenance
            when g.d = s.cp_day or s.next_provenance is null or s.next_provenance = s.provenance then s.provenance
            else s.provenance || ' / ' || s.next_provenance
       end as provenance
  from seg s
  join generate_series(0, 180) as g(d)
    on g.d >= s.cp_day and (s.next_day is null or g.d < s.next_day);

-- The baseline, whole cells (every lot in): measured where any lot has
-- reached the day, else the estimate. Long form: one row per metric.
create or replace view public.health_baseline with (security_invoker = true) as
with cells as (
    select c.class_code, c.label as class_label, c.sort_order, s.season_code, s.label as season_label, s.cycle_order
      from public.health_class_bands c cross join public.health_season_defs s
), pts as (
    select g.d as day, false as is_close from generate_series(0, 180) g(d)
    union all select null, true
), metrics(metric, m_order) as (
    values ('pull1_pct_head',1),('pull2_pct_pull1',2),('dead_pct_pull1',3),('dead_pct_head',4),('loss_pct_head',5)
), grid as (
    select c.*, p.day, p.is_close, m.metric, m.m_order
      from cells c cross join pts p cross join metrics m
     where m.metric <> 'loss_pct_head' or p.is_close
), ed as materialized (
    select * from public.health_estimate_daily
), ep as materialized (
    select * from public.health_estimate_points where checkpoint = 'close'
), meas as materialized (
    select m.*, v.metric, v.value_pct
      from public.health_curve_measured m
      cross join lateral (values ('pull1_pct_head', m.pull1_pct_head), ('pull2_pct_pull1', m.pull2_pct_pull1),
                                 ('dead_pct_pull1', m.dead_pct_pull1), ('dead_pct_head', m.dead_pct_head),
                                 ('loss_pct_head', m.loss_pct_head)) v(metric, value_pct)
     where m.lots > 0
)
select g.class_code, g.class_label, g.season_code, g.season_label, g.day, g.is_close, g.metric,
       coalesce(ms.value_pct, round(case when g.is_close then ep.value_pct else ed.value_pct end, 2)) as value_pct,
       case when ms.value_pct is not null then 'measured'
            when coalesce(ep.value_pct, ed.value_pct) is not null then 'assumed' end as kind,
       case when ms.value_pct is not null
                then 'Measured · ' || ms.lots || case when ms.lots = 1 then ' lot, ' else ' lots, ' end
                     || to_char(ms.head, 'FM999,999,999') || ' hd'
            when g.is_close then ep.provenance
            else ed.provenance end as provenance,
       ms.lots, ms.head, ms.lot_numbers,
       g.sort_order, g.cycle_order, g.m_order
  from grid g
  left join meas ms on ms.class_code = g.class_code and ms.season_code = g.season_code
                   and ms.is_close = g.is_close and coalesce(ms.day, -1) = coalesce(g.day, -1) and ms.metric = g.metric
  left join ed on not g.is_close and ed.class_code = g.class_code
                   and ed.season_code = g.season_code and ed.metric = g.metric and ed.day = g.day
  left join ep on g.is_close and ep.class_code = g.class_code
                   and ep.season_code = g.season_code and ep.metric = g.metric;

-- Each lot against its own cell WITH ITSELF LEFT OUT.
-- The baseline is an EXPECTATION over the lot's own head: each head is
-- scored at the day it has actually reached, so a lot still receiving is
-- not measured at one average day. Measured wherever another lot in the
-- cell has reached that day; the estimate elsewhere. A closed lot compares
-- close to close.
create or replace view public.lot_health_status with (security_invoker = true) as
with lc as materialized (
    select * from public.lot_health_class
), daily as materialized (
    select * from public.health_curve_lot_daily
), hdays as materialized (
    select lot_id, day_reached, pull1_day, pull2_day from public.health_head_days
), own_close as (
    select * from daily where is_close
), own_day as (
    select * from daily where not is_close
), cell_day as (
    select class_code, season_code, day, sum(head) as head, sum(pull1) as pull1, sum(pull2) as pull2,
           sum(dead) as dead, count(*) filter (where head > 0) as lots
      from daily where not is_close group by class_code, season_code, day
), cell_close as (
    select class_code, season_code, sum(head) as head, sum(pull1) as pull1, sum(pull2) as pull2,
           sum(dead) as dead, sum(shorts) as shorts, count(*) filter (where head > 0) as lots
      from daily where is_close group by class_code, season_code
), est as materialized (
    select class_code, season_code, day,
           max(value_pct) filter (where metric = 'pull1_pct_head')  / 100.0 as p1,
           max(value_pct) filter (where metric = 'pull2_pct_pull1') / 100.0 as p2r,
           max(value_pct) filter (where metric = 'dead_pct_pull1')  / 100.0 as dr,
           max(value_pct) filter (where metric = 'dead_pct_head')   / 100.0 as dh,
           max(provenance) filter (where metric = 'pull1_pct_head') as provenance
      from public.health_estimate_daily group by class_code, season_code, day
), est_close as materialized (
    select class_code, season_code,
           max(value_pct) filter (where metric = 'pull1_pct_head')  / 100.0 as p1,
           max(value_pct) filter (where metric = 'pull2_pct_pull1') / 100.0 as p2r,
           max(value_pct) filter (where metric = 'dead_pct_pull1')  / 100.0 as dr,
           max(value_pct) filter (where metric = 'dead_pct_head')   / 100.0 as dh,
           max(value_pct) filter (where metric = 'loss_pct_head')   / 100.0 as lh,
           max(provenance) filter (where metric = 'pull1_pct_head') as provenance
      from public.health_estimate_points where checkpoint = 'close' group by class_code, season_code
), heads_by_day as (         -- open lots: how many head sit at each day reached (capped at 180)
    select h.lot_id, least(h.day_reached, 180) as day, count(*) as n
      from hdays h
      join lc on lc.lot_id = h.lot_id and not lc.is_closed
     group by h.lot_id, least(h.day_reached, 180)
), excl_day as (             -- per open lot, per day it needs: the cell less the lot itself
    select hb.lot_id, hb.day, hb.n,
           cd.head  - coalesce(od.head, 0)  as head,
           cd.pull1 - coalesce(od.pull1, 0) as pull1,
           cd.pull2 - coalesce(od.pull2, 0) as pull2,
           cd.dead  - coalesce(od.dead, 0)  as dead,
           cd.lots  - case when coalesce(od.head, 0) > 0 then 1 else 0 end as lots,
           e.p1 as e_p1, e.p2r as e_p2r, e.dr as e_dr, e.dh as e_dh
      from heads_by_day hb
      join lc on lc.lot_id = hb.lot_id
      left join cell_day cd on cd.class_code = lc.class_code and cd.season_code = lc.season_code and cd.day = hb.day
      left join own_day od on od.lot_id = hb.lot_id and od.day = hb.day
      left join est e on e.class_code = lc.class_code and e.season_code = lc.season_code and e.day = hb.day
), rates as (                -- per-head rates at that day: measured if any other lot is there
    select lot_id, day, n,
           (coalesce(head, 0) > 0) as measured,
           case when coalesce(head, 0) > 0 then pull1::numeric / head else e_p1 end as r_p1,
           case when coalesce(head, 0) > 0 then pull2::numeric / head else e_p1 * e_p2r end as r_p2,
           case when coalesce(head, 0) > 0 then dead::numeric / head  else e_p1 * e_dr end as r_d_via_p1,
           case when coalesce(head, 0) > 0 then dead::numeric / head  else e_dh end as r_d_hd
      from excl_day
), expect_open as (
    select lot_id,
           sum(n * r_p1)       as x_p1,
           sum(n * r_p2)       as x_p2,
           sum(n * r_d_via_p1) as x_dv,
           sum(n * r_d_hd)     as x_dh,
           sum(n)              as n,
           bool_and(measured)  as all_measured,
           bool_or(measured)   as any_measured,
           count(*) filter (where r_p1 is null) as days_without_baseline
      from rates group by lot_id
), measured_through as (     -- last day another lot in the cell has reached
    select lc.lot_id, max(cd.day) filter (where cd.head - coalesce(od.head, 0) > 0) as through_day
      from lc
      join cell_day cd on cd.class_code = lc.class_code and cd.season_code = lc.season_code
      left join own_day od on od.lot_id = lc.lot_id and od.day = cd.day
     group by lc.lot_id
), at_day as (               -- provenance line at the lot's weighted day
    select lc.lot_id, least(greatest(lc.current_day, 0), 180) as day,
           cd.head - coalesce(od.head, 0) as head,
           cd.lots - case when coalesce(od.head, 0) > 0 then 1 else 0 end as lots,
           e.provenance as est_provenance
      from lc
      left join cell_day cd on cd.class_code = lc.class_code and cd.season_code = lc.season_code
                           and cd.day = least(greatest(lc.current_day, 0), 180)
      left join own_day od on od.lot_id = lc.lot_id
                           and od.day = least(greatest(lc.current_day, 0), 180)
      left join est e on e.class_code = lc.class_code and e.season_code = lc.season_code
                     and e.day = least(greatest(lc.current_day, 0), 180)
), actual as (
    select h.lot_id,
           count(*)                                        as head,
           count(*) filter (where h.pull1_day is not null) as pull1,
           count(*) filter (where h.pull2_day is not null) as pull2
      from hdays h group by h.lot_id
), deaths as (
    select lot_id,
           coalesce(sum(head) filter (where not is_short), 0) as dead,
           coalesce(sum(head) filter (where is_short), 0)     as shorts_gross
      from public.health_death_days group by lot_id
), strays as (
    select lot_id, sum(head_count) as back
      from public.lot_events
     where event_type = 'adjustment' and head_count > 0 and lower(btrim(coalesce(cause, ''))) = 'stray_return'
     group by lot_id
), base as (
    select lc.lot_id, lc.lot_number, lc.order_buyer, lc.is_closed, lc.class_code, lc.class_label,
           lc.season_code, lc.season_label, lc.current_day, (lc.current_day > 180 and not lc.is_closed) as past_180,
           lc.needs_review, lc.override_applied,
           a.head, a.pull1, a.pull2, coalesce(d.dead, 0) as dead,
           greatest(0, coalesce(d.shorts_gross, 0) - coalesce(s.back, 0)) as shorts,
           -- actual
           100.0 * a.pull1 / nullif(a.head, 0)                                          as act_p1,
           100.0 * a.pull2 / nullif(a.pull1, 0)                                         as act_p2r,
           100.0 * coalesce(d.dead, 0) / nullif(a.pull1, 0)                             as act_dr,
           100.0 * coalesce(d.dead, 0) / nullif(a.head, 0)                              as act_dh,
           case when lc.is_closed then 100.0 * (coalesce(d.dead, 0) + greatest(0, coalesce(d.shorts_gross, 0) - coalesce(s.back, 0)))
                                             / nullif(a.head, 0) end                   as act_lh,
           -- baseline
           case when lc.is_closed then
                case when cc.head - oc.head > 0 then 100.0 * (cc.pull1 - oc.pull1) / (cc.head - oc.head) else 100.0 * ec.p1 end
                else 100.0 * x.x_p1 / nullif(x.n, 0) end                                as base_p1,
           case when lc.is_closed then
                case when cc.head - oc.head > 0 then 100.0 * (cc.pull2 - oc.pull2) / nullif(cc.pull1 - oc.pull1, 0) else 100.0 * ec.p2r end
                else 100.0 * x.x_p2 / nullif(x.x_p1, 0) end                             as base_p2r,
           case when lc.is_closed then
                case when cc.head - oc.head > 0 then 100.0 * (cc.dead - oc.dead) / nullif(cc.pull1 - oc.pull1, 0) else 100.0 * ec.dr end
                else 100.0 * x.x_dv / nullif(x.x_p1, 0) end                             as base_dr,
           case when lc.is_closed then
                case when cc.head - oc.head > 0 then 100.0 * (cc.dead - oc.dead) / (cc.head - oc.head) else 100.0 * ec.dh end
                else 100.0 * x.x_dh / nullif(x.n, 0) end                                as base_dh,
           case when lc.is_closed then
                case when cc.head - oc.head > 0 then 100.0 * (cc.dead - oc.dead + cc.shorts - oc.shorts) / (cc.head - oc.head) else 100.0 * ec.lh end
           end                                                                          as base_lh,
           -- provenance
           case
               when lc.is_closed and cc.head - oc.head > 0 then
                   'Measured at close · ' || (cc.lots - 1) || case when cc.lots - 1 = 1 then ' lot, ' else ' lots, ' end
                   || to_char(cc.head - oc.head, 'FM999,999,999') || ' hd'
               when lc.is_closed then coalesce(ec.provenance, 'No baseline')
               when x.all_measured then
                   'Measured · ' || ad.lots || case when ad.lots = 1 then ' lot, ' else ' lots, ' end
                   || to_char(ad.head, 'FM999,999,999') || ' hd'
               when x.any_measured then
                   'Measured to day ' || mt.through_day || ', then ' || coalesce(ad.est_provenance, 'no estimate')
               else coalesce(ad.est_provenance, 'No baseline')
           end                                                                          as provenance,
           case when lc.is_closed then case when cc.head - oc.head > 0 then 'measured' when ec.p1 is not null then 'assumed' end
                when x.all_measured then 'measured'
                when x.any_measured then 'mixed'
                when x.days_without_baseline = 0 then 'assumed' end                    as baseline_kind,
           mt.through_day as measured_through_day
      from lc
      join actual a on a.lot_id = lc.lot_id
      left join deaths d          on d.lot_id = lc.lot_id
      left join strays s          on s.lot_id = lc.lot_id
      left join expect_open x     on x.lot_id = lc.lot_id
      left join measured_through mt on mt.lot_id = lc.lot_id
      left join at_day ad         on ad.lot_id = lc.lot_id
      left join own_close oc      on oc.lot_id = lc.lot_id
      left join cell_close cc     on cc.class_code = lc.class_code and cc.season_code = lc.season_code
      left join est_close ec      on ec.class_code = lc.class_code and ec.season_code = lc.season_code
)
select b.lot_id, b.lot_number, b.order_buyer, b.is_closed, b.class_code, b.class_label, b.season_code, b.season_label,
       b.current_day, b.past_180, b.needs_review, b.override_applied,
       b.head, b.pull1, b.pull2, b.dead, b.shorts,
       round(b.act_p1, 1)  as pull1_pct_head,   round(b.base_p1, 1)  as base_pull1_pct_head,   round(b.act_p1  - b.base_p1, 1)  as delta_pull1_pct_head,
       round(b.act_p2r, 1) as pull2_pct_pull1,  round(b.base_p2r, 1) as base_pull2_pct_pull1,  round(b.act_p2r - b.base_p2r, 1) as delta_pull2_pct_pull1,
       round(b.act_dr, 1)  as dead_pct_pull1,   round(b.base_dr, 1)  as base_dead_pct_pull1,   round(b.act_dr  - b.base_dr, 1)  as delta_dead_pct_pull1,
       round(b.act_dh, 1)  as dead_pct_head,    round(b.base_dh, 1)  as base_dead_pct_head,    round(b.act_dh  - b.base_dh, 1)  as delta_dead_pct_head,
       round(b.act_lh, 1)  as loss_pct_head,    round(b.base_lh, 1)  as base_loss_pct_head,    round(b.act_lh  - b.base_lh, 1)  as delta_loss_pct_head,
       coalesce(b.act_p1  - b.base_p1  > t1.threshold_pp, false) as flag_pull1_pct_head,
       coalesce(b.act_p2r - b.base_p2r > t2.threshold_pp, false) as flag_pull2_pct_pull1,
       coalesce(b.act_dr  - b.base_dr  > t3.threshold_pp, false) as flag_dead_pct_pull1,
       coalesce(b.act_dh  - b.base_dh  > t4.threshold_pp, false) as flag_dead_pct_head,
       coalesce(b.act_lh  - b.base_lh  > t5.threshold_pp, false) as flag_loss_pct_head,
       (coalesce(b.act_p1  - b.base_p1  > t1.threshold_pp, false) or coalesce(b.act_p2r - b.base_p2r > t2.threshold_pp, false)
        or coalesce(b.act_dr - b.base_dr > t3.threshold_pp, false) or coalesce(b.act_dh  - b.base_dh  > t4.threshold_pp, false)
        or coalesce(b.act_lh - b.base_lh > t5.threshold_pp, false)) as any_flag,
       (t1.threshold_pp is not null or t2.threshold_pp is not null or t3.threshold_pp is not null
        or t4.threshold_pp is not null or t5.threshold_pp is not null) as thresholds_set,
       b.provenance, b.baseline_kind, b.measured_through_day
  from base b
  left join public.health_flag_thresholds t1 on t1.metric = 'pull1_pct_head'
  left join public.health_flag_thresholds t2 on t2.metric = 'pull2_pct_pull1'
  left join public.health_flag_thresholds t3 on t3.metric = 'dead_pct_pull1'
  left join public.health_flag_thresholds t4 on t4.metric = 'dead_pct_head'
  left join public.health_flag_thresholds t5 on t5.metric = 'loss_pct_head';

-- Position Desk hook: open lots running over a threshold. Empty until John
-- sets one.
create or replace view public.health_exceptions with (security_invoker = true) as
select lot_id, lot_number, class_label, season_label, current_day,
       flag_pull1_pct_head, flag_pull2_pct_pull1, flag_dead_pct_pull1, flag_dead_pct_head,
       delta_pull1_pct_head, delta_pull2_pct_pull1, delta_dead_pct_pull1, delta_dead_pct_head,
       provenance
  from public.lot_health_status
 where not is_closed and any_flag;

-- Death capture for the crew: every non-test lot, by month and in total.
create or replace view public.lot_death_capture with (security_invoker = true) as
with ev as (
    select e.lot_id, e.event_date, abs(e.head_count) as head,
           (e.event_type = 'adjustment' or lower(btrim(coalesce(e.cause, ''))) = 'missing from shipping') as is_short,
           (e.tag_number is not null and btrim(e.tag_number) <> '') as tagged,
           exists (select 1 from public.doctoring_events d
                    where d.lot_id = e.lot_id and e.tag_number is not null
                      and btrim(d.tag_number) = btrim(e.tag_number)
                      and (d.event_datetime at time zone 'America/Chicago')::date <= e.event_date) as pulled_before
      from public.lot_events e
      join public.lots l on l.id = e.lot_id and not l.is_test
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

-- Things to look at before trusting a curve.
create or replace view public.health_anomalies with (security_invoker = true) as
-- several doctoring entries for one tag on one day (counted once)
select 'same_day_duplicate_pull'::text as kind, l.id as lot_id, l.lot_number, btrim(d.tag_number) as tag_number,
       (d.event_datetime at time zone 'America/Chicago')::date as event_date,
       count(*)::int as n, count(*) || ' entries for one tag on one day; counted as one pull' as detail
  from public.doctoring_events d
  join public.lots l on l.id = d.lot_id and not l.is_test
 where d.tag_number is not null and btrim(d.tag_number) <> ''
 group by l.id, l.lot_number, btrim(d.tag_number), (d.event_datetime at time zone 'America/Chicago')::date
having count(*) > 1
union all
-- a pull with no usable tag
select 'pull_no_tag', l.id, l.lot_number, d.tag_number, (d.event_datetime at time zone 'America/Chicago')::date, 1,
       'doctoring entry with no usable tag; not on any curve'
  from public.doctoring_events d
  join public.lots l on l.id = d.lot_id and not l.is_test
 where coalesce(d.no_tag, false) or d.tag_number is null or d.tag_number !~ '^\s*\d{1,9}\s*$'
union all
-- a pulled tag the lot never received (on an included lot)
select 'pull_tag_not_in_lot', p.lot_id, l.lot_number, p.tag_number::text, p.first_pull, p.entries::int,
       'tag pulled on this lot but not among its head received; not on any curve'
  from public.health_pull_days p
  join public.lots l on l.id = p.lot_id
  join public.lot_health_class c on c.lot_id = p.lot_id
 where not exists (select 1 from public.health_head_base h where h.lot_id = p.lot_id and h.tag_number = p.tag_number)
union all
-- a first pull dated before that head arrived
select 'pull_before_arrival', h.lot_id, l.lot_number, h.tag_number::text, h.arrival_date + h.pull1_day, 1,
       'first pull ' || abs(h.pull1_day) || ' day(s) before the head''s arrival'
  from public.health_head_days h
  join public.lots l on l.id = h.lot_id
 where h.pull1_day < 0
union all
-- a tagged death the lot never received
select 'death_tag_not_in_lot', x.lot_id, l.lot_number, x.tag_number, x.event_date, x.head,
       'tagged death not among the lot''s head received; dated from the lot''s weighted arrival'
  from public.health_death_days x
  join public.lots l on l.id = x.lot_id
 where x.tag_number is not null and btrim(x.tag_number) <> '' and not x.tag_matched and not x.is_short
union all
-- one tag registered twice on a lot
select 'duplicate_tag_in_lot', h.lot_id, l.lot_number, h.tag_number::text, null, count(*)::int,
       'tag appears ' || count(*) || ' times among the lot''s head; its pulls count on each'
  from public.health_head_base h
  join public.lots l on l.id = h.lot_id
 group by h.lot_id, l.lot_number, h.tag_number
having count(*) > 1
union all
-- tags on the receipts do not match the receipt head
select 'tags_vs_receipt_head', b.lot_id, b.lot_number, null, null, (b.receipt_tags - b.receipt_head)::int,
       b.receipt_tags || ' tags on receipts against ' || b.receipt_head || ' receipt head; the curve counts tags'
  from public.health_lot_basis b
 where b.excluded_reason is null and b.basis = 'receipts' and b.receipt_tags <> b.receipt_head
union all
-- registered tags outside the estimated load ranges
select 'tag_outside_estimated_loads', t.lot_id, l.lot_number, t.tag_number::text, null, 1,
       'registered tag outside every estimated load range; not on any curve'
  from public.lot_tags t
  join public.lots l on l.id = t.lot_id
 where exists (select 1 from public.health_estimated_loads e where e.lot_id = t.lot_id)
   and not exists (select 1 from public.health_estimated_loads e
                    where e.lot_id = t.lot_id and t.tag_number between e.tag_start and e.tag_end)
union all
-- class or season picked by rule on a lot that straddles; John to confirm
select 'class_season_review', c.lot_id, c.lot_number, null, null, null,
       concat_ws('; ',
           case when c.class_span_flag  then 'loads straddle a weight band (lot ' || c.weighted_weight_lb || ' lb, ' || c.class_label || ' by rule)' end,
           case when c.season_span_flag then 'receipts cross a season (' || c.first_arrival || ' to ' || c.last_arrival || ', ' || c.season_label || ' by rule)' end)
  from public.lot_health_class c
 where c.needs_review;

-- ---------------------------------------------------------------- functions

-- Seed a borrowed estimate for every cell / metric / checkpoint that has no
-- active estimate, from the nearest OTHER cell with a measured value there:
--   1 same class, nearest season  2 adjacent class, same season
--   3 adjacent class, nearest season  4 anything else, nearest first.
-- Ties go to the earlier season in the year, then the lighter class.
-- Never overwrites: John's rows and earlier borrowed rows stand.
create or replace function public.seed_health_estimates()
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare v_n integer;
begin
    with cps(checkpoint, cp_day, is_close) as (
        values ('7',7,false),('14',14,false),('21',21,false),('30',30,false),('45',45,false),
               ('60',60,false),('90',90,false),('120',120,false),('180',180,false),('close',null::int,true)
    ), metrics(metric) as (
        values ('pull1_pct_head'),('pull2_pct_pull1'),('dead_pct_pull1'),('dead_pct_head'),('loss_pct_head')
    ), nseas as (select count(*) as n from health_season_defs),
    src as (
        select m.class_code, m.season_code, m.is_close, m.day, m.lots, m.head, v.metric, v.value_pct
          from health_curve_measured m
          cross join lateral (values ('pull1_pct_head', m.pull1_pct_head), ('pull2_pct_pull1', m.pull2_pct_pull1),
                                     ('dead_pct_pull1', m.dead_pct_pull1), ('dead_pct_head', m.dead_pct_head),
                                     ('loss_pct_head', m.loss_pct_head)) v(metric, value_pct)
         where m.lots > 0 and v.value_pct is not null
    ), want as (
        select c.class_code, c.sort_order, s.season_code, s.cycle_order, k.checkpoint, k.cp_day, k.is_close, mt.metric
          from health_class_bands c
          cross join health_season_defs s
          cross join cps k
          cross join metrics mt
         where (mt.metric <> 'loss_pct_head' or k.is_close)
           and not exists (select 1 from health_baseline_estimates e
                            where e.superseded_at is null and e.class_code = c.class_code and e.season_code = s.season_code
                              and e.metric = mt.metric and e.checkpoint = k.checkpoint)
    ), ranked as (
        select w.class_code, w.season_code, w.metric, w.checkpoint, src.value_pct,
               src.class_code as b_class, src.season_code as b_season, src.lots, src.head,
               row_number() over (
                   partition by w.class_code, w.season_code, w.metric, w.checkpoint
                   order by
                       case when sc.sort_order = w.sort_order and ss.season_code <> w.season_code then 1
                            when abs(sc.sort_order - w.sort_order) = 1 and ss.season_code = w.season_code then 2
                            when abs(sc.sort_order - w.sort_order) = 1 then 3
                            else 4 end,
                       abs(sc.sort_order - w.sort_order),
                       least(abs(ss.cycle_order - w.cycle_order), (select n from nseas) - abs(ss.cycle_order - w.cycle_order)),
                       ss.cycle_order, sc.sort_order) as rn
          from want w
          join src on src.metric = w.metric and src.is_close = w.is_close
                  and src.day is not distinct from w.cp_day
                  and not (src.class_code = w.class_code and src.season_code = w.season_code)
          join health_class_bands sc on sc.class_code = src.class_code
          join health_season_defs ss on ss.season_code = src.season_code
    )
    insert into health_baseline_estimates
        (class_code, season_code, metric, checkpoint, value_pct, source, borrowed_class, borrowed_season, borrowed_lots, borrowed_head)
    select class_code, season_code, metric, checkpoint, value_pct, 'borrowed', b_class, b_season, lots, head
      from ranked where rn = 1;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

-- John overwrites one estimate. The old row is kept, stamped superseded.
create or replace function public.set_health_estimate(
    p_class_code text, p_season_code text, p_metric text, p_checkpoint text, p_value_pct numeric)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare v_id uuid;
begin
    if public.current_user_role() is distinct from 'owner' then
        raise exception 'only the owner can edit health estimates' using errcode = '42501';
    end if;
    if p_value_pct is null or p_value_pct < 0 then
        raise exception 'estimate must be a percentage of 0 or more';
    end if;
    update health_baseline_estimates
       set superseded_at = now(), superseded_by = auth.uid()
     where class_code = p_class_code and season_code = p_season_code
       and metric = p_metric and checkpoint = p_checkpoint and superseded_at is null;
    insert into health_baseline_estimates (class_code, season_code, metric, checkpoint, value_pct, source)
    values (p_class_code, p_season_code, p_metric, p_checkpoint, p_value_pct, 'john')
    returning id into v_id;
    return v_id;
end;
$$;

-- ---------------------------------------------------------------- RLS & grants

do $$
declare t text;
begin
    foreach t in array array['health_class_bands','health_season_defs','health_seasons','lot_health_overrides',
                             'health_estimated_loads','health_baseline_estimates','health_flag_thresholds']
    loop
        execute format('alter table public.%I enable row level security', t);
        execute format('drop policy if exists %I on public.%I', t || '_select', t);
        execute format('create policy %I on public.%I for select to authenticated using (public.can_read_operational())', t || '_select', t);
        execute format('drop policy if exists %I on public.%I', t || '_insert', t);
        execute format('create policy %I on public.%I for insert to authenticated with check (public.current_user_role() = ''owner'')', t || '_insert', t);
        execute format('drop policy if exists %I on public.%I', t || '_update', t);
        execute format('create policy %I on public.%I for update to authenticated using (public.current_user_role() = ''owner'') with check (public.current_user_role() = ''owner'')', t || '_update', t);
        execute format('drop policy if exists %I on public.%I', t || '_delete', t);
        if t <> 'health_baseline_estimates' then      -- estimates are history: never deleted
            execute format('create policy %I on public.%I for delete to authenticated using (public.current_user_role() = ''owner'')', t || '_delete', t);
        end if;
        execute format('revoke all on public.%I from public, anon', t);
        execute format('grant select, insert, update, delete on public.%I to authenticated', t);
        execute format('revoke truncate, references, trigger on public.%I from authenticated', t);
    end loop;
    revoke delete on public.health_baseline_estimates from authenticated;

    foreach t in array array['health_lot_basis','health_excluded_lots','health_head_base','lot_health_class',
                             'health_pull_days','health_head_days','health_death_days','health_curve_lot_daily',
                             'health_curve_measured','health_estimate_points','health_estimate_daily','health_baseline',
                             'lot_health_status','health_exceptions','lot_death_capture','health_anomalies']
    loop
        execute format('revoke all on public.%I from public, anon', t);
        execute format('grant select on public.%I to authenticated', t);
        -- Supabase's default privileges hand authenticated ALL on a new
        -- relation; these views are read-only
        execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from authenticated', t);
    end loop;
end $$;

revoke all on function public.health_receipt_weights() from public, anon;
grant execute on function public.health_receipt_weights() to authenticated;
revoke all on function public.seed_health_estimates() from public, anon;
grant execute on function public.seed_health_estimates() to authenticated;
revoke all on function public.set_health_estimate(text, text, text, text, numeric) from public, anon;
grant execute on function public.set_health_estimate(text, text, text, text, numeric) to authenticated;

-- ---------------------------------------------------------------- seed estimates

do $$
declare v_n integer;
begin
    v_n := public.seed_health_estimates();
    raise notice 'health estimates seeded: % rows', v_n;
end $$;

-- fresh tables carry no statistics; without them the planner guesses
-- hundreds of rows for a four-row table and the baseline view goes slow
analyze public.health_class_bands, public.health_season_defs, public.health_seasons,
        public.lot_health_overrides, public.health_estimated_loads,
        public.health_baseline_estimates, public.health_flag_thresholds;

-- ---------------------------------------------------------------- verify

do $$
declare v_bad text; v_n integer;
begin
    -- RLS on every new table
    select string_agg(c.relname, ', ') into v_bad
      from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
       and c.relname in ('health_class_bands','health_season_defs','health_seasons','lot_health_overrides',
                         'health_estimated_loads','health_baseline_estimates','health_flag_thresholds')
       and not c.relrowsecurity;
    if v_bad is not null then raise exception 'RLS off on: %', v_bad; end if;

    -- every new view security_invoker
    select string_agg(c.relname, ', ') into v_bad
      from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
       and (c.relname like 'health\_%' or c.relname in ('lot_health_class','lot_health_status','lot_death_capture'))
       and not coalesce('security_invoker=true' = any (c.reloptions), false);
    if v_bad is not null then raise exception 'view(s) without security_invoker: %', v_bad; end if;

    -- anon holds nothing
    select string_agg(c.relname, ', ') into v_bad
      from pg_class c
     where c.relnamespace = 'public'::regnamespace
       and (c.relname like 'health\_%' or c.relname in ('lot_health_class','lot_health_status','lot_death_capture','lot_health_overrides'))
       and has_table_privilege('anon', c.oid, 'select');
    if v_bad is not null then raise exception 'anon can read: %', v_bad; end if;
    if has_function_privilege('anon', 'public.health_receipt_weights()', 'execute') then
        raise exception 'anon can execute health_receipt_weights()';
    end if;

    -- settings seeded
    select count(*) into v_n from public.health_class_bands;  if v_n < 4  then raise exception 'class bands: %', v_n; end if;
    select count(*) into v_n from public.health_seasons;      if v_n <> 12 then raise exception 'season months: %', v_n; end if;

    -- every included lot has a class and a season
    select string_agg(lot_number, ', ') into v_bad from public.lot_health_class where class_code is null or season_code is null;
    if v_bad is not null then raise exception 'lot(s) with no class or season: %', v_bad; end if;

    -- 37X is in, on estimated loads, 361 head
    if exists (select 1 from public.health_estimated_loads e join public.lots l on l.id = e.lot_id where l.lot_number = '37X') then
        select head into v_n from public.lot_health_class where lot_number = '37X';
        if v_n is distinct from 361 then raise exception '37X head on estimated loads is %, expected 361', v_n; end if;
    end if;

    raise notice 'health curves: RLS on, views invoker, anon locked out, 37X on 361 estimated head';
end $$;

commit;
