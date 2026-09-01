-- =====================================================================
-- Put every bagged item in Bag Storage
-- =====================================================================
-- The 8/30 re-seed kept each layer wherever the old seed had put it, and
-- the old seed had put everything in the Commodity Barn. Four sacked items
-- - Limiter, Pennchlor, Ranly and Salt - are stacked on the bag pallet in
-- real life. Salt's default bay was pointing at the barn as well.
--
-- WHY THIS MATTERS AND IS NOT COSMETIC: FIFO runs per (item, location).
-- Leave it and the next pallet of Pennchlor entered will default to Bag
-- Storage, split that item across two locations, and on-hand-by-bay stops
-- reconciling - which is the one thing this module exists to protect.
-- Fixing it before the first count is free; fixing it after is a transfer
-- with a cost trail.
--
-- Selection is by DATA, not by a list of names: anything whose purchase
-- unit is a bag belongs on the bag pallet. A name list would go stale the
-- first time an item is added.
--
-- HOW TO RUN IT: paste the whole thing into the Supabase SQL editor.
-- It is ONE statement - a single DO block - because the editor swallows
-- begin;/commit;. Any RAISE EXCEPTION rolls the whole thing back.
-- =====================================================================

DO $bagged$
DECLARE
    v_bag    uuid;
    n        integer;
    v_before numeric;
    v_after  numeric;
    v_moved  integer;
    v_reptd  integer;
BEGIN
    -- 0. Only safe while nothing has been drawn down --------------------
    -- A layer that has been fed against is joined to frozen cost rows and
    -- to a location's count history. Moving one after the fact is a
    -- TRANSFER, which lays a new layer and leaves an audit trail; it is
    -- not this. Refuse rather than quietly do the wrong kind of move.
    SELECT count(*) INTO n FROM public.feed_usage;
    IF n > 0 THEN
        RAISE EXCEPTION
          'STOP: % feed_usage row(s) exist. Pounds have been drawn against these layers. Move the stock with a transfer, not by rewriting the layer.', n;
    END IF;

    SELECT count(*) INTO n FROM public.feed_counts WHERE status = 'posted';
    IF n > 0 THEN
        RAISE EXCEPTION
          'STOP: % posted count(s) exist. A count recorded book quantity AT a location; moving layers underneath it would make that history a lie.', n;
    END IF;

    SELECT id INTO v_bag FROM public.feed_storage_locations WHERE name = 'Bag Storage';
    IF v_bag IS NULL THEN
        RAISE EXCEPTION 'There is no location named "Bag Storage".';
    END IF;

    SELECT COALESCE(SUM(qty_lb_remaining), 0) INTO v_before FROM public.feed_receipts;

    -- 1. Move the layers -------------------------------------------------
    UPDATE public.feed_receipts r
       SET location_id = v_bag,
           notes = COALESCE(r.notes || ' ', '')
                   || 'Moved to Bag Storage 2026-08-31: bagged items are stored and counted on the bag pallet, not in the commodity barn. No pounds changed hands.',
           updated_at = now()
      FROM public.feed_items i
     WHERE i.id = r.item_id
       AND i.purchase_unit = 'bag'
       AND r.location_id IS DISTINCT FROM v_bag;
    GET DIAGNOSTICS v_moved = ROW_COUNT;

    -- 2. Point their default bay at the same place -----------------------
    -- Otherwise the next load in defaults back to the barn and re-splits
    -- the item, which is the failure this script is preventing.
    UPDATE public.feed_items
       SET default_location_id = v_bag, updated_at = now()
     WHERE purchase_unit = 'bag'
       AND default_location_id IS DISTINCT FROM v_bag;
    GET DIAGNOSTICS v_reptd = ROW_COUNT;

    -- 3. Prove no feed appeared or vanished ------------------------------
    SELECT COALESCE(SUM(qty_lb_remaining), 0) INTO v_after FROM public.feed_receipts;
    IF v_after <> v_before THEN
        RAISE EXCEPTION 'Total on hand changed from % lb to % lb. A move must not create or destroy feed.', v_before, v_after;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.feed_receipts r
          JOIN public.feed_items i ON i.id = r.item_id
         WHERE i.purchase_unit = 'bag' AND r.location_id <> v_bag) THEN
        RAISE EXCEPTION 'A bagged layer is still outside Bag Storage.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.feed_items
         WHERE purchase_unit = 'bag' AND default_location_id IS DISTINCT FROM v_bag) THEN
        RAISE EXCEPTION 'A bagged item still defaults to somewhere other than Bag Storage.';
    END IF;

    RAISE NOTICE 'Moved % layer(s) and repointed % item default(s). Total unchanged at % lb.',
        v_moved, v_reptd, v_before;
END
$bagged$;


-- =====================================================================
-- Run this SECOND to see where everything stands. The editor does not show
-- RAISE NOTICE, so this is how you read the result.
-- Expect: Commodity Barn 6 layers / 1,179,784 lb, Bag Storage 4 / 9,625 lb,
-- Terrell Silage pile 1 / 1,553,425 lb. Total still 2,742,834 lb.
-- =====================================================================
SELECT l.name                                      AS bay,
       count(r.id)                                 AS layers,
       to_char(COALESCE(SUM(r.qty_lb_remaining),0), 'FM999,999,999') AS on_hand_lb,
       to_char(COALESCE(SUM(r.product_cost),0), 'FM999,999,990.00')  AS value_usd,
       string_agg(i.name, ', ' ORDER BY i.name)     AS items
  FROM public.feed_storage_locations l
  LEFT JOIN public.feed_receipts r ON r.location_id = l.id
  LEFT JOIN public.feed_items i    ON i.id = r.item_id
 GROUP BY l.id, l.name
 ORDER BY l.name;
