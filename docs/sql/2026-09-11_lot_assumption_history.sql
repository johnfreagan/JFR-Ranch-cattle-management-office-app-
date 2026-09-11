-- 2026-09-11  Closeout assumptions: a trail on SAVE, and only on Save.
--
-- Decision: docs/cog-design-decisions.md section 7. The closeout inputs are
-- John's scratch pad - typing recalculates live and is a what-if, never a
-- change of expectation. Save is the statement "this is what I now expect",
-- and that is what gets logged: one row per Save that changed something,
-- {column: [old, new]} for every assumption that moved, who and when.
-- Captured by a trigger on lots so no app path can forget it.
--
-- RLS: readable through can_read_books() (it is closeout money); INSERT is
-- allowed to the roles that can UPDATE lots, because the trigger runs as
-- the invoking user; no UPDATE, no DELETE - it is an audit trail.
-- Idempotent. Paste WITHOUT the begin/commit lines.
-- Applied through the connector 2026-09-11; smoke-tested in a rolled-back
-- DO block (a target_adg change wrote one row carrying target_adg, then
-- raised so nothing persisted).
begin;

create table if not exists public.lot_assumption_history (
    id          uuid primary key default gen_random_uuid(),
    lot_id      uuid not null references public.lots(id) on delete cascade,
    changed_at  timestamptz not null default now(),
    changed_by  uuid default auth.uid(),
    changes     jsonb not null,
    constraint lot_assumption_history_nonempty check (changes <> '{}'::jsonb)
);
create index if not exists lot_assumption_history_lot_idx on public.lot_assumption_history (lot_id, changed_at desc);

create or replace function public.lot_assumption_history_capture()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
    diff jsonb := '{}'::jsonb;
begin
    -- one line per assumption the closeout saves; old/new as jsonb so a
    -- date, a number and a mode all fit the same shape
    if new.target_sale_cwt              is distinct from old.target_sale_cwt              then diff := diff || jsonb_build_object('target_sale_cwt',              jsonb_build_array(old.target_sale_cwt,              new.target_sale_cwt)); end if;
    if new.target_adg                   is distinct from old.target_adg                   then diff := diff || jsonb_build_object('target_adg',                   jsonb_build_array(old.target_adg,                   new.target_adg)); end if;
    if new.target_ship_date             is distinct from old.target_ship_date             then diff := diff || jsonb_build_object('target_ship_date',             jsonb_build_array(old.target_ship_date,             new.target_ship_date)); end if;
    if new.target_days_on_feed          is distinct from old.target_days_on_feed          then diff := diff || jsonb_build_object('target_days_on_feed',          jsonb_build_array(old.target_days_on_feed,          new.target_days_on_feed)); end if;
    if new.target_ship_weight           is distinct from old.target_ship_weight           then diff := diff || jsonb_build_object('target_ship_weight',           jsonb_build_array(old.target_ship_weight,           new.target_ship_weight)); end if;
    if new.assumed_cog_per_lb           is distinct from old.assumed_cog_per_lb           then diff := diff || jsonb_build_object('assumed_cog_per_lb',           jsonb_build_array(old.assumed_cog_per_lb,           new.assumed_cog_per_lb)); end if;
    if new.assumed_nonfeed_cog_per_day  is distinct from old.assumed_nonfeed_cog_per_day  then diff := diff || jsonb_build_object('assumed_nonfeed_cog_per_day',  jsonb_build_array(old.assumed_nonfeed_cog_per_day,  new.assumed_nonfeed_cog_per_day)); end if;
    if new.labor_mode                   is distinct from old.labor_mode                   then diff := diff || jsonb_build_object('labor_mode',                   jsonb_build_array(old.labor_mode,                   new.labor_mode)); end if;
    if new.assumed_labor_per_day        is distinct from old.assumed_labor_per_day        then diff := diff || jsonb_build_object('assumed_labor_per_day',        jsonb_build_array(old.assumed_labor_per_day,        new.assumed_labor_per_day)); end if;
    if new.assumed_labor_per_head       is distinct from old.assumed_labor_per_head       then diff := diff || jsonb_build_object('assumed_labor_per_head',       jsonb_build_array(old.assumed_labor_per_head,       new.assumed_labor_per_head)); end if;
    if new.assumed_processing_per_head  is distinct from old.assumed_processing_per_head  then diff := diff || jsonb_build_object('assumed_processing_per_head',  jsonb_build_array(old.assumed_processing_per_head,  new.assumed_processing_per_head)); end if;
    if new.assumed_doctoring_per_head   is distinct from old.assumed_doctoring_per_head   then diff := diff || jsonb_build_object('assumed_doctoring_per_head',   jsonb_build_array(old.assumed_doctoring_per_head,   new.assumed_doctoring_per_head)); end if;
    if new.assumed_death_loss_pct       is distinct from old.assumed_death_loss_pct       then diff := diff || jsonb_build_object('assumed_death_loss_pct',       jsonb_build_array(old.assumed_death_loss_pct,       new.assumed_death_loss_pct)); end if;
    if new.assumed_interest_pct         is distinct from old.assumed_interest_pct         then diff := diff || jsonb_build_object('assumed_interest_pct',         jsonb_build_array(old.assumed_interest_pct,         new.assumed_interest_pct)); end if;
    if diff <> '{}'::jsonb then
        insert into public.lot_assumption_history (lot_id, changes) values (new.id, diff);
    end if;
    return new;
end;
$$;

drop trigger if exists lots_assumption_history on public.lots;
create trigger lots_assumption_history
    after update on public.lots
    for each row execute function public.lot_assumption_history_capture();

alter table public.lot_assumption_history enable row level security;
drop policy if exists lot_assumption_history_select on public.lot_assumption_history;
create policy lot_assumption_history_select on public.lot_assumption_history
    for select to authenticated using (public.can_read_books());
drop policy if exists lot_assumption_history_insert on public.lot_assumption_history;
create policy lot_assumption_history_insert on public.lot_assumption_history
    for insert to authenticated with check (public.current_user_role() = any (array['owner','office']));
-- no UPDATE, no DELETE: an audit trail
revoke all on public.lot_assumption_history from public, anon;
grant select, insert on public.lot_assumption_history to authenticated;

-- verify: RLS on, exactly two policies, the trigger exists, and a no-op
-- update writes nothing
do $$
declare n_pol integer; n_trg integer; n_rows_before bigint; n_rows_after bigint; v_rls boolean;
begin
    select relrowsecurity into v_rls from pg_class where oid = 'public.lot_assumption_history'::regclass;
    if not v_rls then raise exception 'RLS is not enabled on lot_assumption_history'; end if;
    select count(*) into n_pol from pg_policies where tablename = 'lot_assumption_history';
    if n_pol <> 2 then raise exception 'expected 2 policies on lot_assumption_history, found %', n_pol; end if;
    select count(*) into n_trg from pg_trigger where tgrelid = 'public.lots'::regclass and tgname = 'lots_assumption_history';
    if n_trg <> 1 then raise exception 'trigger lots_assumption_history missing'; end if;
    select count(*) into n_rows_before from lot_assumption_history;
    update lots set updated_at = updated_at where lot_number = '37X';   -- touches no assumption
    select count(*) into n_rows_after from lot_assumption_history;
    if n_rows_after <> n_rows_before then raise exception 'a no-op update wrote a history row'; end if;
    raise notice 'lot_assumption_history: RLS on, % policies, trigger present, no-op update logged nothing', n_pol;
end $$;

commit;
