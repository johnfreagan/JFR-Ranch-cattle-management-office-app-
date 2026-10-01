-- =====================================================================
-- Jake Taylor's shelf, and the Resflor reading confirmed
-- =====================================================================
-- 2026-10-01. John: "we will have three locations as of now but could
-- grow in future. Medicine Room, Cowboys, and Jake Taylor (will have
-- processing meds)." and "jake taylor will have to give his inventory
-- later today of processing meds."
--
-- ONLY JAKE TAYLOR IS ADDED HERE, and that is deliberate.
--
-- A buyer's shelf is exactly what this table was built for: kind
-- 'buyer' with source_key matching lots.source, so a lot's processing
-- draw knows whose account to pull from without a schema change to
-- lots. med_buyer_reconciliation already joins on
-- lower(loc.source_key) = lower(rw.buyer_source). Five lots carry
-- source = 'Jake Taylor', so the key is spelled to match them exactly.
--
-- Medicine Room and Cowboys are NOT added, because this module keeps
-- ONE ranch pool on purpose - custody is tracked on the man, not on the
-- shelf, which is why a checkout carries direction 0 and does not move
-- stock. The room/truck split already exists as the four gathering
-- boxes on every count line, and that is what produced the $2,394.53
-- crew figure in the opening count.
--
-- Inserting a second kind='ranch' row today would break two things
-- quietly:
--   1. invLedgerReady() in index.html resolves the ranch location with
--      .eq('kind','ranch').limit(1).maybeSingle() - an ARBITRARY row.
--      Every doctoring dose would draw from whichever one came back
--      first.
--   2. med_consume() orders layers (location_id = p_location_id) DESC
--      and then falls through to other locations, so a draw against the
--      wrong shelf SUCCEEDS off the right one. No error, wrong books.
-- And nothing would ever move stock INTO Cowboys, so the trucks would
-- fill at the opening count and never drain - every later count reading
-- the whole truck as shrink. That needs a transfer txn type, a
-- med_transfer(), and screens. John's call, taken 2026-10-01: Jake
-- Taylor now, the real split in wave 2 with the invLedgerReady fix
-- landing first. docs/OPEN-ITEMS.md item 0d.
--
-- usage_from is left NULL. That is the go-live switch: until it is set,
-- no treatment accrues against this location at all, which is what
-- makes it safe to create the row before his count exists.
--
-- Also here: the Resflor reading, confirmed by John, so the line note
-- stops carrying a doubt that has been settled. 2 bottles each half
-- full from the first crew PLUS the fourth man's 3/4 of a 500 mL =
-- 1.75 bottles, 875 mL, $726.92. No quantity changes.
-- =====================================================================

begin;

INSERT INTO public.med_stock_locations (name, kind, source_key, notes)
SELECT 'Jake Taylor', 'buyer', 'Jake Taylor',
       'Processing medicine held on Jake Taylor''s place. source_key matches lots.source so med_buyer_reconciliation can tie a lot''s processing draw to his account. usage_from stays NULL until his opening count is posted.'
WHERE NOT EXISTS (
    SELECT 1 FROM public.med_stock_locations
     WHERE kind = 'buyer' AND lower(source_key) = lower('Jake Taylor')
);

DO $resflor$
DECLARE
    v_count uuid;
