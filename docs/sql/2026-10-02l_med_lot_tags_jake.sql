-- =====================================================================
-- 167 lot tags on Jake's shelf, billed in bulk to cattle last month.
-- =====================================================================
-- APPLIED 2026-10-02. John: "Had 167 lot tags as of yesterday morning.
-- Were billed last month to cattle bulk let's put in inventory and give
-- me a journal entry to pull that forward from last month."
--
-- 167 x $0.4056 = **$67.74** at the catalog (50 tags for $20.28, the
-- same bag price the ID tags carry).
--
-- THE LOCATION IS JAKE TAYLOR, and the arithmetic is what settles it
-- rather than a guess. His 1 Oct receipt drew 9 lot tags and they came
-- off a shelf that held none, so they sat as uncovered usage. 167 on
-- hand the morning of 1 Oct, less the 9 he used that day, leaves 158 -
-- and the same pattern held for his ID tags the same morning (998 less
-- the same 9). If John meant the medicine room instead, the 9 at Jake's
-- would still be uncovered, and they are not: med_settle_uncovered()
-- covered them off this layer.
--
-- Dated 1 Oct, the earliest day his period lock allows - his count for
-- 30 Sep is posted. So:
--
--   med_settle_uncovered(Lot Tag, Jake Taylor)
--     -> units_covered 9, transactions_settled 1, transactions_repriced 0
--
-- Repriced ZERO again, which is the check that matters: the draw was
-- already costed at the catalog and the layer is at the catalog, so no
-- lot moved. Lot 32-26 reads $778.17 before and after.
--
-- NOTHING ON THE PLACE IS UNCOVERED ANY MORE. Both tag kinds at both
-- locations now have stock behind every dose drawn.
--
-- THIS LAYER CARRIES NO NEW MONEY, and that is the whole point of the
-- journal entry John asked for. The tags were billed in bulk to cattle
-- in September, so the cash is already through the P&L in a closed
-- month. The entry capitalizes the 167 that were still on hand at
-- 30 Sep; it does not buy them again. Written up for Jayci and Brenda in
-- docs/worksheets/2026-10-02_lot-tag-journal-entry.txt, with the one-day
-- reconciliation note that matters to them: the books capitalize at
-- 30 Sep close, while this shelf layer is dated 1 Oct because the
-- September count is locked.
--
-- A SMALL DATA NIT, left alone deliberately: Lot Tag carries
-- bottle_size_unit 'mL', which is nonsense for a tag and shows up on the
-- lot detail as "1.000 mL a head". It is label-only - cost_per_unit is
-- bottle_cost / bottle_size and cares nothing for the word - so fixing
-- it changes no number anywhere. It is still a data correction on live
-- books, so it waits for John to say the word.
-- =====================================================================

begin;

insert into public.med_purchase_lines (
    medication_id, location_id, qty_bottles, bottle_size, unit,
    unit_cost, qty_remaining, received_date, origin, mfr_lot_number)
select m.id, loc.id, 167, 1, coalesce(m.bottle_size_unit, 'doses'),
       m.cost_per_unit, 167, '2026-10-01'::date, 'adjustment', 'billed Sep - bulk to cattle'
  from public.medications m
  cross join public.med_stock_locations loc
 where m.name = 'Lot Tag' and loc.source_key = 'Jake Taylor'
   and not exists (select 1 from public.med_purchase_lines x
                    where x.medication_id = m.id and x.location_id = loc.id
                      and x.mfr_lot_number = 'billed Sep - bulk to cattle');

update public.med_txns t
   set notes = 'Lot tags on Jake Taylor''s shelf, 167 as of the morning of 1 Oct 2026 on John''s count. '
            || 'Billed to us LAST MONTH, in bulk to cattle, so the cost is already in September - a '
            || 'journal entry capitalizes the 167 unused at 30 Sep rather than this layer carrying '
            || 'new money. Priced at the catalog $0.4056 a tag (50 for $20.28). Dated 1 Oct, the '
            || 'earliest day his period lock allows.'
 where t.ref_kind = 'med_purchase_line'
   and t.ref_id = (select id from public.med_purchase_lines
                    where mfr_lot_number = 'billed Sep - bulk to cattle')
   and t.notes is null;

-- Cover the 9 he used on the 1st. A no-op on a re-run.
select public.med_settle_uncovered(
    (select id from public.medications where name = 'Lot Tag'),
    (select id from public.med_stock_locations where source_key = 'Jake Taylor'));

-- ---- verify ---------------------------------------------------------------
do $verify$
declare v_units numeric; v_val numeric; v_unc numeric; v_lot numeric; n integer;
begin
    select qty_units, value_fifo, uncovered_units into v_units, v_val, v_unc
      from public.med_on_hand
     where location_kind = 'buyer' and medication_name = 'Lot Tag';
    if v_units <> 158 then
        raise exception 'Jake reads % lot tags, not the 158 that 167 less 9 leaves', v_units;
    end if;
    if v_val <> 64.08 then raise exception 'Jake values his lot tags at %, not 64.08', v_val; end if;
    if coalesce(v_unc, 0) <> 0 then raise exception '% lot tag units still uncovered', v_unc; end if;

    -- covering uncovered usage must never reprice a lot
    select round(total_cost, 2) into v_lot from public.lot_processing_costs c
      join public.lots l on l.id = c.lot_id where l.lot_number = '32-26';
    if v_lot <> 778.17 then raise exception 'lot 32-26 reads %, not 778.17', v_lot; end if;

    -- the tag story is closed: nothing uncovered at either place
    select count(*) into n from public.med_on_hand
     where not location_is_test and medication_name in ('ID Tag','Lot Tag') and uncovered_units <> 0;
    if n > 0 then raise exception '% tag row(s) still carry uncovered usage', n; end if;

    select count(*) into n from (
      select pl.id from public.med_purchase_lines pl
        left join public.med_txn_layers tl on tl.purchase_line_id = pl.id
       group by pl.id, pl.qty_units, pl.qty_remaining
      having round(pl.qty_units - coalesce(sum(tl.qty_units), 0), 4) <> round(pl.qty_remaining, 4)) x;
    if n > 0 then raise exception '% layer(s) no longer tie', n; end if;

    raise notice 'VERIFIED: 158 lot tags at $64.08 on Jake''s shelf, his 9 covered, no tag usage uncovered anywhere, lot 32-26 unmoved.';
end
$verify$;

commit;
