-- Closeout: split the single "med $/head" assumption into PROCESSING and
-- DOCTORING (2026-09-04, John: "historically have combined both on
-- projections but I see the need to call both").
--
-- lots.assumed_med_per_head and lot_budgets.med_per_head are LEFT IN PLACE:
-- frozen budgets carry them and the closeout still reads them as a
-- combined figure when the two new columns are null. Nothing is migrated
-- from old to new - a combined number cannot be split honestly after the
-- fact.
--
-- Idempotent. Paste into the SQL editor without the begin/commit lines.

begin;

alter table public.lots
    add column if not exists assumed_processing_per_head numeric
        check (assumed_processing_per_head is null or assumed_processing_per_head >= 0),
    add column if not exists assumed_doctoring_per_head numeric
        check (assumed_doctoring_per_head is null or assumed_doctoring_per_head >= 0);

comment on column public.lots.assumed_processing_per_head is
    'Closeout assumption: processing (receiving meds) $ per head in. Used for the projection only until the lot''s receipts carry a receiving protocol; from then the derived actual is the projection.';
comment on column public.lots.assumed_doctoring_per_head is
    'Closeout assumption: doctoring (treatment) $ per head in. A floor for the projection while the lot is on feed; actual plus observed burn takes over once it exceeds it.';

alter table public.lot_budgets
    add column if not exists processing_per_head numeric,
    add column if not exists doctoring_per_head numeric;

comment on column public.lot_budgets.med_per_head is
    'Legacy: processing + doctoring combined. Budgets frozen from 2026-09-04 carry processing_per_head and doctoring_per_head instead.';

do $$
begin
    if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='lots' and column_name='assumed_doctoring_per_head') then
        raise exception 'lots.assumed_doctoring_per_head missing';
    end if;
    if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='lot_budgets' and column_name='doctoring_per_head') then
        raise exception 'lot_budgets.doctoring_per_head missing';
    end if;
    raise notice 'processing/doctoring split: OK';
end $$;

commit;
