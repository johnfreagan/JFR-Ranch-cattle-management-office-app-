-- =====================================================================
-- Feed inventory: opening balance
-- =====================================================================
-- 2026-08-27. Run AFTER docs/sql/2026-08-27_feed_inventory.sql.
--
-- There is no special "opening balance" concept in this schema, and that
-- is deliberate: an opening balance IS a FIFO layer, so it is entered as
-- an ordinary load in. Giving it its own table would mean two code paths
-- for the same thing, forever.
--
-- HOW TO USE
--
-- Run it as-is and it creates the eight commodities off the 2026-08-27 PB
-- invoice and nothing else - no bays, no stock. Then edit the BAY and
-- AMOUNT columns and run it again to lay the opening stock down.
--
-- Rows with a NULL bay or a zero amount create the catalog entry only.
-- Re-running is safe: it REFUSES to double-stock a bay that already has
-- an opening balance, and it never overwrites an item you have edited in
-- the app.
--
-- COST BASIS: the $/unit figures are PB's own Cost Per Ton off the
-- 2026-08-27 invoice. They are delivered prices, so they go in whole -
-- do not split any of it into freight or it double-counts. Use a real
-- delivered invoice instead wherever you have the ticket. Leave $/unit
-- NULL only if you genuinely have no basis: the load is then counted but
-- not valued, and shows as unpriced until you price it in the app.
--
-- ⚠ THE TWO ADDITIVES ARE A GUESS. Deccox-Corrid and Pennchlor are
-- entered at 50 lb a sack, with $/bag derived from PB's $/ton
-- ($2,800/ton -> $70 a 50 lb bag; $5,200/ton -> $130). CONFIRM THE REAL
-- SACK WEIGHT and move lb/unit and $/unit together if it differs - a
-- 25 lb sack is $35, not $70.
--
-- Verified 2026-08-27 on a scratch PostgreSQL 16 against the real
-- migration: catalog-only run, filled run (15.8 ton corn -> 31,600 lb at
-- $0.07908/lb = $2,498.77), an unpriced row counted but not valued, and
-- a re-run correctly refusing to double-stock.
-- =====================================================================

DO $opening$
DECLARE
    row_rec     record;
    v_loc       uuid;
    v_item      uuid;
    v_lb        numeric;
    v_cost      numeric;
    v_made_item integer := 0;
    v_made_loc  integer := 0;
    v_made_rec  integer := 0;
    v_dupes     text[] := '{}';
BEGIN
FOR row_rec IN
    SELECT * FROM (VALUES
    -- item name              | type              | unit  | lb/unit | PB name                    | BAY (null = skip) | AMOUNT   | $/unit
      ('Corn hopper bin'      ,'bulk_commodity'   ,'ton'  , 2000    ,'Corn hopper bin'           , NULL::text        , NULL::numeric, 158.15),
      ('Molasses'             ,'bulk_commodity'   ,'ton'  , 2000    ,'Molasses'                  , NULL              , NULL     , 365.00),
      ('DDG'                  ,'bulk_commodity'   ,'ton'  , 2000    ,'DDG'                       , NULL              , NULL     , 245.00),
      ('Peanut Hulls'         ,'bulk_commodity'   ,'ton'  , 2000    ,'Peanut Hulls'              , NULL              , NULL     , 190.00),
      ('SoyHull Pellets'      ,'bulk_commodity'   ,'ton'  , 2000    ,'SoyHull Pellets'           , NULL              , NULL     , 208.00),
      ('Whole Cottonseed'     ,'bulk_commodity'   ,'ton'  , 2000    ,'Whole Cottonseed'          , NULL              , NULL     , 255.00),
      ('Deccox-Corrid Crumbles','additive'        ,'bag'  ,   50    ,'Deccox- Corrid Crumbles'   , NULL              , NULL     , 70.00),
      ('Pennchlor 50G'        ,'additive'         ,'bag'  ,   50    ,'Pennchlor 50G'             , NULL              , NULL     , 130.00)
    ) AS t(item_name, item_type, purchase_unit, lb_per_unit, pb_name, bay_name, qty_units, cost_per_unit)
LOOP
    -- bay
    v_loc := NULL;
    IF row_rec.bay_name IS NOT NULL THEN
        SELECT id INTO v_loc FROM public.feed_storage_locations
         WHERE lower(name) = lower(row_rec.bay_name);
        IF v_loc IS NULL THEN
            INSERT INTO public.feed_storage_locations (name, kind, is_bulk)
            VALUES (row_rec.bay_name, CASE WHEN row_rec.purchase_unit='bag' THEN 'pallet' ELSE 'bay' END,
                    row_rec.purchase_unit <> 'bag')
            RETURNING id INTO v_loc;
            v_made_loc := v_made_loc + 1;
        END IF;
    END IF;

    -- item (never clobbers one that already exists)
    SELECT id INTO v_item FROM public.feed_items WHERE lower(name) = lower(row_rec.item_name);
    IF v_item IS NULL THEN
        INSERT INTO public.feed_items (name, item_type, purchase_unit, lb_per_purchase_unit,
                                       is_counted, pb_name, default_location_id)
        VALUES (row_rec.item_name, row_rec.item_type, row_rec.purchase_unit, row_rec.lb_per_unit,
                row_rec.purchase_unit = 'bag', row_rec.pb_name, v_loc)
        RETURNING id INTO v_item;
        v_made_item := v_made_item + 1;
    ELSIF v_loc IS NOT NULL THEN
        UPDATE public.feed_items SET default_location_id = COALESCE(default_location_id, v_loc)
         WHERE id = v_item;
    END IF;

    CONTINUE WHEN v_loc IS NULL OR COALESCE(row_rec.qty_units,0) <= 0;

    -- Running twice must not double-stock the bay.
    IF EXISTS (SELECT 1 FROM public.feed_receipts
                WHERE item_id = v_item AND location_id = v_loc
                  AND ticket_number = 'OPENING BALANCE') THEN
        v_dupes := v_dupes || (row_rec.item_name || ' in ' || row_rec.bay_name);
        CONTINUE;
    END IF;

    v_lb   := row_rec.qty_units * row_rec.lb_per_unit;
    v_cost := CASE WHEN row_rec.cost_per_unit IS NULL THEN NULL
                   ELSE ROUND(row_rec.qty_units * row_rec.cost_per_unit, 2) END;

    INSERT INTO public.feed_receipts (
        receipt_date, item_id, location_id, vendor, ticket_number, notes,
        qty_purchase_units, qty_lb, product_cost, cost_pending, qty_lb_remaining, source)
    VALUES (
        public.ranch_today(), v_item, v_loc, '(opening balance)', 'OPENING BALANCE',
        'Opening balance at go-live. Counted/estimated, not a delivery.',
        row_rec.qty_units, v_lb, v_cost, (v_cost IS NULL), v_lb, 'purchase');
    v_made_rec := v_made_rec + 1;
END LOOP;

IF array_length(v_dupes,1) IS NOT NULL THEN
    RAISE EXCEPTION E'Refusing to double-stock. An opening balance already exists for:\n  - %\nDelete those loads first if you meant to redo them.',
        array_to_string(v_dupes, E'\n  - ');
END IF;

RAISE NOTICE 'Opening balance: % item(s) created, % location(s) created, % load(s) in.',
    v_made_item, v_made_loc, v_made_rec;
END
$opening$;
