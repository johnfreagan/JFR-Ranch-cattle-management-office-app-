-- =====================================================================
-- An office estimate doses the per-hundredweight meds until the first
-- invoice. Real weight always wins.
-- =====================================================================
-- 2026-10-02. John: "What if we bill meds off estimated weight entered
-- by office till first invoice, then off lot avg weight after that. I
-- know within 5 pounds what they weigh when the cattle are purchased."
--
-- Better than what was there. THREE RUNGS, and the order is the whole
-- design:
--
--   1. the receipt's OWN invoice weight          best
--   2. the lot average across its invoices       once any invoice exists
--   3. the office estimate                       only while the lot has
--                                                NO invoice anywhere
--
-- Rung 3 never competes with real data. The moment one invoice lands for
-- the lot, rung 2 takes over and the estimate is ignored for good.
--
-- WHY IT MATTERED. Lot 32-26 had no invoice at all, so Valcor, Macrosyn
-- and Synanthic - all dosed per hundredweight - contributed NOTHING to
-- either costing. 6 of 22 med lines on that lot were empty. It read
-- $512.01 for 42 head when three of its eleven drugs were missing.
--
-- BLAST RADIUS, CHECKED BEFORE TOUCHING THE COSTING VIEW. Exactly ONE
-- lot has a receipt with no weight: 32-26. Every other lot already has
-- an invoice, so rung 3 can never fire for them. That is what let this
-- change the shared lot_processing_cost_detail at all - the plan's item
-- 16 calls an unchanged processing total non-negotiable, and a snapshot
-- of all 10 lots before and after came back identical at $99,264.14
-- because no estimate has been entered yet. The snapshot table is left
-- in place as public._proc_cost_snapshot_20261002 so the same check can
-- be repeated the day a weight IS entered.
--
-- THE LOCK RULE, John's refinement: "correct if month is still open,
-- lock if week straddles month end." A late invoice reverses and
-- re-draws while the period is open. Once a count has closed the
-- period, the draw stands as it was and the functions report
-- lines_locked rather than throwing - one late invoice must not fail a
-- whole invoice save, and the difference is said out loud rather than
-- skipped quietly.
--
-- WHAT THIS DOES NOT DO. It does not flip processing COST to FIFO. The
-- closeout still reads lot_processing_cost_detail. The estimate feeds
-- both that and the inventory draw from the same expression, so the two
-- cannot disagree about the dose - which is the only thing that could
-- have gone wrong here.
-- =====================================================================

ALTER TABLE public.lots ADD COLUMN IF NOT EXISTS est_purchase_weight_lb numeric(8,2);
ALTER TABLE public.lots ADD COLUMN IF NOT EXISTS est_weight_source text;

ALTER TABLE public.lots DROP CONSTRAINT IF EXISTS lots_est_weight_ck;
ALTER TABLE public.lots ADD CONSTRAINT lots_est_weight_ck
  CHECK (est_purchase_weight_lb IS NULL OR est_purchase_weight_lb > 0);

COMMENT ON COLUMN public.lots.est_purchase_weight_lb IS
 'Office estimate of average purchase weight a head, used to dose per-hundredweight processing meds ONLY while the lot has no invoice weight at all. Real weight always wins: this is the third rung, below the receipt''s own invoice and the lot average.';
COMMENT ON COLUMN public.lots.est_weight_source IS
 'Free text: who gave the estimate and when, so a dose computed off it can be explained later.';

-- med_processing_src gains rung 3 and a flag saying when it was used.
-- weight_is_estimated is appended LAST: CREATE OR REPLACE cannot insert
-- a column mid-list, it reads that as renaming the one that was there.

-- lot_processing_cost_detail gains the same rung, inside lot_avg_wt, so
-- the implied cost and the inventory draw dose identically.

-- (Both view bodies are applied live; see the deployed definitions.)

DO $verify$
DECLARE n integer; v numeric;
BEGIN
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='lots' AND column_name='est_purchase_weight_lb';
    IF n <> 1 THEN RAISE EXCEPTION 'lots.est_purchase_weight_lb is missing'; END IF;

    -- rung 3 must never outrank real weight
    SELECT count(*) INTO n FROM public.med_processing_src s
      JOIN public.lots l ON l.id = s.lot_id
     WHERE s.weight_is_estimated AND EXISTS (
            SELECT 1 FROM public.invoices i
             WHERE i.lot_id = s.lot_id AND i.head_count > 0 AND i.total_weight_lb > 0);
    IF n <> 0 THEN
        RAISE EXCEPTION '% receipts used the estimate although the lot has a real invoice weight', n;
    END IF;

    -- only lots with no invoice at all can ever reach rung 3
    SELECT count(DISTINCT lot_id) INTO n FROM public.med_processing_src WHERE est_wt IS NULL;
    IF n > 1 THEN
        RAISE EXCEPTION '% lots still have no weight of any kind - check before trusting the blast radius', n;
    END IF;

    RAISE NOTICE 'VERIFIED: the estimate is the third rung and never outranks an invoice.';
END
$verify$;
