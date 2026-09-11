-- =====================================================================
-- 2026-09-11  Sale pay weight: backfill net_weight_lb from gross
-- =====================================================================
-- John, 2026-09-11: "47-26 has a sale with weights entered but office app
-- and Claude review says no sales weight entered?  Where is missing link"
--
-- THE MISSING LINK
-- ----------------
-- `sales` carries two weights. `gross_weight_lb` is what came off the
-- scale; `net_weight_lb` is the PAY WEIGHT, and the pay weight is the
-- only one anything downstream reads:
--
--   lot_realized_adg_internal()   WHERE s.net_weight_lb > 0   -- no fallback
--     -> lot_realized_adg         -> the lot tile's ADG Actual
--                                 -> the closeout's ADG REALIZED
--                                 -> the per_lb cost-of-gain true-up
--
-- The lot's Sales table, by contrast, falls back (`net || gross`) and
-- prints "151,805 gross". So a sale entered with a gross and no net LOOKS
-- complete on the screen a person reads and is invisible to every number
-- built on the scale ticket. 47-26 is the lot where it reads as total
-- absence because its ONE sale is such a row: head_sold_with_weight = 0,
-- realized_adg = NULL.
--
-- Nine live rows carry no pay weight, all hand-entered through the lot's
-- "+ Sale" form in June and August. Everything entered through a shipment
-- sheet has one, because that path derives pay weight from gross and
-- shrink itself and writes it.
--
-- WHAT THIS FIXES, AND THE GUARD THAT DECIDES
-- -------------------------------------------
-- Eight of the nine have a weight; it is in the gross box. For every one
-- of them the MONEY TIES ON THAT WEIGHT to the cent:
--
--   round(total_price / gross_weight_lb * 100, 2) = price_per_cwt
--
-- A buyer settles on the pay weight, never on the scale gross, so a
-- weight the cheque was computed against IS the pay weight -- it was
-- simply typed into the wrong box. That tie is the guard, and it is the
-- whole argument: this migration copies gross to net ONLY where the money
-- proves the figure is a pay weight, never on a bare gross.
--
--   lot     date        hd    weight      $/cwt    avg wt
--   31-26   2026-06-04  18     8,159.94   403.01     453
--   31-26   2026-06-04  12     3,740      244.39     312
--   31-26   2026-06-11   8    11,889.50    96.04   1,486
--   31-26   2026-08-11  10     8,528      327.86     853
--   37X     2026-08-11  37    31,555      327.85     853
--   37X-1   2026-08-11  44    37,525      327.84     853
--   37X-1   2026-08-11 143   121,956      327.84     853
--   47-26   2026-08-11 178   151,805      327.85     853
--
-- The ninth (37X-1, 2026-06-04, 2 hd) has NO weight at all -- only
-- $1,826.96/head -- so there is nothing to move and it is left alone.
-- It will show on the Anomalies report until someone types the weight.
--
-- WHAT IS DELIBERATELY NOT DONE
-- -----------------------------
-- `lot_realized_adg_internal()` is NOT given a fallback to gross. Gross
-- is heavier than pay weight by the shrink, so a silent fallback would
-- book 2-3 percent of shrink as gain on every lot that ever entered a
-- real scale gross -- quietly, forever, and in the flattering direction.
-- Pay weight is the number, and the fix is to record it.
--
-- No money moves. `net_weight_lb` feeds realized ADG and display only;
-- `total_price` is untouched, so revenue, closeout dollars and every
-- fiscal year stand exactly where they stood.
--
-- Idempotent: the WHERE clauses exclude any row that already has a pay
-- weight, so a re-run changes nothing and the verify block still passes.
-- =====================================================================

begin;

DO $mig$
DECLARE
    tie_rows      INTEGER;
    sales_fixed   INTEGER;
    sources_fixed INTEGER;
    leftover      INTEGER;
    bad_lot       TEXT;
