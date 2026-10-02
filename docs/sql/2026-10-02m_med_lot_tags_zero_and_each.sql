-- =====================================================================
-- Lot tags go in free, and both tags are counted in "each".
-- =====================================================================
-- APPLIED 2026-10-02, two instructions from John minutes apart:
--
--   "Let's put the lot tags in Jake's inventory at zero cost and will
--    start adding cost with new purchases in future"
--   "Let's change both lot tags and id tags to 'each' not doses"
--
-- THIS REVERSES THE PRICING IN 2026-10-02l, WHICH STANDS AS HISTORY.
-- That file put the 167 lot tags in at the catalog $0.4056 ($67.74) and
-- drafted a journal entry to capitalize them out of September. John chose
-- the simpler road instead: the tags were billed in bulk to cattle last
-- month, the cost is already through September, and it is not charged a
-- second time. Cost starts with the next purchase.
--
-- **SO THERE IS NO JOURNAL ENTRY.** September keeps the bulk expense,
-- nothing is capitalized, and there is nothing for Jayci and Brenda to
-- post. The memo written for them an hour earlier is withdrawn in place
-- rather than deleted, so nobody sends a stale one.
--
-- WHAT WENT TO ZERO
--
--   the layer                167 tags, Jake Taylor, unit_cost -> 0
--   the 9 already drawn      the allocation AND the txn -> 0
--
-- The second one is a deliberate correction, not a recalculation. A
-- consumed allocation is frozen on purpose - that is what makes a
-- reversal exact - but these 9 came off the layer John has just declared
-- free, and free stock cannot charge a lot. Leaving them would have put
-- $3.65 of cost on 32-26 for tags that cost nothing.
--
-- WHAT IT MOVED, and it is the only thing that moved:
--
--   lot 32-26 Lot Tag line   $17.04 -> $13.38   (42 head, $0.3187 a head)
--   lot 32-26 total          $778.17 -> $774.52
--   processing, every lot    $99,530.31 -> $99,526.66
--   on hand, both pools      $24,992.82 -> $24,928.74
--
-- The $13.38 that remains is right, not a leftover: the 30 Sep receipt
-- (33 head) has no draw, so it still reads the catalog at $0.4056 a head.
-- Only the 1 Oct receipt (9 head) drew off the free layer, at $0. The
-- blend across 42 head is $0.3187. Pre-go-live receipts keep reading the
-- catalog, which is how every other medicine behaves and is why the
-- catalog price is deliberately NOT zeroed here.
--
-- ID TAGS ARE STILL AT CATALOG, on purpose. John, earlier the same day:
-- the ~6,000 tags at $0.40 are "kind of immaterial in the dollars", and
-- he put them in at catalog so per-head processing cost reads right. Lot
-- tags went the other way because they were billed in bulk to the cattle
-- last month specifically. Different facts, different answer, both his.
--
-- "EACH", NOT DOSES. A tag is not a dose and Lot Tag was carrying 'mL',
-- which read on the lot detail as "1.000 mL a head". Changed in two
-- places: the catalog, and the snapshot each existing tag layer carries
-- in its own `unit` column, so the shelf does not show a mix. Label only
-- - cost_per_unit is bottle_cost / bottle_size and cares nothing for the
-- word, which the gate below proves.
-- =====================================================================

begin;

-- 1. the layer carries no money
update public.med_purchase_lines
   set unit_cost = 0
 where mfr_lot_number = 'billed Sep - bulk to cattle';

-- 2. and neither do the 9 that came off it
update public.med_txn_layers tl
   set unit_cost = 0
 where tl.purchase_line_id = (select id from public.med_purchase_lines
                               where mfr_lot_number = 'billed Sep - bulk to cattle');

update public.med_txns t
   set total_cost = 0,
       notes = coalesce(t.notes || ' | ', '')
            || 'Repriced to $0 on 2026-10-02: John put the lot tags in at zero cost, '
            || 'cost to start with new purchases. These 9 came off that layer, so they '
            || 'cost the lot nothing either.'
 where t.direction = -1
   and t.medication_id = (select id from public.medications where name = 'Lot Tag')
   and t.id in (select tl.txn_id from public.med_txn_layers tl
                 where tl.purchase_line_id = (select id from public.med_purchase_lines
                                               where mfr_lot_number = 'billed Sep - bulk to cattle'))
   and t.total_cost <> 0;

