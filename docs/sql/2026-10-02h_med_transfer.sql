-- =====================================================================
-- Moving stock between pools: med_transfer()
-- =====================================================================
-- 2026-10-02. John: "We do need a way to transfer meds possibly using
-- the checkout to move between inventory pools. Probably won't happen
-- often but does happen some."
--
-- The immediate case is a shelf of previously expensed medicine going to
-- Jake to use up. There was no way to do it: a checkout is custody at
-- ONE location (direction 0, nothing moves), and nothing else crossed a
-- location boundary at all.
--
-- WHAT A TRANSFER HAS TO DO, and why it is not just two entries:
--
--   1. consume at the source by FIFO, oldest layer first;
--   2. rebuild those layers at the destination AT THEIR OWN COST, one
--      new layer a consumed layer - NOT one blended layer. Ship 600 mL
--      that came off a $0.30 layer and a $0.38 layer and the destination
--      gets both, so the next draw there costs what the drug actually
--      cost. A blend would quietly re-price inventory on the way out the
--      door, which is the one thing FIFO exists to prevent.
--   3. carry the maker's lot number and the expiry with each layer. Drug
--      does not get younger by changing trucks.
--
-- NO NEW txn_type, deliberately. The two sides are 'adjustment' rows
-- carrying reason 'transfer_out' and 'transfer_in', the same way count
-- shrink is an adjustment carrying reason 'count'. A new type would have
-- meant dropping and re-adding a CHECK constraint, and - worse - every
-- view that buckets by txn_type would have gone on tying while silently
-- showing the movement in no column at all. Reasons are what this module
-- already uses to say WHY an adjustment happened.
--
-- A TRANSFER IS NOT A USAGE, so it gets none of usage's forgiveness:
--
--   - It will NOT post short. med_consume() lets a dose book against an
--     empty shelf, because a treatment that happened must not be lost to
--     a bookkeeping gap. Nobody hands over drug they do not have, so a
--     transfer that exceeds the source shelf is refused and says what is
--     actually there.
--   - It will NOT slide its date into the open period. Usage does, so a
--     late field entry is never thrown away. A transfer is paperwork and
--     can simply be dated right, so BOTH periods must be open - the same
--     rule a purchase has always had.
--
-- The roll-forward learns two new columns rather than letting transfers
-- hide inside Adjustments, where an out-transfer would read like shrink.
-- The printed identity on that report becomes:
--
--   beginning + purchases + opening - used + adjustments + uncovered
--             + transfers in - transfers out = ending
-- APPLIED 2026-10-02. Tested with a dry run that rolled itself back: 50
-- ID tags, Ranch -> Jake Taylor, $20.28, ONE new layer at $0.405600
-- carrying lot #1001-6000; Ranch 5,000 -> 4,950, Jake 989 -> 1,039, and
-- every layer on the place still tied remaining = bought - used. All four
-- guards refuse in plain words: more than the shelf holds ("Ranch has
-- 5000.0000 on the shelf, not the 99999 asked for"), a date in a closed
-- month ("Ranch is closed through 2026-09-30"), the same pool at both
-- ends, and an empty source shelf. rls_verify: PASS.
-- =====================================================================

begin;

-- med_consume gains nothing. It already takes 'adjustment', already
-- walks FIFO oldest-first FOR UPDATE, already writes med_txn_layers.
-- Reusing it is the point: a second FIFO walk is a second FIFO walk to
-- get wrong, and this module has already been bitten once by duplicated
-- maths (lot_processing_costs, 2026-10-02e).

create or replace function public.med_transfer(
    p_medication_id uuid,
    p_from_location uuid,
    p_to_location   uuid,
    p_qty_units     numeric,
    p_txn_date      date default null,
    p_notes         text default null
) returns jsonb
language plpgsql
set search_path to 'public', 'pg_temp'
as $fn$
declare
    v_date      date;
    v_from_name text;
    v_to_name   text;
    v_locked    date;
    v_on_hand   numeric;
    v_out       jsonb;
    v_out_txn   uuid;
    v_line      uuid;
    v_layers    integer := 0;
    v_total     numeric := 0;
    r           record;
begin
    if p_qty_units is null or p_qty_units <= 0 then
        raise exception 'med_transfer: qty_units must be positive (got %)', p_qty_units;
    end if;
    if p_from_location = p_to_location then
        raise exception 'med_transfer: the source and the destination are the same pool';
    end if;

    select name into v_from_name from public.med_stock_locations
     where id = p_from_location and is_active;
    select name into v_to_name   from public.med_stock_locations
     where id = p_to_location   and is_active;
    if v_from_name is null then raise exception 'med_transfer: no active source pool'; end if;
    if v_to_name   is null then raise exception 'med_transfer: no active destination pool'; end if;

    v_date := coalesce(p_txn_date, public.ranch_today());

    -- BOTH periods open. A transfer is paperwork; it can be dated right.
    v_locked := public.med_locked_through(p_from_location);
    if v_locked is not null and v_date <= v_locked then
        raise exception 'med_transfer: % is closed through % - date the transfer after that',
            v_from_name, v_locked;
    end if;
    v_locked := public.med_locked_through(p_to_location);
    if v_locked is not null and v_date <= v_locked then
        raise exception 'med_transfer: % is closed through % - date the transfer after that',
            v_to_name, v_locked;
    end if;

    -- Nobody hands over drug they do not have.
    select coalesce(sum(qty_remaining), 0) into v_on_hand
      from public.med_purchase_lines
     where medication_id = p_medication_id and location_id = p_from_location
       and qty_remaining > 0;
    if v_on_hand < p_qty_units then
        raise exception 'med_transfer: % has % on the shelf, not the % asked for',
            v_from_name, v_on_hand, p_qty_units;
    end if;

    v_out := public.med_consume(
        p_medication_id, p_from_location, p_qty_units,
        'adjustment', 'transfer_out', 'med_transfer', p_to_location, v_date,
        coalesce(p_notes || ' | ', '') || 'Transfer to ' || v_to_name || '.');
    v_out_txn := (v_out->>'txn_id')::uuid;

    -- Pre-checked above, so this cannot fire. It is here because if it
    -- ever does, the whole transfer must roll back rather than conjure
    -- stock at the destination.
    if coalesce((v_out->>'shortfall_units')::numeric, 0) > 0 then
        raise exception 'med_transfer: % came up % short after all - rolling back',
            v_from_name, (v_out->>'shortfall_units');
    end if;

    -- One new layer a consumed layer, at that layer's own cost.
    for r in
        select tl.qty_units, tl.unit_cost, pl.bottle_size, pl.unit,
               pl.mfr_lot_number, pl.expires_on
          from public.med_txn_layers tl
          join public.med_purchase_lines pl on pl.id = tl.purchase_line_id
         where tl.txn_id = v_out_txn
         order by pl.received_date, pl.sort_order, pl.created_at, pl.id
    loop
        insert into public.med_purchase_lines (
            medication_id, location_id, qty_bottles, bottle_size, unit,
            unit_cost, qty_remaining, received_date, origin,
            mfr_lot_number, expires_on
        ) values (
            p_medication_id, p_to_location,
            r.qty_units / r.bottle_size, r.bottle_size, r.unit,
            r.unit_cost, r.qty_units, v_date, 'adjustment',
            r.mfr_lot_number, r.expires_on
        ) returning id into v_line;

        -- The ledger trigger has just written the +1 row and labelled it
        -- reason 'count', which is its default for an adjustment layer.
        -- Say what it really is. ref_kind and ref_id are left exactly as
        -- the trigger set them: the DELETE branch of med_layer_ledger
        -- finds its row by those, and re-pointing them would orphan the
        -- ledger the first time somebody unwound a layer.
        update public.med_txns
           set reason = 'transfer_in',
               notes  = 'Transfer from ' || v_from_name || '. med_txn:' || v_out_txn::text
                     || coalesce(' | ' || p_notes, '')
         where ref_kind = 'med_purchase_line' and ref_id = v_line;

        v_layers := v_layers + 1;
        v_total  := v_total + (r.qty_units * r.unit_cost);
    end loop;

    return jsonb_build_object(
        'out_txn_id',  v_out_txn,
        'units',       p_qty_units,
        'total_cost',  round(v_total, 4),
        'layers',      v_layers,
        'from',        v_from_name,
        'to',          v_to_name,
        'txn_date',    v_date
    );
end
$fn$;

revoke all on function public.med_transfer(uuid, uuid, uuid, numeric, date, text) from public;
grant execute on function public.med_transfer(uuid, uuid, uuid, numeric, date, text) to authenticated;

comment on function public.med_transfer(uuid, uuid, uuid, numeric, date, text) is
 'Move stock between pools. Consumes FIFO at the source through med_consume and rebuilds each consumed layer at the destination at its own unit cost, carrying lot number and expiry. Refuses to post short and refuses a date inside either pool''s closed period. Runs as the caller, so the med_purchase_lines and med_txns policies decide who may do it.';

-- The roll-forward learns transfers, appended LAST because CREATE OR
-- REPLACE cannot insert a column mid-list - it reads that as renaming
-- the one that was there (42P16).
create or replace view public.med_roll_forward
with (security_invoker = true) as
 with uncovered as (
     select txn_id, sum(qty_units) as uncovered_units, sum(extended_cost) as uncovered_value
       from med_txn_layers where purchase_line_id is null group by txn_id
 ), monthly as (
     select t.location_id, t.medication_id,
        date_trunc('month', t.txn_date::timestamp with time zone)::date as period_month,
        max(t.fiscal_year) as fiscal_year,
        sum(t.qty_units) filter (where t.txn_type = 'purchase') as purchased_units,
        sum(t.qty_units) filter (where t.txn_type = 'opening') as opening_units,
        sum(t.qty_units) filter (where t.txn_type = 'usage') as used_units,
        -- A transfer is an adjustment by type and NOT an adjustment by
        -- meaning. Left in this column, stock leaving for Jake's shelf
        -- would read as shrink to anybody looking at the report.
        sum(t.qty_units * t.direction::numeric) filter (
            where t.txn_type = 'adjustment'
              and coalesce(t.reason, '') not in ('transfer_in', 'transfer_out')) as adjustment_units,
        sum(coalesce(u.uncovered_units, 0)) as uncovered_units,
        sum(t.qty_units) filter (
            where t.txn_type = 'adjustment' and t.direction = -1 and t.reason = 'count') as shrink_units,
        sum(coalesce(t.total_cost, 0)) filter (where t.txn_type = 'purchase') as purchased_value,
        sum(coalesce(t.total_cost, 0)) filter (where t.txn_type = 'opening') as opening_value,
        sum(coalesce(t.total_cost, 0)) filter (where t.txn_type = 'usage') as used_value,
        sum(coalesce(t.total_cost, 0) * t.direction::numeric) filter (
            where t.txn_type = 'adjustment'
              and coalesce(t.reason, '') not in ('transfer_in', 'transfer_out')) as adjustment_value,
        sum(coalesce(u.uncovered_value, 0)) as uncovered_value,
        sum(coalesce(t.total_cost, 0)) filter (
            where t.txn_type = 'adjustment' and t.direction = -1 and t.reason = 'count') as shrink_value,
        -- net stays every row by direction, so the running balance is
        -- right whatever the reason says
        sum((t.qty_units - coalesce(u.uncovered_units, 0)) * t.direction::numeric) as net_units,
        sum((coalesce(t.total_cost, 0) - coalesce(u.uncovered_value, 0)) * t.direction::numeric) as net_value,
        sum(t.qty_units) filter (where t.reason = 'transfer_in')  as xfer_in_units,
        sum(t.qty_units) filter (where t.reason = 'transfer_out') as xfer_out_units,
        sum(coalesce(t.total_cost, 0)) filter (where t.reason = 'transfer_in')  as xfer_in_value,
        sum(coalesce(t.total_cost, 0)) filter (where t.reason = 'transfer_out') as xfer_out_value
       from med_txns t
       left join uncovered u on u.txn_id = t.id
      group by t.location_id, t.medication_id, date_trunc('month', t.txn_date::timestamp with time zone)
 )
 select loc.name as location_name, mo.location_id, m.name as medication_name,
    m.generic_category, mo.medication_id, mo.period_month, mo.fiscal_year,
    coalesce(mo.opening_units, 0) as opening_units,
    coalesce(mo.purchased_units, 0) as purchased_units,
    coalesce(mo.used_units, 0) as used_units,
    coalesce(mo.adjustment_units, 0) as adjustment_units,
    coalesce(mo.uncovered_units, 0) as uncovered_units,
    coalesce(mo.shrink_units, 0) as shrink_units,
    round(coalesce(mo.opening_value, 0), 2) as opening_value,
    round(coalesce(mo.purchased_value, 0), 2) as purchased_value,
    round(coalesce(mo.used_value, 0), 2) as used_value,
    round(coalesce(mo.adjustment_value, 0), 2) as adjustment_value,
    round(coalesce(mo.uncovered_value, 0), 2) as uncovered_value,
    round(coalesce(mo.shrink_value, 0), 2) as shrink_value,
    sum(mo.net_units) over w - mo.net_units as beginning_units,
    sum(mo.net_units) over w as ending_units,
    round(sum(mo.net_value) over w - mo.net_value, 2) as beginning_value,
    round(sum(mo.net_value) over w, 2) as ending_value,
    coalesce(mo.xfer_in_units, 0) as transferred_in_units,
    coalesce(mo.xfer_out_units, 0) as transferred_out_units,
    round(coalesce(mo.xfer_in_value, 0), 2) as transferred_in_value,
    round(coalesce(mo.xfer_out_value, 0), 2) as transferred_out_value
   from monthly mo
   join medications m on m.id = mo.medication_id
   join med_stock_locations loc on loc.id = mo.location_id
  window w as (partition by mo.location_id, mo.medication_id order by mo.period_month
               rows between unbounded preceding and current row);

-- ---- verify ---------------------------------------------------------------
do $verify$
declare
    n integer;
begin
    select count(*) into n
      from pg_class c join pg_namespace nn on nn.oid = c.relnamespace
     where nn.nspname = 'public' and c.relname = 'med_roll_forward'
       and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=true%';
    if n > 0 then raise exception 'med_roll_forward is missing security_invoker = true'; end if;

    select count(*) into n from information_schema.columns
     where table_schema = 'public' and table_name = 'med_roll_forward'
       and column_name in ('transferred_in_units','transferred_out_units',
                           'transferred_in_value','transferred_out_value');
    if n <> 4 then raise exception 'the roll-forward is missing its transfer columns (% of 4)', n; end if;

    if has_function_privilege('anon', 'public.med_transfer(uuid, uuid, uuid, numeric, date, text)', 'EXECUTE') then
        raise exception 'anon can execute med_transfer';
    end if;

    -- the report's printed identity, every row on the place
    select count(*) into n from public.med_roll_forward
     where round(beginning_units + opening_units + purchased_units - used_units
                 + adjustment_units + uncovered_units
                 + transferred_in_units - transferred_out_units, 4) <> round(ending_units, 4);
    if n > 0 then
        raise exception '% roll-forward row(s) do not tie on units', n;
    end if;

    raise notice 'VERIFIED: med_transfer is in, anon cannot call it, and every roll-forward row ties on units.';
end
$verify$;

commit;
