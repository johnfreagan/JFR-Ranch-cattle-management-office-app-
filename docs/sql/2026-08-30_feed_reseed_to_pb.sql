-- =====================================================================
-- Re-seed the office app's feed layers to PB's inventory at 2026-08-30
-- =====================================================================
-- The opening balance was seeded from a PB inventory screen pulled on an
-- arbitrary day, and it has drifted. This replaces it with PB's figures as
-- of 8/30 so the app and PB start from the same number.
--
-- THIS IS A SEED CORRECTION, NOT AN ADJUSTMENT. Nothing has been fed out of
-- the app yet - `feed_usage` is empty - so no cost has frozen, no layer has
-- been consumed, and rewriting the opening quantities harms nothing and
-- rewrites no history. The script REFUSES to run if that is no longer true.
--
-- Deliberately NOT done through post_feed_count: a count posts shrink and
-- found-feed rows into the variance account, and this is neither. It is a
-- bad seed being replaced. The variance account has to stay clean for the
-- real counts that start 8/31.
--
-- PRICES ARE PB'S COST PER TON, which is what the original seed used too -
-- every existing layer values out to PB's exact rate. They are provisional.
-- Because nothing is consumed, any price here can still be corrected in the
-- app (Feed -> Loads in) right up until the first pound is fed.
--
-- NEGATIVE BALANCES BECOME ZERO. PB carries four: Corn -1,393,
-- Deccox -836, RTU Silage Premix 2025 -1,109,171, RTU Silage Tran 1 -29,918.
-- A FIFO layer cannot be negative and the app will not pretend otherwise -
-- that refusal is the point. They come in at zero and the 8/31 barn walk
-- gives them a real number.
--
-- Order of operations this replaces itself into:
--   today  - this script: app == PB at 8/30
--   8/31   - barn walk, posted as a physical COUNT in the app; that variance
--            is real and goes to the variance account. That is the 9/1 lock.
--   9/1    - feed charges direct to lots. Everything after is a count.
-- =====================================================================
--
-- HOW TO RUN IT: paste the whole thing into the Supabase SQL editor.
--
-- It is ONE statement - a single DO block - on purpose. The SQL editor
-- swallows `begin;`/`commit;`, so a wrapped script can report "Success. No
-- rows returned" while having applied nothing, or worse, applied half. A DO
-- block is its own transaction with no wrapper to swallow: every guard,
-- the DELETE, the INSERT and the verification either all land or none do.
-- Any RAISE EXCEPTION below rolls the whole thing back.
-- =====================================================================

