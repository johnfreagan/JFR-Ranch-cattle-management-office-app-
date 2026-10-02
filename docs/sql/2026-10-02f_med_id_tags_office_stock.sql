-- =====================================================================
-- 5,000 ID tags in the medicine room, #1001-6000, at the catalog price.
-- =====================================================================
-- 2026-10-02. John: "We have 5000 id tags #1001-6000 in med room. Put in
-- inventory at the catalog price."
--
-- It closes the office half of the tag question. Jake Taylor holds
-- #2-1000 (999 tags, verified 2026-10-02) and the office holds the next
-- block, which is why the numbering picks up at 1001.
--
-- 5,000 doses x $0.4056 = **$2,028.00**. The catalog carries ID Tag as a
-- 50-dose bag at $20.28, so this is 100 bags, and cost_per_unit is a
-- GENERATED column off that - nothing here sets a price by hand.
--
-- WHY AN ADJUSTMENT LAYER AND NOT A COUNT. Three reasons, in order of
-- how much they matter:
--
--   1. The Ranch count for 30 Sep is POSTED. med_locked_through('Ranch')
--      is 2026-09-30 and med_purchase_lines carries the period-lock
--      trigger, so a layer dated on or before that is refused outright -
--      correctly. The tags were simply never on that count sheet.
--   2. A count is the shelf as somebody saw it on a day. Posting a new
--      one today would lock the Ranch period through 2 Oct and shut the
--      door on any 1-2 Oct doctoring still to be entered. John's rule
--      from yesterday stands: full counts at month end, every month.
--   3. Jayci's reconciliation is built on the 30 Sep balance. Found
--      stock belongs after it, in the open period, where she can see it
--      as its own line rather than as a changed opening figure.
--
-- So: origin 'adjustment', dated ranch_today(), no count_id. The ledger
-- trigger writes the matching +1 med_txns row by itself; its notes carry
-- the audit text, because an adjustment that cannot explain itself is
-- indistinguishable from a typo six months from now.
--
-- THE PRICE IS PROVISIONAL AND THE FILE SAYS SO. John, yesterday: "The
-- lot tag haven't been billed to us yet. Will check tomorrow use the
-- cost in catalog for now." Same for these. $0.4056 is the catalog, not
-- an invoice. When the invoice turns up and the real price differs, the
-- correction is this layer's unit_cost - it has been drawn against
-- nothing yet, so nothing downstream has to be reversed.
--
-- STILL OPEN AFTER THIS, and it needs John:
--   - Jake's 999 ID tags (#2-1000) are NOT in inventory. Nor are any lot
--     tags, at either place.
--   - So the 1 Oct processing draw at Jake Taylor took 9 ID tags and
--     9 Lot tags off a shelf that holds neither: both sit as uncovered
--     usage, $3.65 each, priced at catalog. This layer does NOT settle
--     them and must not - they came out of Jake's box, 150 miles from
--     the medicine room, and settling them here would charge the lot for
--     tags that never moved.
-- APPLIED 2026-10-02. The medicine room reads 5,000 ID tags, 100 bags,
-- $2,028.00, oldest layer 2 Oct. Ranch on-hand $22,018.50 all told. The
-- ledger carries the matching adjustment row, +5,000 units at $2,028.00,
-- with the audit note on it. Jake Taylor still shows 9 uncovered ID tags
-- and 9 uncovered Lot tags, $7.30, which is correct and is the open item
-- above.
-- =====================================================================

begin;

do $tags$
declare
    v_loc  uuid;
    v_med  uuid;
    v_line uuid;
    v_qty  numeric := 5000;
