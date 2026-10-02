-- =====================================================================
-- Jake Taylor held ID tags #2-999 on 1 Oct. He used #2-10 that day.
-- =====================================================================
-- APPLIED 2026-10-02. John, third time of telling, and the record should
-- say so plainly: "For the third time Jake's inventory had tag #2-999 on
-- Oct 1. He used #2-10 on the 1st. Put those tags in his inventory."
--
-- #2 through #999 inclusive is **998 tags**. (An earlier note in this
-- chain read #2-1000, 999 tags; #2-999 is the figure of record now.)
-- #2 through #10 inclusive is **9 tags**, which is exactly the 9 head on
-- the 1 Oct receipt - the draw and the tag range agree, which is the
-- check worth doing before entering any of it.
--
-- 998 x $0.4056 = $404.79, dated 1 Oct, his location, origin
-- 'adjustment'. Jake Taylor is locked through 30 Sep, so 1 Oct is the
-- earliest open day and it is also the right day: that is when he had
-- them.
--
-- Then med_settle_uncovered() covered his 9: units_covered 9,
-- transactions_settled 1, transactions_repriced 0. Repriced ZERO is the
-- point - the draw was already costed at catalog and the layer is at
-- catalog, so the lot moved not one cent. Lot 32-26 reads $778.17 before
-- and after; processing across the place $99,530.31 before and after.
-- His shelf now reads 989 tags, #11-999, $401.14.
--
-- THE COST BASIS IS STILL OPEN, and it is bigger than tags. John, same
-- message: the office block was "expensed out earlier in year lump sum
-- when we didn't have a good inventory and mgt tracking program", and
-- there are previously expensed meds he wants to send to Jake to use up.
-- Catalog is used here so that processing cost is not distorted - his
-- own objection to a zero - and because a wrong basis is one UPDATE to
-- these layers' unit_cost while nothing has drawn against them. The
-- options are being worked through with him; see OPEN-ITEMS 0k.
--
-- Lot tags are NOT entered, at either place. Nobody has counted them and
-- John's note stands: they have not been billed to us yet. Jake's 9 lot
-- tags from the 1 Oct draw stay uncovered, $3.65, priced at catalog -
-- the lot is charged, the shelf just cannot show them.
-- =====================================================================

begin;

insert into public.med_purchase_lines (
    medication_id, location_id, qty_bottles, bottle_size, unit,
    unit_cost, qty_remaining, received_date, origin, mfr_lot_number)
select m.id, loc.id, 998, 1, coalesce(m.bottle_size_unit, 'doses'),
       m.cost_per_unit, 998, '2026-10-01'::date, 'adjustment', '#2-999'
  from public.medications m
  cross join public.med_stock_locations loc
 where m.name = 'ID Tag' and loc.source_key = 'Jake Taylor'
   and not exists (select 1 from public.med_purchase_lines x
                    where x.medication_id = m.id and x.location_id = loc.id
                      and x.mfr_lot_number = '#2-999');

-- The ledger row the trigger wrote, told why it exists. An adjustment
-- that cannot explain itself is indistinguishable from a typo later.
update public.med_txns t
   set notes = 'Jake Taylor held ID tags #2-999 on 1 Oct 2026 - 998 tags, on '
            || 'John''s word 2026-10-02. Priced at the catalog $0.4056 a tag. '
            || 'They came off a block expensed earlier in the year as a lump '
            || 'sum; the cost basis is under discussion and is corrected on '
            || 'this layer''s unit_cost if it changes.'
 where t.ref_kind = 'med_purchase_line'
   and t.ref_id = (select id from public.med_purchase_lines
                    where mfr_lot_number = '#2-999')
   and t.notes is null;

-- Cover the 9 he used. Safe to re-run: with nothing uncovered it is a
-- no-op that reports units_covered 0.
select public.med_settle_uncovered(
    (select id from public.medications where name = 'ID Tag'),
    (select id from public.med_stock_locations where source_key = 'Jake Taylor'));

-- ---- verify ---------------------------------------------------------------
do $verify$
declare
    v_units numeric;
    v_value numeric;
    v_unc   numeric;
    v_lot   numeric;
    n       integer;
begin
    select qty_units, value_fifo, uncovered_units
      into v_units, v_value, v_unc
      from public.med_on_hand
     where location_kind = 'buyer' and medication_name = 'ID Tag';

    if v_units <> 989 then
        raise exception 'Jake reads % ID tags, not the 989 that #11-999 is', v_units;
    end if;
    if v_value <> 401.14 then
        raise exception 'Jake values his ID tags at %, not 401.14', v_value;
    end if;
    if coalesce(v_unc, 0) <> 0 then
        raise exception '% ID tag units still uncovered at Jake - the settle did not take', v_unc;
    end if;

    -- the settle must not have moved a lot: catalog in, catalog out
    select round(total_cost, 2) into v_lot
      from public.lot_processing_costs c join public.lots l on l.id = c.lot_id
     where l.lot_number = '32-26';
    if v_lot <> 778.17 then
        raise exception 'lot 32-26 reads % - covering uncovered usage must not reprice it', v_lot;
    end if;

    -- the layer must sit outside every locked period
    select count(*) into n from public.med_purchase_lines l
      join public.med_stock_locations loc on loc.id = l.location_id
     where l.mfr_lot_number = '#2-999'
       and l.received_date <= public.med_locked_through(loc.id);
    if n > 0 then
        raise exception 'the tag layer is dated inside a locked period';
    end if;

    -- FIFO identity, every layer on the place
    select count(*) into n from (
        select pl.id from public.med_purchase_lines pl
          left join public.med_txn_layers tl on tl.purchase_line_id = pl.id
         group by pl.id, pl.qty_units, pl.qty_remaining
        having round(pl.qty_units - coalesce(sum(tl.qty_units), 0), 4)
            <> round(pl.qty_remaining, 4)) x;
    if n > 0 then
        raise exception '% layer(s) no longer tie: remaining <> bought - used', n;
    end if;

    raise notice 'VERIFIED: Jake holds 989 ID tags, #11-999, $401.14. Nothing uncovered. Lot 32-26 unmoved at $778.17.';
end
$verify$;

commit;
