-- =====================================================================
-- GO LIVE. Both counts posted, usage_from set, today's doses drawn.
-- =====================================================================
-- 2026-10-01, evening ranch time. John: "Go live on all medicines
-- inventories as of this morning so today's doctoring and processing
-- goes against it."
--
-- This file is the record of an irreversible step, not something to run
-- again: med_post_count() creates the opening layers and locks the
-- period, and running it twice is refused. The verify block at the
-- bottom is the part worth keeping - it asserts the state go-live left
-- behind, and it can be run any time.
--
-- WHAT WAS DONE, in order, because the order matters
--   1. Jake Taylor's count entered from his pad - 9 lines, $2,668.56,
--      dated 2026-09-30.
--   2. med_post_count() on Ranch   - 21 lines, 10 stocked, $20,081.64.
--   3. med_post_count() on Jake Taylor - 9 lines, $2,668.56.
--   4. usage_from = 2026-10-01 on both locations.
--   5. Today's doctoring drawn by hand - 7 lines, $91.12.
--
-- JAKE'S COUNT IS DATED 9/30, NOT THE 10-1 ON HIS PAD. The period lock
-- refuses any transaction dated ON OR BEFORE the last posted count
-- (med_guard_locked_period: v_date <= v_locked). A count dated 10/1
-- would therefore block every 10/1 draw at his place, which is the
-- opposite of going live this morning. Dating it 9/30 makes 10/1 the
-- first live day at both locations.
--
-- "THIS MORNING" IS 2026-10-01. ranch_today() read 2026-10-01 at
-- go-live; the database runs UTC and was already into the 2nd. The
-- ranch's day is the one that counts - CLAUDE.md, and the reason
-- ranch_today() exists.
--
-- WHY TODAY'S DOSES HAD TO BE DRAWN BY HAND. usage_from gates a
-- treatment AT THE MOMENT IT IS SAVED, in invRecordDoctoringUsage. It
-- does not reach back. Today's doctoring was typed at 09:46 ranch time,
-- hours before the ledger went live, so the hook never fired for it.
-- Left alone, those doses were off the shelf with the ledger none the
-- wiser, and the next count would have booked them as shrink that never
-- happened - the exact failure the approvals gate exists to prevent,
-- arriving through a third door.
--
-- 9/30's four events were deliberately NOT drawn. The count IS the shelf
-- at 9/30 close, so those doses are already out of the counted figure.
-- Drawing them would take them twice.
--
-- WHAT WENT LIVE AND WHAT DID NOT
--   LIVE: doctoring. invRecordDoctoringUsage is wired at three call
--         sites and draws on save.
--   NOT LIVE: processing. Nothing in the app consumes medicine
--         inventory at processing - there is exactly one med_consume()
--         caller in index.html and it is the doctoring hook. Jake
--         Taylor's whole shelf is processing product, so his $2,668.56
--         will sit unchanged until that is built. See OPEN-ITEMS 0g.
--
-- WHERE IT LANDED
--   opening layers      $22,750.19   (Ranch 20,081.64 + Jake 2,668.56)
--   drawn 10/1              $91.12   (Enroflox 78 cc, Excede 18, Resflor 29)
--   on hand               $22,659.07
-- =====================================================================

DO $verify$
DECLARE v numeric; n integer;
BEGIN
    SELECT round(sum(qty_units*unit_cost),2) INTO v FROM public.med_purchase_lines;
    IF v <> 22750.19 THEN RAISE EXCEPTION 'opening layers total %, expected 22750.19', v; END IF;

    SELECT round(sum(qty_remaining*unit_cost),2) INTO v FROM public.med_purchase_lines;
    IF v <> 22659.07 THEN RAISE EXCEPTION 'on hand is %, expected 22659.07', v; END IF;

    -- What the layers gave up must equal what the transactions say they
    -- took. A cent of tolerance: total_cost is stored rounded and the
    -- layer arithmetic is not, which is worth 0.0002 across seven draws.
    SELECT abs(sum(qty_units*unit_cost) - sum(qty_remaining*unit_cost)
             - (SELECT sum(total_cost) FROM public.med_txns WHERE txn_type='usage'))
      INTO v FROM public.med_purchase_lines;
    IF v > 0.01 THEN RAISE EXCEPTION 'layers and transactions disagree by %', v; END IF;

    -- Every draw froze its allocation, which is what makes a reversal exact.
    SELECT count(*) INTO n FROM public.med_txns t
     WHERE t.txn_type='usage'
       AND NOT EXISTS (SELECT 1 FROM public.med_txn_layers tl WHERE tl.txn_id=t.id);
    IF n <> 0 THEN RAISE EXCEPTION '% usage txns have no layer allocation', n; END IF;

    -- Nothing drew against stock the ledger did not have.
    SELECT count(*) INTO n FROM public.med_txn_layers WHERE purchase_line_id IS NULL;
    IF n <> 0 THEN RAISE EXCEPTION '% uncovered allocations', n; END IF;

    SELECT count(*) INTO n FROM public.med_purchase_lines WHERE qty_remaining < 0;
    IF n <> 0 THEN RAISE EXCEPTION '% layers are negative', n; END IF;

    SELECT count(*) INTO n FROM public.med_counts WHERE status <> 'posted';
    IF n <> 0 THEN RAISE EXCEPTION '% counts are still a draft', n; END IF;

    SELECT count(*) INTO n FROM public.med_stock_locations
     WHERE is_active AND NOT is_test AND usage_from IS NULL;
    IF n <> 0 THEN RAISE EXCEPTION '% live locations have no usage_from', n; END IF;

    -- Nothing may be drawn on or before the count date: that is the
    -- period lock, and it is also what stops 9/30's doses being taken twice.
    SELECT count(*) INTO n FROM public.med_txns
     WHERE txn_type='usage' AND txn_date < DATE '2026-10-01';
    IF n <> 0 THEN RAISE EXCEPTION '% usage txns are dated before go-live', n; END IF;

    RAISE NOTICE 'VERIFIED: $22,750.19 opening, $91.12 drawn, $22,659.07 on hand, both counts posted and both locations live from 2026-10-01.';
END
$verify$;
