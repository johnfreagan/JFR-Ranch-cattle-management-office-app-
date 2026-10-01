-- lots.cog_mode column default: per_day -> per_lb (2026-10-01, John approved)
--
-- lots_cog_mode_check has allowed per_lb only since 2026-09-11
-- (2026-09-11_cog_per_lb_only.sql), but the column default on the live
-- database was still 'per_day'. Any insert that did not name cog_mode was
-- refused by the constraint; the New Lot form was one, and that is how it
-- was found.
--
-- The default was meant to change on 2026-09-04: step 4 of
-- 2026-09-04_cog_per_lb.sql sets it, but that line sits after the file's
-- commit; and did not reach the live database.
--
-- The app now sends cog_mode = 'per_lb' on every lot insert, so this is the
-- second half: a lot created outside the form lands on the only legal mode.
-- No rows change. labor_mode keeps its per_day default (still legal).
--
-- Idempotent. Strip begin/commit for apply_migration or the CLI.

begin;

alter table public.lots alter column cog_mode set default 'per_lb';

do $$
declare d text;
begin
    select column_default into d
      from information_schema.columns
     where table_schema = 'public' and table_name = 'lots' and column_name = 'cog_mode';
    if d is distinct from '''per_lb''::text' then
        raise exception 'lots.cog_mode default is %, expected per_lb', d;
    end if;
    raise notice 'lots.cog_mode default: OK';
end $$;

commit;
