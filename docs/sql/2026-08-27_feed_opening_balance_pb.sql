-- =====================================================================
-- Feed opening balance, seeded from the Performance Beef inventory screen
-- =====================================================================
-- 2026-08-27. Run AFTER docs/sql/2026-08-27_feed_inventory.sql.
-- Supersedes 2026-08-27_feed_opening_balance.sql, which covered only the
-- eight commodities on the group invoice and guessed at a 50 lb sack for
-- the two additives. This one takes POUNDS directly, as PB reports them,
-- so there is no sack-size guess anywhere in it.
--
-- WHAT THE PB SCREEN SHOWED (2026-08-27), and what this does with it:
--
--   11 items with a positive balance  -> loaded, 2,772,454 lb, $162,072.52
--    2 items at zero                  -> catalog entry only, no stock
--    4 items NEGATIVE                 -> NOT loaded, listed loudly
--
-- The four negatives are the important part. A negative on-hand means PB
-- was told to feed more than it was ever told was received:
--
--   Corn                       -1,393 lb
--   Deccox- Corrid Crumbles      -756 lb
--   RTU Silage Tran 1 2025    -29,918 lb
--   RTU Silage Premix 2025 -1,109,171 lb   <- 554 tons; not drift
--
-- A negative is not a quantity, so it cannot be an opening balance, and
-- feed_receipts.qty_lb CHECK (qty_lb > 0) would refuse it anyway. Those
-- four get a catalog entry and nothing else. Count the bays and enter what
-- is actually there.
--
-- COST BASIS: PB's Cost Per Ton, converted at qty_lb * $/ton / 2000.
-- These are delivered prices - they go in whole, never split into freight.
--
-- DRY MATTER is recorded in the item's notes and used nowhere. It is a
-- nutrition figure; inventory is as fed. Relieving a bay by dry matter
-- would leave roughly 12% of every load as a phantom balance.
--
-- EDIT BEFORE RUNNING: the POUNDS column, and v_default_bay. Rows keep a
-- bay column so items can be split across real bays instead of all landing
-- in one place.
--
-- Re-running refuses to double-stock and names every offender.
--
-- Verified 2026-08-27 on a scratch PostgreSQL 16 against the real
-- migration: 17 items, 11 balances, negatives skipped and reported, zeros
-- catalogued, per-ton prices round-tripping exactly, and the rerun guard
-- firing.
-- =====================================================================

DO $opening$
DECLARE
    -- Any row below with a NULL bay lands here. Set it to whatever you
    -- actually call the place most of this is stored; you can split items
    -- into their real bays afterwards with Feed -> Feed Out -> Transfer.
    v_default_bay text := 'Commodity Barn';

    row_rec     record;
    v_loc       uuid;
    v_item      uuid;
    v_bay       text;
    v_cost      numeric;
    v_made_item integer := 0;
    v_made_loc  integer := 0;
    v_made_rec  integer := 0;
    v_skipped   text[] := '{}';
    v_zero      text[] := '{}';
    v_dupes     text[] := '{}';
    v_total_lb  numeric := 0;
    v_total_usd numeric := 0;
BEGIN
FOR row_rec IN
    SELECT * FROM (VALUES
    -- item name                  | type            | category   | $/ton   | POUNDS ON HAND | BAY (null = default) | dry matter
      ('Corn hopper bin'          ,'bulk_commodity','Energy'    , 158.15  ,   879807::numeric, NULL::text          , 86.0),
      ('Whole Cottonseed'         ,'bulk_commodity','Protein'   , 255.00  ,   177370         , NULL                , 88.0),
      ('Peanut Hulls'             ,'bulk_commodity','Roughage'  , 190.00  ,    76365         , NULL                , 90.0),
      ('DDG'                      ,'bulk_commodity','Protein'   , 245.00  ,    27522         , NULL                , 90.0),
      ('Cottonseed Hulls'         ,'bulk_commodity','Roughage'  , 458.00  ,        0         , NULL                , 95.0),
      ('Molasses'                 ,'bulk_commodity','Energy'    , 365.00  ,    26127         , NULL                , 65.0),
      ('Limiter- Calcium Chloride','additive'      ,'Additive'  , 720.00  ,     4703         , NULL                , 90.0),
      ('Salt'                     ,'mineral'       ,'Mineral'   , 185.00  ,      195         , NULL                , 90.0),
      ('2024 Corn Silage'         ,'bulk_commodity','Roughage'  ,  58.08  ,  1553425         , NULL                , 35.0),
      ('Corn'                     ,'bulk_commodity','Energy'    , 132.50  ,    -1393         , NULL                , 85.0),
      ('Deccox- Corrid Crumbles'  ,'additive'      ,'Additive'  ,2800.00  ,     -756         , NULL                , 90.0),
      ('Pennchlor 50G'            ,'additive'      ,'Additive'  ,5200.00  ,     1124         , NULL                , 90.0),
      ('RTU Silage Premix 2025'   ,'additive'      ,'Additive'  , 182.71  , -1109171         , NULL                , 87.0),
      ('RTU Silage Tran 1 2025'   ,'additive'      ,'Additive'  , 241.09  ,   -29918         , NULL                , 88.0),
      ('SoyHull Pellets'          ,'bulk_commodity','Byproduct' , 208.00  ,    21292         , NULL                , 91.0),
      ('Ranly mixing mineral'     ,'mineral'       ,'Mineral'   ,1120.00  ,     4524         , NULL                , 90.0),
      ('Grass Hay'                ,'bulk_commodity','Hay'       , 100.00  ,        0         , NULL                , 90.0)
    ) AS t(item_name, item_type, category, cost_per_ton, qty_lb, bay_name, dry_pct)
