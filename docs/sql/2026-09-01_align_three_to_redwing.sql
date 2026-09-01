-- =====================================================================
-- Move Corn (Feed), Corn Silage 2024 and Molasses to Redwing at 8/31/26
-- =====================================================================
-- These three opening balances came from the Performance Beef screen at
-- 8/30. Redwing's Feed & Mineral RM Inventory at 8/31 is the number the
-- three systems are being tied to, so the app moves to it.
--
-- WHY NOT A COUNT: a count books the difference to the VARIANCE ACCOUNT as
-- shrink or found feed. No shrink happened here - the opening figure was
-- taken from the wrong source. That account has to keep meaning "how good
-- are the allowances", so this is a seed correction, exactly as the 8/30
-- re-seed was.
--
-- WHY NOT DELETE AND RE-ADD: corn and molasses have had pounds drawn
-- against them (the 8/31 barn count), and deleting a layer with frozen
-- usage cost against it is the disaster this module exists to prevent.
--
-- WHAT IS PRESERVED: whatever has already been FED stays fed, at the cost
-- it froze at. The 8 lb of corn and 7 lb of molasses booked as shrink on
-- 8/31 keep their old rate - about 63c and $1.28. Frozen is frozen; only
-- what is still standing moves.
--
--   qty_lb_remaining := Redwing's on-hand
--   qty_lb           := that + what was already fed   (keeps the flow
--                        identity receipts - usage = remaining intact)
--   product_cost     := priced so the ON-HAND values at Redwing's figure
--
-- Apply in the Supabase SQL editor. One DO block, so any failure rolls
-- the whole thing back.
-- =====================================================================

DO $align$
DECLARE
    r        record;
    v_fed    numeric;
    v_newqty numeric;
    v_newusd numeric;
    v_id     uuid;
    n        integer;
    bad      text;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('Corn (Feed)',       854832.50::numeric, 74298.38::numeric),
            ('Corn Silage 2024', 1216290.00,          39180.48),
            ('Molasses',           23384.00,           4154.36)
        ) AS v(item, rw_lb, rw_usd)
    LOOP
        -- One layer, or the arithmetic below is ambiguous: "what was fed"
        -- and "what should remain" cannot be split across layers without
        -- someone deciding which layer gives up the pounds.
        SELECT count(*) INTO n
          FROM public.feed_receipts fr JOIN public.feed_items i ON i.id = fr.item_id
         WHERE i.name = r.item;
        IF n <> 1 THEN
            RAISE EXCEPTION
              'STOP: % has % layer(s), not 1. This script only corrects a single opening balance.', r.item, n;
        END IF;

        SELECT fr.id, fr.qty_lb - fr.qty_lb_remaining, fr.source
          INTO v_id, v_fed, bad
          FROM public.feed_receipts fr JOIN public.feed_items i ON i.id = fr.item_id
         WHERE i.name = r.item;

        IF bad <> 'opening_balance' THEN
            RAISE EXCEPTION 'STOP: %''s layer is a %, not an opening balance.', r.item, bad;
        END IF;

        IF r.rw_lb < 0 THEN
            RAISE EXCEPTION 'STOP: Redwing shows % negative for %. A FIFO layer cannot be negative.', r.rw_lb, r.item;
        END IF;

        v_newqty := r.rw_lb + v_fed;
        -- Price so the pounds STILL STANDING carry Redwing's value. Setting
        -- product_cost to Redwing's figure directly would spread it over the
        -- fed pounds too and land the on-hand value a little under.
        v_newusd := ROUND(v_newqty * r.rw_usd / NULLIF(r.rw_lb, 0), 2);

        UPDATE public.feed_receipts
           SET qty_lb           = v_newqty,
               qty_lb_remaining = r.rw_lb,
               product_cost     = v_newusd,
               notes = COALESCE(notes || ' ', '')
                     || 'Aligned to Redwing RM Inventory 2026-08-31 on ' || public.ranch_today()::text
                     || ': on hand set to ' || r.rw_lb::text || ' lb valued at $' || r.rw_usd::text
                     || '. ' || v_fed::text || ' lb already fed is preserved at its frozen cost.',
               updated_at = now()
         WHERE id = v_id;

        RAISE NOTICE '% -> % lb on hand, $% (kept % lb fed).',
            r.item, r.rw_lb, v_newusd, v_fed;
    END LOOP;

    -- Prove the on-hand now reads Redwing, to the cent.
    SELECT string_agg(x.item || ': ' || round(x.lb,2) || ' lb / $' || round(x.usd,2)
                      || ' (want ' || x.rw_lb || ' / $' || x.rw_usd || ')', '; ')
      INTO bad
      FROM (
        SELECT v.item, v.rw_lb, v.rw_usd,
               fr.qty_lb_remaining AS lb,
               fr.qty_lb_remaining * fr.unit_cost_per_lb AS usd
          FROM (VALUES
            ('Corn (Feed)',       854832.50::numeric, 74298.38::numeric),
            ('Corn Silage 2024', 1216290.00,          39180.48),
            ('Molasses',           23384.00,           4154.36)
          ) AS v(item, rw_lb, rw_usd)
          JOIN public.feed_items i  ON i.name = v.item
          JOIN public.feed_receipts fr ON fr.item_id = i.id
      ) x
     WHERE abs(x.lb - x.rw_lb) > 0.005 OR abs(x.usd - x.rw_usd) > 0.02;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'Did not land: %', bad;
    END IF;

    -- And that the books still add up: receipts minus usage = what is left.
    IF (SELECT COALESCE(SUM(qty_lb),0) FROM public.feed_receipts)
     - (SELECT COALESCE(SUM(qty_lb),0) FROM public.feed_usage)
    <> (SELECT COALESCE(SUM(qty_lb_remaining),0) FROM public.feed_receipts) THEN
        RAISE EXCEPTION 'The flow identity broke: receipts - usage no longer equals remaining.';
    END IF;

    RAISE NOTICE 'All three now read Redwing 8/31.';
END
$align$;


-- =====================================================================
-- Run this SECOND to see the result.
-- =====================================================================
SELECT i.name AS item,
       to_char(r.qty_lb_remaining, 'FM999,999,999.99')                  AS on_hand_lb,
       to_char(r.qty_lb_remaining * r.unit_cost_per_lb, 'FM999,990.00') AS on_hand_usd,
       to_char(r.unit_cost_per_lb * 2000, 'FM999,990.00')               AS per_ton,
       to_char(r.qty_lb - r.qty_lb_remaining, 'FM999,990.00')           AS already_fed_lb
  FROM public.feed_receipts r
  JOIN public.feed_items i ON i.id = r.item_id
 WHERE i.name IN ('Corn (Feed)','Corn Silage 2024','Molasses')
 ORDER BY i.name;
