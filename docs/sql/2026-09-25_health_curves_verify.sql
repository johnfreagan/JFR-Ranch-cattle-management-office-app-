-- 2026-09-25  Health curves: reproduce John's verification table (pulled
-- 25 Sep 2026) with the OLD rule - every head classed by its own load, all
-- lots in, no self-exclusion - from the same base views the build uses.
-- Read-only. Expected:
--   200-400 Dec-Mar  31-26                1,766 hd  9.3 / 21.5 / 27.3  13.4  6.1
--   401-550 Dec-Mar  47-26, 37X-1, 37X-F    778 hd  7.2 / 17.0 / 20.2  12.9  6.8
--   551-650 Apr-May  59X                    241 hd  8.7 / 19.5 / 25.3  12.8  4.3
-- The build adds 37X (361 hd on estimated loads) to the 401-550 Dec-Mar
-- cell; it was not in the table, so the query below leaves it out
-- (the exclude array at the top). Run with it in to see what 37X does to the cell.
with p as (select array['37X']::text[] as exclude),
head as (
    select h.lot_id, l.lot_number, h.tag_number, h.arrival_date,
           (select c.class_code from health_class_bands c
             where h.weight_lb >= c.min_lb and (c.max_lb is null or h.weight_lb < c.max_lb)) as cls,
           s.season_code as sea,
           pd.first_pull - h.arrival_date as p1, pd.second_pull - h.arrival_date as p2
      from health_head_base h
      join lots l on l.id = h.lot_id
      join health_seasons s on s.month = extract(month from h.arrival_date)::int
      left join health_pull_days pd on pd.lot_id = h.lot_id and pd.tag_number = h.tag_number
     where not (l.lot_number = any ((select exclude from p)::text[]))
), dead as (   -- deaths within 30 days, per head's own cell (untagged: the lot's modal cell)
    select coalesce(hc.cls, lc.cls) as cls, coalesce(hc.sea, lc.sea) as sea, sum(x.head) as d30
      from health_death_days x
      join lots l on l.id = x.lot_id
      left join lateral (select cls, sea from head h
                          where h.lot_id = x.lot_id and x.tag_number ~ '^\s*\d{1,9}\s*$'
                            and h.tag_number = btrim(x.tag_number)::int limit 1) hc on true
      left join lateral (select cls, sea from head h where h.lot_id = x.lot_id
                          group by cls, sea order by count(*) desc limit 1) lc on true
     where not x.is_short and x.death_day <= 30
       and not (l.lot_number = any ((select exclude from p)::text[]))
     group by 1, 2
)
select h.cls, h.sea, string_agg(distinct h.lot_number, ', ') as lots, count(*) as hd,
       round(100.0 * count(*) filter (where p1 <= 14) / count(*), 1) as p1_d14,
       round(100.0 * count(*) filter (where p1 <= 30) / count(*), 1) as p1_d30,
       round(100.0 * count(*) filter (where p1 <= 60) / count(*), 1) as p1_d60,
       round(100.0 * count(*) filter (where p2 <= 30) / nullif(count(*) filter (where p1 <= 30), 0), 1) as p2_of_p1_d30,
       round(100.0 * max(d.d30) / nullif(count(*) filter (where p1 <= 30), 0), 1) as dead_of_p1_d30
  from head h
  left join dead d on d.cls = h.cls and d.sea = h.sea
 group by h.cls, h.sea
 order by h.cls, h.sea;

-- Death capture, 31-26: expect 116 dead, 52 tagged, 38 pulled before death,
-- 14 never pulled.
select lot_number, dead, tagged, tag_capture_pct, tagged_pulled_before, tagged_never_pulled, shorts
  from lot_death_capture where is_total order by lot_number;
