-- 2026-09-11  Cost of gain: one mode. Every lot and budget on per_lb.
--
-- The closeout input has been locked to $/lb of gain since 2026-09-04, but
-- lots and budgets could still carry per_day or per_head, and the app kept
-- three code paths alive for them (closeoutActual, cogAt, closeoutBudget,
-- ltStoredRates). The transfer basis read the STORED mode, so a lot shown
-- converted on screen froze a basis on different math. Decision 2026-09-11
-- (docs/cog-design-decisions.md section 6): migrate, then delete the paths.
--
-- Converts per_day -> per_lb through the lot's own target ADG, the same
-- arithmetic the screen has shown since 2026-09-04. per_head would convert
-- through ADG x target days; no row carries it. Old columns stay as audit.
-- Idempotent; the CHECKs are tightened last so a stray write cannot bring a
-- mode back. Paste WITHOUT the begin/commit lines.
begin;

do $$
declare n_lots integer; n_bud integer; n_left integer;
begin
    update lots
       set assumed_cog_per_lb = case
               when assumed_cog_per_lb is not null then assumed_cog_per_lb
               when cog_mode = 'per_day'  and assumed_cog_per_day  is not null and coalesce(target_adg,0) > 0
                    then round(assumed_cog_per_day / target_adg, 4)
               when cog_mode = 'per_head' and assumed_cog_per_head is not null and coalesce(target_adg,0) > 0 and coalesce(target_days_on_feed,0) > 0
                    then round(assumed_cog_per_head / (target_adg * target_days_on_feed), 4)
               else null end,
           cog_mode = 'per_lb',
           notes = concat_ws(E'\n', nullif(notes, ''),
               '[2026-09-11] COG mode ' || cog_mode || ' -> per_lb'
               || case when cog_mode = 'per_day' and assumed_cog_per_day is not null and coalesce(target_adg,0) > 0
                       then ' (' || assumed_cog_per_day || '/hd/day at ' || target_adg || ' ADG = $' || round(assumed_cog_per_day / target_adg, 4) || '/lb)'
                       else '' end
               || '. One COG mode from here; the old columns are audit.')
     where cog_mode <> 'per_lb';
    get diagnostics n_lots = row_count;

    update lot_budgets b
       set cog_value = case
               when b.cog_mode = 'per_day'  and coalesce(b.target_adg,0) > 0 then round(b.cog_value / b.target_adg, 4)
               when b.cog_mode = 'per_head' and coalesce(b.target_adg,0) > 0 and coalesce(b.days_on_feed,0) > 0
                    then round(b.cog_value / (b.target_adg * b.days_on_feed), 4)
               else b.cog_value end,
           cog_mode = 'per_lb'
     where b.cog_mode <> 'per_lb';
    get diagnostics n_bud = row_count;
    raise notice 'lots converted: %, budgets converted: %', n_lots, n_bud;

    select count(*) into n_left from lots where cog_mode <> 'per_lb';
    if n_left > 0 then raise exception '% lots still not per_lb', n_left; end if;
end $$;

alter table lots        drop constraint if exists lots_cog_mode_check;
alter table lots        add  constraint lots_cog_mode_check        check (cog_mode = 'per_lb');
alter table lot_budgets drop constraint if exists lot_budgets_cog_mode_check;
alter table lot_budgets add  constraint lot_budgets_cog_mode_check check (cog_mode = 'per_lb');

do $$
declare rec record;
begin
    for rec in select lot_number, cog_mode, assumed_cog_per_lb, assumed_cog_per_day, target_adg
                 from lots where coalesce(is_test,false) = false order by lot_number loop
        raise notice '%: % $%/lb (was %/hd/day at % ADG)', rec.lot_number, rec.cog_mode, rec.assumed_cog_per_lb, rec.assumed_cog_per_day, rec.target_adg;
    end loop;
end $$;

commit;
