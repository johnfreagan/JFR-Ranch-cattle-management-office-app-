-- Cost of gain per POUND of gain (2026-09-04, John's call)
--
-- A third COG mode beside $/head/day and $/head flat. The rate is charged
-- on pounds gained: the expected ADG times head-days while the cattle are
-- on feed, trued up to the pay weight on each sale as head ship. The app
-- computes it; this migration only lets the mode be stored.
--
-- Idempotent. Paste into the SQL editor without the begin/commit lines.

begin;

-- 1. The rate itself, alongside the per-day and per-head columns.
alter table public.lots
    add column if not exists assumed_cog_per_lb numeric
        check (assumed_cog_per_lb is null or assumed_cog_per_lb >= 0);

comment on column public.lots.assumed_cog_per_lb is
    'Cost of gain, $ per lb gained. Used when cog_mode = per_lb: expected ADG x head-days until head ship with a pay weight, then the real gain on those head.';

-- 2. Widen the mode CHECKs on lots and lot_budgets. Dropping and re-adding
--    is the only way to change a CHECK; both are guarded so a re-run is a
--    no-op.
do $$
begin
    if exists (select 1 from pg_constraint
               where conname = 'lots_cog_mode_check'
                 and conrelid = 'public.lots'::regclass
                 and pg_get_constraintdef(oid) not like '%per_lb%') then
        alter table public.lots drop constraint lots_cog_mode_check;
    end if;
    if not exists (select 1 from pg_constraint
                   where conname = 'lots_cog_mode_check'
                     and conrelid = 'public.lots'::regclass) then
        alter table public.lots
            add constraint lots_cog_mode_check
            check (cog_mode in ('per_day','per_head','per_lb'));
    end if;

    if exists (select 1 from pg_constraint
               where conname = 'lot_budgets_cog_mode_check'
                 and conrelid = 'public.lot_budgets'::regclass
                 and pg_get_constraintdef(oid) not like '%per_lb%') then
        alter table public.lot_budgets drop constraint lot_budgets_cog_mode_check;
    end if;
    if not exists (select 1 from pg_constraint
                   where conname = 'lot_budgets_cog_mode_check'
                     and conrelid = 'public.lot_budgets'::regclass) then
        alter table public.lot_budgets
            add constraint lot_budgets_cog_mode_check
            check (cog_mode in ('per_day','per_head','per_lb'));
    end if;
end $$;

-- 3. Verify.
do $$
begin
    if not exists (select 1 from information_schema.columns
                   where table_schema = 'public' and table_name = 'lots'
                     and column_name = 'assumed_cog_per_lb') then
        raise exception 'lots.assumed_cog_per_lb missing';
    end if;
    if not exists (select 1 from pg_constraint
                   where conname = 'lots_cog_mode_check'
                     and pg_get_constraintdef(oid) like '%per_lb%') then
        raise exception 'lots_cog_mode_check does not allow per_lb';
    end if;
    if not exists (select 1 from pg_constraint
                   where conname = 'lot_budgets_cog_mode_check'
                     and pg_get_constraintdef(oid) like '%per_lb%') then
        raise exception 'lot_budgets_cog_mode_check does not allow per_lb';
    end if;
    raise notice 'cog per_lb: OK';
end $$;

commit;

-- ---------------------------------------------------------------------
-- 2026-09-04, later the same day. John: "set the $ per lb of gain as the
-- default for COG on closeout. Leave labor at head day cost."
--
-- 4. Column default, so a lot created outside the app lands on per_lb.
alter table public.lots alter column cog_mode set default 'per_lb';

-- (An earlier draft converted the open lots here. Not needed: the Closeout
-- screen is locked to $/lb and converts a stored per-day rate through the
-- lot's target ADG as the starting value; Save writes it. Nothing in the
-- books changes until someone saves.)
