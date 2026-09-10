-- 2026-09-10: back-fill the remaining unpriced doctoring med costs at today's
-- price list. John: "price at today's med cost. Some data is better than no
-- data." Same rule and formula as the 2026-09-04 X-lot backfill: a NULL cost
-- is a hole, not a frozen number; dose_cc x cost_per_unit, guarded on
-- cost IS NULL so a priced row never moves. Test lots excluded.
--
-- Rows found 2026-09-10: 31-26 1,081 rows ($9,163.37), 47-26 78 rows
-- ($931.67) - both closed, FY2026. Two rows stay NULL: one Dexamethasone on
-- 59X (no price on the list) and one free-text Bloat-Pac on 31-26 (no
-- medication row at all). The count check raises so a re-run cannot
-- double-apply. Applied through the connector 2026-09-10: 1,159 rows.

do $$
declare
    n_rows   integer;
    n_events integer;
begin
    with priced as (
        update public.doctoring_event_meds dem
           set cost = dem.dose_cc * m.cost_per_unit
          from public.doctoring_events e, public.medications m, public.lots l
         where e.id = dem.doctoring_event_id
           and l.id = e.lot_id
           and m.id = dem.medication_id
           and dem.cost is null
           and dem.dose_cc > 0
           and m.cost_per_unit is not null
           and coalesce(l.is_test, false) = false
           and l.lot_number not ilike 'TEST%'
        returning dem.doctoring_event_id
    ),
    noted as (
        update public.doctoring_events e
           set notes = concat_ws(E'\n', e.notes,
               '[2026-09-10] Med cost back-filled from the current medication price list (rows were saved unpriced). Formula: dose_cc x cost_per_unit, same as the app freezes at save.')
         where e.id in (select distinct doctoring_event_id from priced)
        returning e.id
    )
    select (select count(*) from priced), (select count(*) from noted)
      into n_rows, n_events;

    raise notice 'priced % med rows on % doctoring events', n_rows, n_events;

    if n_rows <> 1159 then
        raise exception 'expected 1159 rows, priced % - check before re-running', n_rows;
    end if;
end $$;
