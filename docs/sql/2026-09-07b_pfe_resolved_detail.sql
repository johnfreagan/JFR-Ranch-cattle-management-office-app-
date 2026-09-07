-- One jsonb column so the office's review decisions survive until approval.
--
-- A test weight needs a true shrink % and whether the sample stands for the
-- pasture or the whole lot. Those are decided in the approvals screen BEFORE
-- the row is posted, so they have to persist on the staged row — but they
-- belong to `weights`, not to pending_field_entries, and there is no sensible
-- existing column for them. resolved_meds is med-specific; `raw` is the
-- cowboy's own record and is never written by the office.
--
-- Idempotent. Paste WITHOUT begin/commit.
alter table public.pending_field_entries
    add column if not exists resolved_detail jsonb;

comment on column public.pending_field_entries.resolved_detail is
    'Office review decisions that have no column of their own, e.g. a test weight''s shrink_pct and applies_to. Never written by the field app.';

do $$
begin
    if not exists (select 1 from information_schema.columns
                   where table_schema='public' and table_name='pending_field_entries'
                     and column_name='resolved_detail') then
        raise exception 'resolved_detail was not added';
    end if;
    raise notice 'OK: pending_field_entries.resolved_detail in place.';
end $$;
