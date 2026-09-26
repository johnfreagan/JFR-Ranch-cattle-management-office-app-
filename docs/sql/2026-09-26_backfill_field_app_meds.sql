-- 2026-09-26  Backfill doctoring_event_meds lost by the Approvals bug.
--
-- Cause: commit e0530ba (2026-08-31) read pending_field_entries.resolved_meds
-- with Array.isArray() alone. The column is NOT NULL DEFAULT '[]', so every
-- untouched entry resolved to an EMPTY med list and posted with no meds.
-- 167 field-app doctoring events, 2026-09-01 .. 2026-09-26.
--
-- This restores the meds the cowboy recorded (pending_field_entries.raw
-- medicationN / dosageN), matched by name the same way the app matches them
-- (trim + lower case), costed with the app's computeMedCost():
--   cost_per_unit * dose  when priced per unit, else cost_per_head.
-- Prices for Excede, Enroflox(Baytril) and Resflor have not changed since
-- 2026-08-28, so this is the cost approval would have frozen.
--
-- Skipped on purpose: 13 events (36-27, Sept 5/6/10) where the field app
-- sent the med names with BLANK doses. Their doses must come from John.
--
-- Expected: 154 events, 279 lines, $2,759.57.
-- Idempotent: only touches events that still have zero med rows.

do $$
declare
  n_events int; n_lines int; v_cost numeric;
begin
  create temp table bf on commit drop as
  with e as (
    select (p.approved_ref->>'id')::uuid as ev_id, p.raw
    from pending_field_entries p
    where p.status = 'approved'
      and p.approved_ref->>'kind' = 'doctoring_event'
      and jsonb_array_length(p.resolved_meds) = 0
      and exists (select 1 from doctoring_events d where d.id = (p.approved_ref->>'id')::uuid)
      and not exists (select 1 from doctoring_event_meds m
                      where m.doctoring_event_id = (p.approved_ref->>'id')::uuid)
  ), l as (
    select e.ev_id, i::smallint as pos,
           nullif(trim(e.raw->>('medication'||i)), '') as mname,
           nullif(trim(e.raw->>('dosage'||i)), '')     as dtxt
    from e, generate_series(1,3) i
  )
  select l.ev_id, l.pos, md.id as medication_id, l.dtxt::numeric as dose_cc,
         case when md.cost_per_unit is not null then md.cost_per_unit * l.dtxt::numeric
              else md.cost_per_head end as cost
  from l
  join medications md on lower(trim(md.name)) = lower(l.mname)
  where l.dtxt ~ '^[0-9]*\.?[0-9]+$' and l.dtxt::numeric > 0
    -- every med on the event must have a dose, or the event is skipped whole
    and not exists (select 1 from l l2 where l2.ev_id = l.ev_id
                    and l2.mname is not null and l2.dtxt is null);

  select count(distinct ev_id), count(*), round(sum(cost), 2)
    into n_events, n_lines, v_cost from bf;

  if n_events <> 154 or n_lines <> 279 or v_cost <> 2759.57 then
    raise exception 'Expected 154 events / 279 lines / $2759.57, found % / % / $%. Nothing written.',
      n_events, n_lines, v_cost;
  end if;

  insert into doctoring_event_meds (doctoring_event_id, position, medication_id,
                                    medication_name_freetext, dose_cc, cost)
  select ev_id, pos, medication_id, null, dose_cc, cost from bf;

  update doctoring_events d
     set notes = concat_ws(' ', nullif(d.notes, ''),
       '[2026-09-26 meds restored from field entry: approval bug had posted this with no meds]')
   where d.id in (select distinct ev_id from bf);

  raise notice 'Restored % med lines on % events, $%', n_lines, n_events, v_cost;
end $$;

-- Verify: should return 13 rows (the blank-dose events) and nothing else.
select (d.event_datetime at time zone 'America/Chicago')::date as dt, d.tag_number
from doctoring_events d
where d.legacy_source = 'field_app' and d.event_datetime >= '2026-09-01'
  and not exists (select 1 from doctoring_event_meds m where m.doctoring_event_id = d.id)
order by 1, 2;