-- 3. the ledger row that created the layer says what it is now
update public.med_txns t
   set total_cost = 0,
       notes = 'Lot tags on Jake Taylor''s shelf, 167 as of the morning of 1 Oct 2026 on John''s '
            || 'count, AT ZERO COST. John 2026-10-02: "Let''s put the lot tags in Jake''s inventory '
            || 'at zero cost and will start adding cost with new purchases in future." They were '
            || 'billed in bulk to cattle last month, so the cost is already through September and '
            || 'is not charged again - which also means there is nothing to capitalize and no '
            || 'journal entry. Dated 1 Oct, the earliest day his period lock allows.'
 where t.ref_kind = 'med_purchase_line'
   and t.ref_id = (select id from public.med_purchase_lines
                    where mfr_lot_number = 'billed Sep - bulk to cattle');

-- 4. a tag is counted in "each"
update public.medications
   set bottle_size_unit = 'each'
 where name in ('ID Tag', 'Lot Tag');

update public.med_purchase_lines l
   set unit = 'each'
 where l.medication_id in (select id from public.medications where name in ('ID Tag', 'Lot Tag'));

-- ---- verify ---------------------------------------------------------------
do $verify$
declare
    v_units numeric; v_val numeric; v_unc numeric; v_unit text;
    v_line numeric; v_lot numeric; n integer;
begin
    -- free, and still 158 of them
    select qty_units, value_fifo, uncovered_units, unit
      into v_units, v_val, v_unc, v_unit
      from public.med_on_hand
     where location_kind = 'buyer' and medication_name = 'Lot Tag';
    if v_units <> 158 then raise exception 'Jake reads % lot tags, not 158', v_units; end if;
    if v_val <> 0 then raise exception 'Jake values his lot tags at %, not 0', v_val; end if;
    if coalesce(v_unc, 0) <> 0 then raise exception '% lot tag units uncovered', v_unc; end if;
    if v_unit <> 'each' then raise exception 'lot tags read in %, not each', v_unit; end if;

    select unit into v_unit from public.med_on_hand
     where location_kind = 'ranch' and medication_name = 'ID Tag';
    if v_unit <> 'each' then raise exception 'ID tags read in %, not each', v_unit; end if;

    -- the catalog price survived the unit change: label only
    select cost_per_unit into v_val from public.medications where name = 'Lot Tag';
    if round(v_val, 4) <> 0.4056 then
        raise exception 'the Lot Tag catalog now reads % a tag - the unit change moved a price', v_val;
    end if;

    -- ID tags unchanged: still at catalog, both pools
    select round(sum(value_fifo), 2) into v_val from public.med_on_hand
     where medication_name = 'ID Tag' and not location_is_test;
    if v_val <> 2429.14 then
        raise exception 'ID tags now value at %, not the 2429.14 they went in at', v_val;
    end if;

    -- 32-26: the drawn 9 cost nothing, the undrawn 33 still read the catalog
    select round(total_cost, 2) into v_line
      from public.lot_processing_cost_detail d join public.lots l on l.id = d.lot_id
     where l.lot_number = '32-26' and d.med_name = 'Lot Tag';
    if v_line <> 13.38 then
        raise exception 'the 32-26 Lot Tag line reads %, not the 13.38 that 33 head at catalog leaves', v_line;
    end if;

    select round(total_cost, 2) into v_lot from public.lot_processing_costs c
      join public.lots l on l.id = c.lot_id where l.lot_number = '32-26';
    if v_lot <> 774.52 then raise exception 'lot 32-26 reads %, not 774.52', v_lot; end if;

    -- nothing else on the place moved: only 32-26 differs from the snapshot,
    -- and only by the weight estimate ($266.16) less these tags ($3.65)
    select count(*) into n
      from public._proc_cost_snapshot_20261002 s
      full join public.lot_processing_costs c on c.lot_id = s.lot_id
     where round(coalesce(c.total_cost, 0) - coalesce(s.total_cost, 0), 2) <> 0
       and coalesce(c.lot_id, s.lot_id) <> (select id from public.lots where lot_number = '32-26');
    if n > 0 then raise exception '% lot(s) other than 32-26 moved', n; end if;

    select count(*) into n from (
      select pl.id from public.med_purchase_lines pl
        left join public.med_txn_layers tl on tl.purchase_line_id = pl.id
       group by pl.id, pl.qty_units, pl.qty_remaining
      having round(pl.qty_units - coalesce(sum(tl.qty_units), 0), 4) <> round(pl.qty_remaining, 4)) x;
    if n > 0 then raise exception '% layer(s) no longer tie', n; end if;

    raise notice 'VERIFIED: 158 free lot tags, both tags in "each", 32-26 at $774.52, ID tags untouched at $2,429.14.';
end
$verify$;

commit;