BEGIN
    SELECT c.id INTO v_count
      FROM public.med_counts c
      JOIN public.med_stock_locations l ON l.id = c.location_id
     WHERE c.count_date = DATE '2026-09-30' AND c.is_opening
       AND l.kind = 'ranch' AND NOT l.is_test;

    IF v_count IS NULL THEN
        RAISE EXCEPTION 'the opening count draft is missing';
    END IF;
    IF (SELECT status FROM public.med_counts WHERE id = v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the opening count is no longer a draft - refusing to edit a posted count';
    END IF;

    UPDATE public.med_count_lines cl
       SET notes = 'Redwing "Resflor 500 ML" 10.00 bottles, $4,153.81. 10 x 500 mL. Redwing also lists "Resflor 250 ML" at zero. | CREW ADDED 2026-10-01: 2 bottles each 1/2 full = 1.0 bottle, plus a fourth man reporting 3/4 of a 500 mL = 1.75 bottles = 875 mL in the trucks. CONFIRMED by John 2026-10-01: two bottles each half full, not one full and one half, and the fourth man''s 3/4 is on top of that. Charged out in September and not yet used.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Resflor';
END
$resflor$;

DO $verify$
DECLARE
    v_count uuid;
    n       integer;
    v       numeric;
    bad     text;
    loc     record;
BEGIN
    -- exactly one buyer location for Jake Taylor, keyed to his lots
    SELECT count(*) INTO n FROM public.med_stock_locations
     WHERE kind = 'buyer' AND lower(source_key) = lower('Jake Taylor');
    IF n <> 1 THEN RAISE EXCEPTION 'expected 1 Jake Taylor buyer location, found %', n; END IF;

    SELECT * INTO loc FROM public.med_stock_locations
     WHERE kind = 'buyer' AND lower(source_key) = lower('Jake Taylor');
    IF loc.usage_from IS NOT NULL THEN
        RAISE EXCEPTION 'Jake Taylor is live already (usage_from %) - it must stay NULL until his count posts', loc.usage_from;
    END IF;
    IF NOT loc.is_active OR loc.is_test THEN
        RAISE EXCEPTION 'Jake Taylor location is inactive or flagged test';
    END IF;

    -- the source_key has to match a real lots.source or the buyer
    -- reconciliation silently returns nothing
    SELECT count(*) INTO n FROM public.lots WHERE source = loc.source_key;
    IF n = 0 THEN
        RAISE EXCEPTION 'no lot carries source = %, so the buyer reconciliation would never match', loc.source_key;
    END IF;

    -- STILL exactly one ranch location. This is the assertion that would
    -- have caught a second one being added before invLedgerReady is fixed.
    SELECT count(*) INTO n FROM public.med_stock_locations
     WHERE kind = 'ranch' AND NOT is_test;
    IF n <> 1 THEN
        RAISE EXCEPTION 'expected exactly 1 ranch location, found % - invLedgerReady() picks an arbitrary one', n;
    END IF;

    -- and the opening count is untouched
    SELECT c.id INTO v_count FROM public.med_counts c
      JOIN public.med_stock_locations l ON l.id = c.location_id
     WHERE c.count_date = DATE '2026-09-30' AND c.is_opening
       AND l.kind = 'ranch' AND NOT l.is_test;

    SELECT count(*) INTO n FROM public.med_count_lines WHERE count_id = v_count;
    IF n <> 21 THEN RAISE EXCEPTION 'expected 21 count lines, found %', n; END IF;

    SELECT string_agg(m.name, '; ') INTO bad
      FROM public.med_count_lines cl
      JOIN public.medications m ON m.id = cl.medication_id
     WHERE cl.count_id = v_count AND cl.counted_units > 0
       AND cl.bottle_size * (coalesce(cl.barn_full,0) + coalesce(cl.barn_open,0)
                           + coalesce(cl.crew_full,0) + coalesce(cl.crew_open,0))
           <> cl.counted_units;
    IF bad IS NOT NULL THEN RAISE EXCEPTION 'count boxes do not reconcile - %', bad; END IF;

    SELECT round(SUM(counted_units * unit_cost), 2) INTO v
      FROM public.med_count_lines WHERE count_id = v_count AND unit_cost IS NOT NULL;
    IF v <> 20056.61 THEN RAISE EXCEPTION 'count comes to %, expected 20056.61', v; END IF;

    SELECT count(*) INTO n FROM public.med_counts;
    IF n <> 1 THEN RAISE EXCEPTION 'expected 1 count, found % - Jake Taylor has none yet', n; END IF;

    SELECT count(*) INTO n FROM public.med_purchase_lines;
    IF n <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% layers)', n; END IF;
    SELECT count(*) INTO n FROM public.med_txns;
    IF n <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% txns)', n; END IF;

    RAISE NOTICE 'VERIFIED: Jake Taylor buyer location created, not live, 1 ranch location, count unchanged at $20,056.61.';
END
$verify$;

commit;