begin
    select id into v_loc from public.med_stock_locations
     where kind = 'ranch' and not is_test;
    select id into v_med from public.medications where name = 'ID Tag';
    if v_loc is null or v_med is null then
        raise exception 'the Ranch location or the ID Tag medication is missing';
    end if;

    -- Idempotent: the same block of tags must not land twice.
    if exists (select 1 from public.med_purchase_lines
                where medication_id = v_med and location_id = v_loc
                  and origin = 'adjustment' and mfr_lot_number = '#1001-6000') then
        raise notice 'SKIPPED: ID tags #1001-6000 are already on the shelf.';
        return;
    end if;

    -- Unit-normalized, the same shape every other layer on the place has:
    -- bottle_size 1 and qty_bottles in units, so FIFO arithmetic never has
    -- to care what size container the stock arrived in. med_on_hand still
    -- reports 100 bags, because bottles_equiv divides by the CATALOG size.
    -- qty_units is GENERATED (qty_bottles x bottle_size) and refuses a
    -- value, the same way medications.cost_per_unit does. Derived numbers
    -- are derived in one place; that is the point of them.
    insert into public.med_purchase_lines (
        medication_id, location_id, qty_bottles, bottle_size, unit,
        unit_cost, qty_remaining, received_date, origin, mfr_lot_number
    )
    select v_med, v_loc, v_qty, 1, coalesce(m.bottle_size_unit, 'doses'),
           m.cost_per_unit, v_qty, public.ranch_today(), 'adjustment',
           '#1001-6000'
      from public.medications m
     where m.id = v_med
    returning id into v_line;

    -- The ledger row the trigger just wrote, told why it exists.
    update public.med_txns
       set notes = 'Office stock found after the 30 Sep count: 5,000 ID tags, '
                || '#1001-6000, in the medicine room. Priced at the catalog '
                || '$0.4056 a tag (50-dose bag at $20.28) because the invoice '
                || 'has not been found yet - correct this layer''s unit_cost '
                || 'when it is. Entered on John''s instruction 2026-10-02.'
     where ref_kind = 'med_purchase_line' and ref_id = v_line;

    raise notice 'ID tags #1001-6000 on the shelf: % units.', v_qty;
end
$tags$;

-- ---- verify ---------------------------------------------------------------
do $verify$
declare
    v_units numeric;
    v_value numeric;
    v_bags  numeric;
    v_unc   numeric;
    n       integer;
begin
    select qty_units, round(qty_units * avg_unit_cost, 2), bottles_equiv, uncovered_units
      into v_units, v_value, v_bags, v_unc
      from public.med_on_hand
     where location_kind = 'ranch' and not location_is_test
       and medication_name = 'ID Tag';

    if v_units <> 5000 then
        raise exception 'the medicine room reads % ID tags, not 5000', v_units;
    end if;
    if v_value <> 2028.00 then
        raise exception 'the medicine room values its ID tags at %, not 2028.00', v_value;
    end if;
    if v_bags <> 100 then
        raise exception '% bags, not 100 - the catalog bag size has moved', v_bags;
    end if;
    if coalesce(v_unc, 0) <> 0 then
        raise exception 'the medicine room has % uncovered tag units, which it should not', v_unc;
    end if;

    -- the layer must not have been dragged into the locked period
    select count(*) into n from public.med_purchase_lines l
      join public.med_stock_locations loc on loc.id = l.location_id
     where l.mfr_lot_number = '#1001-6000'
       and l.received_date <= public.med_locked_through(loc.id);
    if n > 0 then
        raise exception 'the tag layer is dated inside a locked period';
    end if;

    -- and Jake's uncovered tags must still be uncovered: they came out of
    -- HIS box, and this layer is not allowed to quietly settle them
    select coalesce(sum(uncovered_units), 0) into v_unc
      from public.med_on_hand
     where location_kind = 'buyer' and medication_name in ('ID Tag', 'Lot Tag');
    raise notice 'Jake Taylor still carries % uncovered tag units, as expected.', v_unc;

    raise notice 'VERIFIED: 5,000 ID tags, #1001-6000, $2,028.00, 100 bags, medicine room.';
end
$verify$;

commit;