LOOP
    v_bay := COALESCE(row_rec.bay_name, v_default_bay);

    SELECT id INTO v_loc FROM public.feed_storage_locations WHERE lower(name) = lower(v_bay);
    IF v_loc IS NULL THEN
        INSERT INTO public.feed_storage_locations (name, kind, is_bulk)
        VALUES (v_bay, 'bay', true) RETURNING id INTO v_loc;
        v_made_loc := v_made_loc + 1;
    END IF;

    SELECT id INTO v_item FROM public.feed_items WHERE lower(name) = lower(row_rec.item_name);
    IF v_item IS NULL THEN
        INSERT INTO public.feed_items (name, item_type, category, purchase_unit,
                                       lb_per_purchase_unit, is_counted, pb_name,
                                       default_location_id, notes)
        VALUES (row_rec.item_name, row_rec.item_type, row_rec.category, 'ton', 2000,
                false, row_rec.item_name, v_loc,
                'Performance Beef dry matter ' || row_rec.dry_pct || '%. Dry matter is a '
                || 'nutrition figure and is NOT used for inventory - pounds here are as fed.')
        RETURNING id INTO v_item;
        v_made_item := v_made_item + 1;
    END IF;

    -- A negative on-hand in PB means more was fed than was ever received.
    -- That is not a quantity, so it does not become an opening balance.
    IF row_rec.qty_lb < 0 THEN
        v_skipped := v_skipped || (row_rec.item_name || '  ' || to_char(row_rec.qty_lb,'FM999,999,999') || ' lb');
        CONTINUE;
    END IF;
    IF row_rec.qty_lb = 0 THEN
        v_zero := v_zero || row_rec.item_name;
        CONTINUE;
    END IF;

    IF EXISTS (SELECT 1 FROM public.feed_receipts
                WHERE item_id = v_item AND location_id = v_loc
                  AND ticket_number = 'OPENING BALANCE') THEN
        v_dupes := v_dupes || (row_rec.item_name || ' in ' || v_bay);
        CONTINUE;
    END IF;

    v_cost := ROUND(row_rec.qty_lb * row_rec.cost_per_ton / 2000.0, 2);

    INSERT INTO public.feed_receipts (
        receipt_date, item_id, location_id, vendor, ticket_number, notes,
        qty_purchase_units, qty_lb, product_cost, cost_pending, qty_lb_remaining, source)
    VALUES (
        public.ranch_today(), v_item, v_loc, '(opening balance)', 'OPENING BALANCE',
        'Opening balance from the Performance Beef inventory screen, 2026-08-27.',
        ROUND(row_rec.qty_lb / 2000.0, 4), row_rec.qty_lb, v_cost, false,
        row_rec.qty_lb, 'purchase');

    v_made_rec  := v_made_rec + 1;
    v_total_lb  := v_total_lb + row_rec.qty_lb;
    v_total_usd := v_total_usd + v_cost;
END LOOP;

IF array_length(v_dupes,1) IS NOT NULL THEN
    RAISE EXCEPTION E'Refusing to double-stock. An opening balance already exists for:\n  - %',
        array_to_string(v_dupes, E'\n  - ');
END IF;

RAISE NOTICE '% item(s) created, % location(s) created, % opening balance(s) laid down.',
    v_made_item, v_made_loc, v_made_rec;
RAISE NOTICE 'Total: % lb, $%', to_char(v_total_lb,'FM999,999,999'), to_char(v_total_usd,'FM999,999,990.00');

IF array_length(v_zero,1) IS NOT NULL THEN
    RAISE NOTICE 'Zero on hand - catalog entry made, no stock: %', array_to_string(v_zero, ', ');
END IF;
IF array_length(v_skipped,1) IS NOT NULL THEN
    RAISE NOTICE '--------------------------------------------------------';
    RAISE NOTICE 'NEGATIVE in PB - NOT loaded. More was fed than was ever received:';
    FOR row_rec IN SELECT unnest(v_skipped) AS s LOOP
        RAISE NOTICE '   %', row_rec.s;
    END LOOP;
    RAISE NOTICE 'Count these bays and enter what is really there.';
END IF;
END
$opening$;
