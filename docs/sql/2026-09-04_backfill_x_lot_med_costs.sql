-- 2026-09-04: back-fill unpriced doctoring med costs on the "X" lots
-- (37X, 37X-1, 37X-F, 59X, 60X). John's ask: capture treatment cost for the
-- data bank behind a future doctoring price structure.
--
-- These rows were saved while the medications were unpriced, so cost was
-- NULL - a hole, not a frozen number. Filling a hole from the current price
-- list is the sanctioned after-the-fact write (same rule as
-- recost_pending_usage in feed). Formula matches computeMedCost() in the
-- app: dose_cc x cost_per_unit. Guarded WHERE cost IS NULL; never moves a
-- priced row. Applied through the SQL editor 2026-09-04: 682 rows on 5
-- lots, $8,873.41. One Dexamethasone row on 59X stayed NULL (no price on
-- the list). The count check raises so a re-run cannot double-apply.
--
-- Non-X lots still carry ~1,178 unpriced rows; change the lot filter to
-- cover them.

do $$
declare
    n_rows int;
    n_events int;
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
           and l.lot_number ilike '%X%'
        returning dem.doctoring_event_id
    ),
    noted as (
        update public.doctoring_events e
           set notes = concat_ws(E'\n', e.notes,
               '[2026-09-04] Med cost back-filled from current medication price list (rows were saved unpriced). Formula: dose_cc x cost_per_unit, same as the app freezes at save.')
         where e.id in (select distinct doctoring_event_id from priced)
        returning e.id
    )
    select (select count(*) from priced), (select count(*) from noted)
      into n_rows, n_events;

    raise notice 'priced % med rows on % doctoring events', n_rows, n_events;

    if n_rows <> 682 then
        raise exception 'expected 682 rows, priced % - check before re-running', n_rows;
    end if;
end $$;