BEGIN
    -- ---- pre-check -------------------------------------------------
    -- Nothing to do is fine (a re-run). Something UNEXPECTED is not:
    -- this file was written against eight rows and must not silently
    -- rewrite a ninth that appeared since.
    SELECT count(*) INTO tie_rows
    FROM sales s
    WHERE s.net_weight_lb IS NULL
      AND s.gross_weight_lb IS NOT NULL
      AND s.gross_weight_lb > 0
      AND s.total_price IS NOT NULL
      AND s.price_per_cwt IS NOT NULL
      AND abs(round(s.total_price / s.gross_weight_lb * 100, 2) - s.price_per_cwt) <= 0.01;

    IF tie_rows > 8 THEN
        RAISE EXCEPTION
            'Expected at most 8 sales rows to backfill, found %. A newer row is in scope; review before running.',
            tie_rows;
    END IF;

    RAISE NOTICE 'Sales rows with a pay weight to recover: %', tie_rows;

    -- ---- 1. the pay weight ------------------------------------------
    WITH fixed AS (
        UPDATE sales s
           SET net_weight_lb = s.gross_weight_lb,
               notes = COALESCE(NULLIF(btrim(s.notes), '') || ' | ', '')
                     || '[2026-09-11] Pay weight recovered from the gross box: '
                     || 'total_price / weight x 100 ties to price_per_cwt, so the figure entered '
                     || 'is the buyer pay weight. net_weight_lb was NULL, which made this sale '
                     || 'invisible to realized ADG and cost of gain.'
         WHERE s.net_weight_lb IS NULL
           AND s.gross_weight_lb IS NOT NULL
           AND s.gross_weight_lb > 0
           AND s.total_price IS NOT NULL
           AND s.price_per_cwt IS NOT NULL
           AND abs(round(s.total_price / s.gross_weight_lb * 100, 2) - s.price_per_cwt) <= 0.01
        RETURNING s.id
    )
    SELECT count(*) INTO sales_fixed FROM fixed;

    -- ---- 2. the source row ------------------------------------------
    -- `sale_sources.pay_weight_lb` is NULL on the same rows. Only the
    -- shipment screens read it today and none of these sales belongs to
    -- a shipment, but a row that carries head and dollars and no weight
    -- is a hole waiting for the next reader. Filled ONLY where the sale
    -- has exactly one source row whose head equals the sale's -- then
    -- the pay weight is the sale's, with no allocation to get wrong.
    WITH single_src AS (
        SELECT ss.id, s.net_weight_lb
          FROM sale_sources ss
          JOIN sales s ON s.id = ss.sale_id
         WHERE ss.pay_weight_lb IS NULL
           AND s.net_weight_lb IS NOT NULL
           AND ss.head_count = s.head_count
           AND (SELECT count(*) FROM sale_sources x WHERE x.sale_id = s.id) = 1
    ), fixed AS (
        UPDATE sale_sources ss
           SET pay_weight_lb = sp.net_weight_lb
          FROM single_src sp
         WHERE ss.id = sp.id
        RETURNING ss.id
    )
    SELECT count(*) INTO sources_fixed FROM fixed;

    RAISE NOTICE 'sales rows updated: %   sale_sources rows updated: %',
        sales_fixed, sources_fixed;

    -- ---- verify ------------------------------------------------------
    SELECT count(*) INTO leftover
    FROM sales s
    WHERE s.net_weight_lb IS NULL
      AND s.gross_weight_lb IS NOT NULL
      AND s.gross_weight_lb > 0
      AND s.total_price IS NOT NULL
      AND s.price_per_cwt IS NOT NULL
      AND abs(round(s.total_price / s.gross_weight_lb * 100, 2) - s.price_per_cwt) <= 0.01;

    IF leftover <> 0 THEN
        RAISE EXCEPTION 'Backfill incomplete: % rows still carry a pay weight only in the gross box.', leftover;
    END IF;

    -- A pay weight that does not reach lot_realized_adg has not been
    -- fixed, it has only been written down. Assert the thing this
    -- migration exists for: every lot that sold head with a weight now
    -- reports those head as weighed out.
    SELECT l.lot_number INTO bad_lot
      FROM lots l
      JOIN lot_realized_adg ra ON ra.lot_id = l.id
     WHERE EXISTS (
             SELECT 1 FROM sales s
              WHERE s.lot_id = l.id
                AND s.head_count > 0
                AND s.net_weight_lb > 0)
       AND COALESCE(ra.head_sold_with_weight, 0) = 0
     LIMIT 1;

    IF bad_lot IS NOT NULL THEN
        RAISE EXCEPTION
            'Lot % has sales with a pay weight but lot_realized_adg still reports no weighed-out head.',
            bad_lot;
    END IF;

    -- 47-26 is the lot that prompted this. Name it explicitly: a generic
    -- assertion that passes because the lot dropped out of the query is
    -- not the check anyone wanted.
    SELECT ra.lot_number INTO bad_lot
      FROM lot_realized_adg ra
     WHERE ra.lot_number = '47-26'
       AND (ra.realized_adg IS NULL OR COALESCE(ra.head_sold_with_weight, 0) <> 178);

    IF bad_lot IS NOT NULL THEN
        RAISE EXCEPTION '47-26 should now report 178 head weighed out with a realized ADG; it does not.';
    END IF;

    RAISE NOTICE 'Verified: every sale with a recoverable pay weight now carries one, and 47-26 reports realized ADG.';
END
$mig$;

commit;
