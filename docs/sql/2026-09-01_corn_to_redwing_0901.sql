-- =====================================================================
-- Corn (Feed): move to Redwing at 9/1/26
-- =====================================================================
-- The earlier alignment used Redwing's 8/31 sheet, which showed corn at
-- 854,832.50 lb. Redwing has since moved to 866,380.00 - which is where
-- the app already was before that alignment - so the 8/31 figure was
-- superseded and corn was moved AWAY from Redwing rather than toward it.
-- This puts it back.
--
-- The DOLLARS were right at 8/31 and are right now: $74,298.38 against
-- Redwing's $74,298.39, a cent apart. So this is a quantity correction
-- carrying Redwing's value, and the rate falls from $173.83 to about
-- $171.51/ton as the same money spreads over more pounds.
--
-- Same construction as before: what has already been FED stays fed at the
-- cost it froze at. Only what is standing moves.
--
-- Apply in the Supabase SQL editor.
-- =====================================================================

DO $corn$
DECLARE
    RW_LB  CONSTANT numeric := 866380.00;
    RW_USD CONSTANT numeric := 74298.39;
    v_id     uuid;
    v_fed    numeric;
    v_src    text;
    v_newqty numeric;
    v_newusd numeric;
    n        integer;
    v_lb     numeric;
    v_usd    numeric;
BEGIN
    SELECT count(*) INTO n
      FROM public.feed_receipts r JOIN public.feed_items i ON i.id = r.item_id
     WHERE i.name = 'Corn (Feed)';
    IF n <> 1 THEN
        RAISE EXCEPTION
          'STOP: Corn (Feed) has % layer(s), not 1. With more than one, which layer gives up the pounds is a decision, not arithmetic.', n;
    END IF;

    SELECT r.id, r.qty_lb - r.qty_lb_remaining, r.source
      INTO v_id, v_fed, v_src
      FROM public.feed_receipts r JOIN public.feed_items i ON i.id = r.item_id
     WHERE i.name = 'Corn (Feed)';

    IF v_src <> 'opening_balance' THEN
        RAISE EXCEPTION 'STOP: the corn layer is a %, not an opening balance.', v_src;
    END IF;

    v_newqty := RW_LB + v_fed;
    -- Priced so the pounds STILL STANDING carry Redwing's value.
    v_newusd := ROUND(v_newqty * RW_USD / RW_LB, 2);

    UPDATE public.feed_receipts
       SET qty_lb           = v_newqty,
           qty_lb_remaining = RW_LB,
           product_cost     = v_newusd,
           notes = COALESCE(notes || ' ', '')
                 || 'Re-aligned to Redwing RM Inventory 2026-09-01 on ' || public.ranch_today()::text
                 || ': on hand ' || RW_LB::text || ' lb valued at $' || RW_USD::text
                 || '. The earlier 8/31 alignment used a figure Redwing has since superseded. '
                 || v_fed::text || ' lb already fed keeps its frozen cost.',
           updated_at = now()
     WHERE id = v_id;

    SELECT r.qty_lb_remaining, r.qty_lb_remaining * r.unit_cost_per_lb
      INTO v_lb, v_usd
      FROM public.feed_receipts r WHERE r.id = v_id;

    IF abs(v_lb - RW_LB) > 0.005 OR abs(v_usd - RW_USD) > 0.02 THEN
        RAISE EXCEPTION 'Did not land: % lb / $% (want % / $%).',
            round(v_lb,2), round(v_usd,2), RW_LB, RW_USD;
    END IF;

    IF (SELECT COALESCE(SUM(qty_lb),0) FROM public.feed_receipts)
     - (SELECT COALESCE(SUM(qty_lb),0) FROM public.feed_usage)
    <> (SELECT COALESCE(SUM(qty_lb_remaining),0) FROM public.feed_receipts) THEN
        RAISE EXCEPTION 'The flow identity broke: receipts - usage no longer equals remaining.';
    END IF;

    RAISE NOTICE 'Corn (Feed) -> % lb on hand, $% (kept % lb fed).', RW_LB, v_usd, v_fed;
END
$corn$;

SELECT i.name AS item,
       to_char(r.qty_lb_remaining, 'FM999,999,999.99')                  AS on_hand_lb,
       to_char(r.qty_lb_remaining * r.unit_cost_per_lb, 'FM999,990.00') AS on_hand_usd,
       to_char(r.unit_cost_per_lb * 2000, 'FM999,990.00')               AS per_ton
  FROM public.feed_receipts r JOIN public.feed_items i ON i.id = r.item_id
 WHERE i.name = 'Corn (Feed)';