DO $reseed$
DECLARE
    n        integer;
    missing  text;
    dupes    text;
    bad      text;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Refuse unless this is still only a seed
    -- -----------------------------------------------------------------
    SELECT count(*) INTO n FROM public.feed_usage;
    IF n > 0 THEN
        RAISE EXCEPTION 'STOP: % feed_usage row(s) exist. Cost has frozen against these layers. Re-seeding would rewrite history - use a physical count instead.', n;
    END IF;

    SELECT count(*) INTO n FROM public.feed_batches;
    IF n > 0 THEN
        RAISE EXCEPTION 'STOP: % feed_batches exist. Use a physical count instead.', n;
    END IF;

    SELECT count(*) INTO n FROM public.feed_counts WHERE status = 'posted';
    IF n > 0 THEN
        RAISE EXCEPTION 'STOP: % posted count(s) exist. The books have been counted once already - correct with another count, not by re-seeding.', n;
    END IF;

    IF to_regclass('public.feed_receipts') IS NULL THEN
        RAISE EXCEPTION 'The feed module is not installed.';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. PB inventory, 2026-08-30. Matched to feed_items on pb_name.
    -- -----------------------------------------------------------------
    CREATE TEMP TABLE pb_inv (pb_name text PRIMARY KEY, qty_lb numeric, cost_per_ton numeric);
    INSERT INTO pb_inv (pb_name, qty_lb, cost_per_ton) VALUES
        ('Corn hopper bin',            866388,  158.15),
        ('Whole Cottonseed',           174418,  255.00),
        ('Peanut Hulls',                73443,  190.00),
        ('DDG',                         21658,  245.00),
        ('Cottonseed Hulls',                0,  458.00),
        ('Molasses',                    25547,  365.00),
        ('Limiter- Calcium Chloride',    4703,  720.00),
        ('Salt',                          195,  185.00),
        ('2024 Corn Silage',          1553425,   58.08),
        ('Corn',                        -1393,  132.50),   -- negative -> 0
        ('Deccox- Corrid Crumbles',      -836, 2800.00),   -- negative -> 0
        ('Pennchlor 50G',                 704, 5200.00),
        ('RTU Silage Premix 2025',   -1109171,  182.71),   -- negative -> 0
        ('RTU Silage Tran 1 2025',     -29918,  241.09),   -- negative -> 0
        ('SoyHull Pellets',             18330,  208.00),
        ('Ranly mixing mineral',         4023, 1120.00);
        -- Grass Hay is not on PB's sheet. It is already zero and is left alone.

    -- -----------------------------------------------------------------
    -- 2. Every PB line must resolve to exactly one feed_item, or stop.
    -- A silently unmatched row would leave that commodity on its old
    -- figure while everything around it moved - the worst outcome.
    -- -----------------------------------------------------------------
    SELECT string_agg(p.pb_name, ', ' ORDER BY p.pb_name) INTO missing
      FROM pb_inv p
     WHERE NOT EXISTS (SELECT 1 FROM public.feed_items i WHERE i.pb_name = p.pb_name);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'No feed_item matches these PB names: %', missing;
    END IF;

    SELECT string_agg(x.pb_name, ', ') INTO dupes FROM (
        SELECT i.pb_name FROM public.feed_items i
         JOIN pb_inv p ON p.pb_name = i.pb_name
         GROUP BY i.pb_name HAVING count(*) > 1) x;
    IF dupes IS NOT NULL THEN
        RAISE EXCEPTION 'More than one feed_item shares these PB names: %', dupes;
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Where each item lives: the bay it is in now, else its usual bay.
    -- -----------------------------------------------------------------
    CREATE TEMP TABLE target AS
    SELECT i.id                  AS item_id,
           i.name                AS item_name,
           p.pb_name,
           GREATEST(p.qty_lb, 0) AS new_qty_lb,
           p.qty_lb              AS pb_raw_qty_lb,
           p.cost_per_ton,
           ROUND(GREATEST(p.qty_lb,0) / 2000.0 * p.cost_per_ton, 2) AS new_cost_usd,
           COALESCE(
               (SELECT r.location_id FROM public.feed_receipts r
                 WHERE r.item_id = i.id ORDER BY r.receipt_date, r.created_at LIMIT 1),
               i.default_location_id
           )                     AS location_id
    FROM pb_inv p
    JOIN public.feed_items i ON i.pb_name = p.pb_name;

    SELECT string_agg(t.item_name, ', ') INTO bad
      FROM target t WHERE t.new_qty_lb > 0 AND t.location_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'These items have stock but no bay to put it in: %', bad;
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Out with the old seed, in with PB's figures.
    -- Safe to DELETE outright only because guard 0 proved nothing
    -- references these layers: no feed_usage means no feed_usage_costs.
    -- -----------------------------------------------------------------
    DELETE FROM public.feed_receipts;

    INSERT INTO public.feed_receipts (
        receipt_date, item_id, location_id, vendor, notes,
        qty_lb, product_cost, cost_pending, qty_lb_remaining, source, created_by
    )
    SELECT
        DATE '2026-08-30',
        t.item_id,
        t.location_id,
        '(opening balance)',
        'Opening balance re-seeded from the Performance Beef inventory screen dated 2026-08-30 at $'
          || t.cost_per_ton::text || '/ton. '
          || CASE WHEN t.pb_raw_qty_lb < 0
                  THEN 'PB carried ' || t.pb_raw_qty_lb::text || ' lb here; a negative balance cannot be a FIFO layer, so this comes in at zero and wants a physical count. '
                  ELSE '' END
          || 'Price is provisional and editable until the first pound is fed.',
        t.new_qty_lb,
        t.new_cost_usd,
        false,
        t.new_qty_lb,
        'purchase',
        NULL
    FROM target t
    WHERE t.new_qty_lb > 0;

    -- -----------------------------------------------------------------
    -- 5. Prove it landed. Any mismatch aborts the whole thing.
    -- -----------------------------------------------------------------
    SELECT string_agg(x.item_name || ' (want ' || x.new_qty_lb || ', got ' || x.got || ')', '; ')
      INTO bad
      FROM (
        SELECT t.item_name, t.new_qty_lb,
               COALESCE((SELECT SUM(r.qty_lb_remaining) FROM public.feed_receipts r
                          WHERE r.item_id = t.item_id), 0) AS got
          FROM target t
      ) x
     WHERE x.got <> x.new_qty_lb;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'Re-seed did not land: %', bad;
    END IF;

    -- No layer may be left anywhere the target did not put one.
    IF EXISTS (SELECT 1 FROM public.feed_receipts r
                WHERE NOT EXISTS (SELECT 1 FROM target t WHERE t.item_id = r.item_id)) THEN
        RAISE EXCEPTION 'A layer survived for an item that is not in the PB sheet.';
    END IF;

    DROP TABLE pb_inv;
    DROP TABLE target;
END
$reseed$;


-- =====================================================================
-- Run this SECOND, on its own, to see what landed. The SQL editor does not
-- show RAISE NOTICE, so the DO block above stays silent when it succeeds -
-- this is how you read the result.
-- Expect: 11 layers, 2,742,834 lb, $157,852.64.
-- =====================================================================
SELECT i.name                                        AS item,
       l.name                                        AS bay,
       to_char(r.qty_lb_remaining, 'FM999,999,999')   AS on_hand_lb,
       to_char(r.product_cost,    'FM999,999,990.00') AS value_usd,
       to_char(r.product_cost / NULLIF(r.qty_lb,0) * 2000, 'FM999,990.00') AS per_ton
  FROM public.feed_receipts r
  JOIN public.feed_items i             ON i.id = r.item_id
  JOIN public.feed_storage_locations l ON l.id = r.location_id
UNION ALL
SELECT 'TOTAL', '', to_char(SUM(qty_lb_remaining), 'FM999,999,999'),
       to_char(SUM(product_cost), 'FM999,999,990.00'), ''
  FROM public.feed_receipts
 ORDER BY 1;
