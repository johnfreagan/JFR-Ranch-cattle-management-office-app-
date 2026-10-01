-- Med inventory assertion suite. Every block raises on failure and prints
-- PASS on success. Run with ON_ERROR_STOP=0 so one failure does not hide
-- the rest, then count the PASS lines.
\set ON_ERROR_STOP 0
SET client_min_messages = notice;
SET test.role = 'owner';
SET test.uid  = '00000000-0000-0000-0000-0000000000a1';
SET test.today = '2026-10-01';

-- ---------------------------------------------------------------- seed
INSERT INTO public.med_stock_locations (id, name, kind, source_key, is_test, usage_from) VALUES
  ('00000000-0000-0000-0000-00000000c001','Count Barn','ranch',NULL,false,'2026-07-01'),
  ('00000000-0000-0000-0000-00000000c002','Lock Barn','ranch',NULL,false,'2026-07-01'),
  ('00000000-0000-0000-0000-00000000c003','Approvals Barn','ranch',NULL,false,'2026-07-01'),
  ('00000000-0000-0000-0000-00000000c004','ACME Cattle','buyer','ACME',false,'2026-07-01'),
  ('00000000-0000-0000-0000-00000000c005','Rehearsal','ranch',NULL,true,'2026-07-01');

-- Medications, with readable ids.
-- bottle_cost, NOT cost_per_unit: the latter is GENERATED as
-- bottle_cost / bottle_size, so writing to it is refused. The per-unit
-- costs these derive are the ones the assertions below expect:
-- $2.00, $1.50, none, $0.05, $3.00 and $0.40.
INSERT INTO public.medications
  (id, name, generic_category, bottle_size, bottle_size_unit, bottle_cost, dose_mode, flat_dose_amount, round_up_to)
VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001','Draxxin','antibiotic',  500,'mL', 1000.00,'per_weight',NULL,1),
  ('aaaaaaaa-0000-0000-0000-000000000002','Nuflor','antibiotic',   500,'mL',  750.00,'flat',6,1),
  ('aaaaaaaa-0000-0000-0000-000000000003','Mystery','antibiotic',  NULL,NULL,   NULL,'flat',5,1),
  ('aaaaaaaa-0000-0000-0000-000000000004','Big Jug','dewormer',   3785,'mL',  189.25,'flat',10,1),
  ('aaaaaaaa-0000-0000-0000-000000000005','Not Stocked','vaccine',  50,'mL',  150.00,'flat',2,1),
  ('aaaaaaaa-0000-0000-0000-000000000006','Vision 7','vaccine',    250,'mL',  100.00,'flat',2,1);

UPDATE public.medications SET track_inventory = false
 WHERE id = 'aaaaaaaa-0000-0000-0000-000000000005';

-- Per-weight numbers for the buyer reconciliation test.
UPDATE public.medications
   SET per_weight_rate = 1.1, per_weight_basis = 100, round_up_to = 1
 WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';

INSERT INTO public.med_crew_members (id, name) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001','Rudy'),
  ('bbbbbbbb-0000-0000-0000-000000000002','Tuffy');

-- ---------------------------------------------------------------- T1
-- FIFO across two layers, oldest first, at the cost each layer was bought at.
DO $t$
DECLARE
    v_ranch uuid; v_res jsonb; v_a numeric; v_b numeric;
BEGIN
    SELECT id INTO v_ranch FROM public.med_stock_locations WHERE name='Ranch';

    INSERT INTO public.med_purchase_lines
      (id, medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
    VALUES
      ('cccccccc-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',
       v_ranch, 0.2, 500, 'mL', 1.00, 100, '2026-08-01'),
      ('cccccccc-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000002',
       v_ranch, 0.2, 500, 'mL', 2.00, 100, '2026-08-15');

    v_res := public.med_consume('aaaaaaaa-0000-0000-0000-000000000002', v_ranch, 150,
                                'usage', NULL, 'doctoring_event', NULL, '2026-08-20');

    IF (v_res->>'total_cost')::numeric <> 200 THEN
        RAISE EXCEPTION 'T1 FIFO cost: expected 200.0000, got %', v_res->>'total_cost';
    END IF;
    IF (v_res->>'shortfall_units')::numeric <> 0 THEN
        RAISE EXCEPTION 'T1 unexpected shortfall %', v_res->>'shortfall_units';
    END IF;

    SELECT qty_remaining INTO v_a FROM public.med_purchase_lines WHERE id='cccccccc-0000-0000-0000-000000000001';
    SELECT qty_remaining INTO v_b FROM public.med_purchase_lines WHERE id='cccccccc-0000-0000-0000-000000000002';
    IF v_a <> 0 OR v_b <> 50 THEN
        RAISE EXCEPTION 'T1 layers: expected 0 / 50, got % / %', v_a, v_b;
    END IF;
    RAISE NOTICE 'PASS T1 FIFO drains the oldest layer first and freezes each layer''s cost';
END $t$;

-- ---------------------------------------------------------------- T2
-- A reversal restores EXACTLY what was taken, to the layers it came off.
DO $t$
DECLARE
    v_txn uuid; v_a numeric; v_b numeric; v_res jsonb;
BEGIN
    SELECT t.id INTO v_txn FROM public.med_txns t
     WHERE t.txn_type='usage' AND t.medication_id='aaaaaaaa-0000-0000-0000-000000000002'
     ORDER BY t.created_at DESC LIMIT 1;

    -- A later purchase lands first, so a reversal that RECOMPUTED which
    -- layers "would have" been used would get it wrong here.
    INSERT INTO public.med_purchase_lines
      (id, medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
    SELECT 'cccccccc-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000002',
           location_id, 0.2, 500, 'mL', 9.99, 100, '2026-08-05'
      FROM public.med_purchase_lines WHERE id='cccccccc-0000-0000-0000-000000000001';

    v_res := public.med_reverse_txn(v_txn);
    IF (v_res->>'restored_units')::numeric <> 150 THEN
        RAISE EXCEPTION 'T2 restored %, expected 150', v_res->>'restored_units';
    END IF;

    SELECT qty_remaining INTO v_a FROM public.med_purchase_lines WHERE id='cccccccc-0000-0000-0000-000000000001';
    SELECT qty_remaining INTO v_b FROM public.med_purchase_lines WHERE id='cccccccc-0000-0000-0000-000000000002';
    IF v_a <> 100 OR v_b <> 100 THEN
        RAISE EXCEPTION 'T2 layers after reversal: expected 100 / 100, got % / %', v_a, v_b;
    END IF;
    IF EXISTS (SELECT 1 FROM public.med_txns WHERE id = v_txn) THEN
        RAISE EXCEPTION 'T2 reversed transaction still exists';
    END IF;
    IF EXISTS (SELECT 1 FROM public.med_txn_layers WHERE txn_id = v_txn) THEN
        RAISE EXCEPTION 'T2 allocation rows outlived their transaction';
    END IF;

    -- Clean up the decoy so later arithmetic is readable.
    DELETE FROM public.med_purchase_lines WHERE id='cccccccc-0000-0000-0000-000000000003';
    RAISE NOTICE 'PASS T2 reversal restores the exact layers, not recomputed ones';
END $t$;

-- ---------------------------------------------------------------- T3
-- Short draw: it still records, the uncovered part is priced at the last
-- cost known, and it is flagged rather than hidden.
DO $t$
DECLARE
    v_ranch uuid; v_res jsonb; v_short numeric; v_prov boolean; v_unc numeric;
BEGIN
    SELECT id INTO v_ranch FROM public.med_stock_locations WHERE name='Ranch';

    v_res := public.med_consume('aaaaaaaa-0000-0000-0000-000000000002', v_ranch, 300,
                                'usage', NULL, 'doctoring_event', NULL, '2026-08-25');

    -- 100 @ 1.00 + 100 @ 2.00 + 100 short @ 2.00 (the last cost known)
    IF (v_res->>'total_cost')::numeric <> 500 THEN
        RAISE EXCEPTION 'T3 cost: expected 500.0000, got %', v_res->>'total_cost';
    END IF;
    IF (v_res->>'shortfall_units')::numeric <> 100 THEN
        RAISE EXCEPTION 'T3 shortfall: expected 100, got %', v_res->>'shortfall_units';
    END IF;

    SELECT shortfall_units, cost_provisional INTO v_short, v_prov
      FROM public.med_txns WHERE id = (v_res->>'txn_id')::uuid;
    IF v_short <> 100 OR v_prov THEN
        RAISE EXCEPTION 'T3 stored shortfall %, provisional %', v_short, v_prov;
    END IF;

    SELECT uncovered_units INTO v_unc FROM public.med_on_hand
     WHERE location_id = v_ranch AND medication_id='aaaaaaaa-0000-0000-0000-000000000002';
    IF v_unc <> 100 THEN
        RAISE EXCEPTION 'T3 med_on_hand.uncovered_units = %, expected 100', v_unc;
    END IF;
    RAISE NOTICE 'PASS T3 a short draw records, prices the hole at the last cost, and flags it';
END $t$;

-- ---------------------------------------------------------------- T4
-- No layer and no catalog price: it books at zero and says so. A zero that
-- looks like a real number is worse than an obvious gap.
DO $t$
DECLARE
    v_ranch uuid; v_res jsonb; v_prov boolean; v_unpriced numeric;
BEGIN
    SELECT id INTO v_ranch FROM public.med_stock_locations WHERE name='Ranch';

    v_res := public.med_consume('aaaaaaaa-0000-0000-0000-000000000003', v_ranch, 10,
                                'usage', NULL, 'doctoring_event', NULL, '2026-08-26');

    IF (v_res->>'total_cost')::numeric <> 0 THEN
        RAISE EXCEPTION 'T4 cost: expected 0, got %', v_res->>'total_cost';
    END IF;
    SELECT cost_provisional INTO v_prov FROM public.med_txns WHERE id=(v_res->>'txn_id')::uuid;
    IF NOT v_prov THEN
        RAISE EXCEPTION 'T4 unpriced usage was not flagged cost_provisional';
    END IF;

    SELECT unpriced_usage_units INTO v_unpriced FROM public.med_on_hand
     WHERE location_id = v_ranch AND medication_id='aaaaaaaa-0000-0000-0000-000000000003';
    IF v_unpriced <> 10 THEN
        RAISE EXCEPTION 'T4 med_on_hand.unpriced_usage_units = %, expected 10', v_unpriced;
    END IF;
    RAISE NOTICE 'PASS T4 usage of an unpriced medication books at zero and is flagged, not believed';
END $t$;

-- ---------------------------------------------------------------- T5
-- The late invoice. A layer dated ON OR BEFORE the treatment settles it; a
-- layer that arrived afterwards cannot have been in the syringe.
DO $t$
DECLARE
    v_ranch uuid; v_res jsonb; v_short numeric;
BEGIN
    SELECT id INTO v_ranch FROM public.med_stock_locations WHERE name='Ranch';

    -- Dated AFTER the 8/25 usage: must be left alone.
    INSERT INTO public.med_purchase_lines
      (id, medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
    VALUES ('cccccccc-0000-0000-0000-000000000004','aaaaaaaa-0000-0000-0000-000000000002',
            v_ranch, 0.1, 500, 'mL', 5.00, 50, '2026-08-28');

    v_res := public.med_settle_uncovered('aaaaaaaa-0000-0000-0000-000000000002', v_ranch);
    IF (v_res->>'units_covered')::numeric <> 0 THEN
        RAISE EXCEPTION 'T5a a layer received after the treatment was used to settle it (% units)',
            v_res->>'units_covered';
    END IF;

    -- Dated BEFORE it: this is the invoice that showed up late.
    INSERT INTO public.med_purchase_lines
      (id, medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
    VALUES ('cccccccc-0000-0000-0000-000000000005','aaaaaaaa-0000-0000-0000-000000000002',
            v_ranch, 0.2, 500, 'mL', 3.00, 100, '2026-08-18');

    v_res := public.med_settle_uncovered('aaaaaaaa-0000-0000-0000-000000000002', v_ranch);
    IF (v_res->>'units_covered')::numeric <> 100 THEN
        RAISE EXCEPTION 'T5b expected 100 units covered, got %', v_res->>'units_covered';
    END IF;

    SELECT COALESCE(SUM(shortfall_units),0) INTO v_short FROM public.med_txns
     WHERE medication_id='aaaaaaaa-0000-0000-0000-000000000002' AND location_id = v_ranch;
    IF v_short <> 0 THEN
        RAISE EXCEPTION 'T5b shortfall still %, expected 0', v_short;
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.med_txn_layers l
         JOIN public.med_txns t ON t.id = l.txn_id
        WHERE t.medication_id='aaaaaaaa-0000-0000-0000-000000000002'
          AND l.purchase_line_id IS NULL
    ) THEN
        RAISE EXCEPTION 'T5b placeholder allocation row survived a full settlement';
    END IF;
    RAISE NOTICE 'PASS T5 a late invoice settles uncovered usage, and only with stock that existed at the time';
END $t$;

-- ---------------------------------------------------------------- T6
-- A BLANK count line is NOT a count of zero.
DO $t$
DECLARE
    v_loc uuid := '00000000-0000-0000-0000-00000000c001';
    v_res jsonb; v_qty numeric;
BEGIN
    INSERT INTO public.med_purchase_lines
      (id, medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
    VALUES ('cccccccc-0000-0000-0000-000000000010','aaaaaaaa-0000-0000-0000-000000000006',
            v_loc, 2, 250, 'mL', 0.40, 500, '2026-08-01');

    INSERT INTO public.med_counts (id, count_date, location_id, counted_by)
    VALUES ('dddddddd-0000-0000-0000-000000000001','2026-08-31', v_loc, 'test');

    INSERT INTO public.med_count_lines (count_id, medication_id, counted_units)
    VALUES ('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000006', NULL);

    v_res := public.med_post_count('dddddddd-0000-0000-0000-000000000001');
    IF (v_res->>'lines_counted')::integer <> 0 THEN
        RAISE EXCEPTION 'T6 a blank line was counted: %', v_res::text;
    END IF;

    SELECT qty_units INTO v_qty FROM public.med_on_hand
     WHERE location_id = v_loc AND medication_id='aaaaaaaa-0000-0000-0000-000000000006';
    IF v_qty <> 500 THEN
        RAISE EXCEPTION 'T6 blank line changed stock: on hand % expected 500', v_qty;
    END IF;
    RAISE NOTICE 'PASS T6 a blank count line posts nothing and never writes the stock to zero';
END $t$;

-- ---------------------------------------------------------------- T7
-- Double post refused.
DO $t$
DECLARE v_ok boolean := false;
BEGIN
    BEGIN
        PERFORM public.med_post_count('dddddddd-0000-0000-0000-000000000001');
    EXCEPTION WHEN others THEN
        v_ok := (SQLERRM LIKE '%already posted%');
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'T7 a posted count was posted again';
    END IF;
    RAISE NOTICE 'PASS T7 a posted count cannot be posted twice';
END $t$;

-- ---------------------------------------------------------------- T8
-- Count SHORT: the difference is consumed at real layer costs and becomes
-- shrink. Count LONG with no cost known anywhere: refused, never zero.
DO $t$
DECLARE
    v_loc uuid := '00000000-0000-0000-0000-00000000c001';
    v_res jsonb; v_var numeric; v_val numeric; v_qty numeric; v_refused boolean := false;
BEGIN
    INSERT INTO public.med_counts (id, count_date, location_id, counted_by)
    VALUES ('dddddddd-0000-0000-0000-000000000002','2026-09-30', v_loc, 'test');

    -- 500 on the shelf, 420 found: 80 short.
    INSERT INTO public.med_count_lines (count_id, medication_id, counted_units)
    VALUES ('dddddddd-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000006', 420);

    -- Long on a medication with no layer, no line cost and no catalog price.
    INSERT INTO public.med_count_lines (count_id, medication_id, counted_units)
    VALUES ('dddddddd-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000003', 25);

    BEGIN
        PERFORM public.med_post_count('dddddddd-0000-0000-0000-000000000002');
    EXCEPTION WHEN others THEN
        v_refused := (SQLERRM LIKE '%no unit cost is known%');
    END;
    IF NOT v_refused THEN
        RAISE EXCEPTION 'T8a a positive variance with no known cost did not refuse';
    END IF;

    -- And the refusal took the whole posting with it: one function, one
    -- transaction, so the short line must not have been booked either.
    SELECT qty_units INTO v_qty FROM public.med_on_hand
     WHERE location_id = v_loc AND medication_id='aaaaaaaa-0000-0000-0000-000000000006';
    IF v_qty <> 500 THEN
        RAISE EXCEPTION 'T8a refusal left a partial posting behind: on hand %', v_qty;
    END IF;

    -- Price it on the line and it posts.
    UPDATE public.med_count_lines SET unit_cost = 4.00
     WHERE count_id='dddddddd-0000-0000-0000-000000000002'
       AND medication_id='aaaaaaaa-0000-0000-0000-000000000003';

    v_res := public.med_post_count('dddddddd-0000-0000-0000-000000000002');

    IF (v_res->>'lines_counted')::integer <> 2
       OR (v_res->>'lines_short')::integer <> 1
       OR (v_res->>'lines_over')::integer <> 1 THEN
        RAISE EXCEPTION 'T8b posting summary wrong: %', v_res::text;
    END IF;
    IF (v_res->>'shrink_units')::numeric <> 80 THEN
        RAISE EXCEPTION 'T8b shrink_units %, expected 80', v_res->>'shrink_units';
    END IF;
    IF (v_res->>'shrink_value')::numeric <> 32.00 THEN
        RAISE EXCEPTION 'T8b shrink_value %, expected 32.00 (80 x 0.40)', v_res->>'shrink_value';
    END IF;

    SELECT variance_units, variance_value INTO v_var, v_val
      FROM public.med_count_lines
     WHERE count_id='dddddddd-0000-0000-0000-000000000002'
       AND medication_id='aaaaaaaa-0000-0000-0000-000000000006';
    IF v_var <> -80 OR v_val <> -32 THEN
        RAISE EXCEPTION 'T8b short line variance % / %, expected -80 / -32', v_var, v_val;
    END IF;

    SELECT qty_units INTO v_qty FROM public.med_on_hand
     WHERE location_id = v_loc AND medication_id='aaaaaaaa-0000-0000-0000-000000000006';
    IF v_qty <> 420 THEN
        RAISE EXCEPTION 'T8b on hand % after count, expected 420', v_qty;
    END IF;

    -- The long line created a layer, and the trigger wrote its ledger row.
    IF NOT EXISTS (
        SELECT 1 FROM public.med_purchase_lines
         WHERE count_id='dddddddd-0000-0000-0000-000000000002'
           AND medication_id='aaaaaaaa-0000-0000-0000-000000000003'
           AND qty_units = 25 AND qty_remaining = 25 AND origin='adjustment'
    ) THEN
        RAISE EXCEPTION 'T8b the long line did not create a layer of exactly 25 units';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.med_txns t
          JOIN public.med_purchase_lines l ON l.id = t.ref_id
         WHERE t.ref_kind='med_purchase_line' AND t.direction = 1
           AND l.count_id='dddddddd-0000-0000-0000-000000000002'
           AND t.total_cost = 100.00
    ) THEN
        RAISE EXCEPTION 'T8b no ledger row was written for the count-born layer';
    END IF;
    RAISE NOTICE 'PASS T8 a count books shrink at real layer cost, and refuses a long line it cannot price';
END $t$;

-- ---------------------------------------------------------------- T9
-- A count-born layer must round-trip EXACTLY. 250 units of a 3,785 mL jug
-- stored as a fraction of a bottle comes back as 250.18.
DO $t$
DECLARE
    v_loc uuid := '00000000-0000-0000-0000-00000000c001';
    v_qty numeric;
BEGIN
    INSERT INTO public.med_counts (id, count_date, location_id, counted_by)
    VALUES ('dddddddd-0000-0000-0000-000000000003','2026-10-31', v_loc, 'test');

    INSERT INTO public.med_count_lines (count_id, medication_id, counted_units, unit_cost)
    VALUES ('dddddddd-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000004', 250, 0.05);

    PERFORM public.med_post_count('dddddddd-0000-0000-0000-000000000003');

    SELECT qty_units INTO v_qty FROM public.med_purchase_lines
     WHERE count_id='dddddddd-0000-0000-0000-000000000003'
       AND medication_id='aaaaaaaa-0000-0000-0000-000000000004';
    IF v_qty <> 250 THEN
        RAISE EXCEPTION 'T9 count-born layer is % units, expected exactly 250', v_qty;
    END IF;
    RAISE NOTICE 'PASS T9 a count-born layer holds exactly the units counted, with no bottle-size rounding';
END $t$;

-- ---------------------------------------------------------------- T10
-- Un-post reverses exactly what the count did, and nothing else.
DO $t$
DECLARE
    v_loc uuid := '00000000-0000-0000-0000-00000000c001';
    v_res jsonb; v_status text; v_qty numeric;
BEGIN
    v_res := public.med_unpost_count('dddddddd-0000-0000-0000-000000000003');
    IF (v_res->>'layers_removed')::integer <> 1 THEN
        RAISE EXCEPTION 'T10 layers_removed %, expected 1', v_res->>'layers_removed';
    END IF;
    IF EXISTS (SELECT 1 FROM public.med_purchase_lines
                WHERE count_id='dddddddd-0000-0000-0000-000000000003') THEN
        RAISE EXCEPTION 'T10 the count-born layer survived un-posting';
    END IF;
    IF EXISTS (SELECT 1 FROM public.med_txns
                WHERE ref_kind='med_purchase_line'
                  AND notes LIKE '%dddddddd-0000-0000-0000-000000000003%') THEN
        RAISE EXCEPTION 'T10 the layer''s ledger row outlived the layer';
    END IF;

    SELECT status INTO v_status FROM public.med_counts WHERE id='dddddddd-0000-0000-0000-000000000003';
    IF v_status <> 'draft' THEN
        RAISE EXCEPTION 'T10 count status is % after un-post, expected draft', v_status;
    END IF;
    IF EXISTS (SELECT 1 FROM public.med_count_lines
                WHERE count_id='dddddddd-0000-0000-0000-000000000003'
                  AND (expected_units IS NOT NULL OR variance_units IS NOT NULL)) THEN
        RAISE EXCEPTION 'T10 stale variance figures survived un-posting';
    END IF;

    -- Un-posting the October count must not have touched September's shrink.
    SELECT qty_units INTO v_qty FROM public.med_on_hand
     WHERE location_id = v_loc AND medication_id='aaaaaaaa-0000-0000-0000-000000000006';
    IF v_qty <> 420 THEN
        RAISE EXCEPTION 'T10 un-posting one count changed another count''s result: on hand %', v_qty;
    END IF;
    RAISE NOTICE 'PASS T10 un-post removes exactly the count''s own layers and adjustments';
END $t$;

-- ---------------------------------------------------------------- T11
-- Un-post refused when a later count sits on top, and refused when the
-- stock the count found has already been used.
DO $t$
DECLARE
    v_loc uuid := '00000000-0000-0000-0000-00000000c001';
    v_refused boolean := false;
BEGIN
    -- September is still posted; put October back on top of it.
    PERFORM public.med_post_count('dddddddd-0000-0000-0000-000000000003');

    BEGIN
        PERFORM public.med_unpost_count('dddddddd-0000-0000-0000-000000000002');
    EXCEPTION WHEN others THEN
        v_refused := (SQLERRM LIKE '%later count%');
    END;
    IF NOT v_refused THEN
        RAISE EXCEPTION 'T11a un-posted a count with a later count on top of it';
    END IF;

    -- Now draw on the stock October found, and try to un-post October.
    PERFORM public.med_consume('aaaaaaaa-0000-0000-0000-000000000004', v_loc, 10,
                               'usage', NULL, 'doctoring_event', NULL, '2026-11-02');
    v_refused := false;
    BEGIN
        PERFORM public.med_unpost_count('dddddddd-0000-0000-0000-000000000003');
    EXCEPTION WHEN others THEN
        v_refused := (SQLERRM LIKE '%already been used%');
    END;
    IF NOT v_refused THEN
        RAISE EXCEPTION 'T11b un-posted a count whose stock had already been used';
    END IF;
    RAISE NOTICE 'PASS T11 un-post refuses under a later count, and refuses to unwind stock already used';
END $t$;

-- ---------------------------------------------------------------- T12
-- The period lock: once a count posts, that location is closed on and
-- before its date for PURCHASES.
DO $t$
DECLARE
    v_loc uuid := '00000000-0000-0000-0000-00000000c002';
    v_locked date; v_refused boolean := false;
BEGIN
    INSERT INTO public.med_purchase_lines
      (medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
    VALUES ('aaaaaaaa-0000-0000-0000-000000000006', v_loc, 1, 250, 'mL', 0.40, 250, '2026-09-10');

    INSERT INTO public.med_counts (id, count_date, location_id, counted_by)
    VALUES ('dddddddd-0000-0000-0000-000000000010','2026-09-30', v_loc, 'test');
    INSERT INTO public.med_count_lines (count_id, medication_id, counted_units)
    VALUES ('dddddddd-0000-0000-0000-000000000010','aaaaaaaa-0000-0000-0000-000000000006', 250);
    PERFORM public.med_post_count('dddddddd-0000-0000-0000-000000000010');

    v_locked := public.med_locked_through(v_loc);
    IF v_locked <> '2026-09-30' THEN
        RAISE EXCEPTION 'T12 locked_through is %, expected 2026-09-30', v_locked;
    END IF;

    BEGIN
        INSERT INTO public.med_purchase_lines
          (medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
        VALUES ('aaaaaaaa-0000-0000-0000-000000000006', v_loc, 1, 250, 'mL', 0.40, 250, '2026-09-15');
    EXCEPTION WHEN others THEN
        v_refused := (SQLERRM LIKE '%period is closed%');
    END;
    IF NOT v_refused THEN
        RAISE EXCEPTION 'T12 a purchase was backdated into a closed period';
    END IF;
    RAISE NOTICE 'PASS T12 a posted count closes the period behind it against backdated purchases';
END $t$;

-- ---------------------------------------------------------------- T13
-- Usage is the one thing that BENDS the lock instead of being lost: a dose
-- approved late posts to the first open day, carrying its true date.
DO $t$
DECLARE
    v_loc uuid := '00000000-0000-0000-0000-00000000c002';
    v_res jsonb; v_notes text; v_date date;
BEGIN
    v_res := public.med_consume('aaaaaaaa-0000-0000-0000-000000000006', v_loc, 20,
                                'usage', NULL, 'doctoring_event', NULL, '2026-09-15');

    IF (v_res->>'posted_date')::date <> '2026-10-01' THEN
        RAISE EXCEPTION 'T13 posted_date %, expected 2026-10-01', v_res->>'posted_date';
    END IF;

    SELECT txn_date, notes INTO v_date, v_notes
      FROM public.med_txns WHERE id = (v_res->>'txn_id')::uuid;
    IF v_date <> '2026-10-01' THEN
        RAISE EXCEPTION 'T13 txn_date %, expected 2026-10-01', v_date;
    END IF;
    IF v_notes IS NULL OR v_notes NOT LIKE '%Given 2026-09-15%' THEN
        RAISE EXCEPTION 'T13 the true treatment date was not kept in the note: %', v_notes;
    END IF;
    RAISE NOTICE 'PASS T13 a late-approved dose posts to the first open day and keeps its real date';
END $t$;

-- ---------------------------------------------------------------- T14
-- The approvals gate. Ranch only.
DO $t$
DECLARE
    v_ranch uuid := '00000000-0000-0000-0000-00000000c003';
    v_buyer uuid := '00000000-0000-0000-0000-00000000c004';
    v_refused boolean := false;
BEGIN
    INSERT INTO public.pending_field_entries (entry_type, client_id, status, event_datetime)
    VALUES ('doctoring','t14','pending','2026-10-28 09:00:00-05');

    INSERT INTO public.med_counts (id, count_date, location_id, counted_by)
    VALUES ('dddddddd-0000-0000-0000-000000000020','2026-10-31', v_ranch, 'test');

    BEGIN
        PERFORM public.med_post_count('dddddddd-0000-0000-0000-000000000020');
    EXCEPTION WHEN others THEN
        v_refused := (SQLERRM LIKE '%awaiting approval%');
    END;
    IF NOT v_refused THEN
        RAISE EXCEPTION 'T14a a ranch count posted with doctoring still in Approvals';
    END IF;

    -- A buyer's shelf has nothing to do with our doctoring queue.
    INSERT INTO public.med_counts (id, count_date, location_id, counted_by)
    VALUES ('dddddddd-0000-0000-0000-000000000021','2026-10-31', v_buyer, 'test');
    PERFORM public.med_post_count('dddddddd-0000-0000-0000-000000000021');

    -- Clear the queue and the ranch count posts.
    UPDATE public.pending_field_entries SET status='approved' WHERE client_id='t14';
    PERFORM public.med_post_count('dddddddd-0000-0000-0000-000000000020');

    IF (SELECT status FROM public.med_counts WHERE id='dddddddd-0000-0000-0000-000000000020') <> 'posted' THEN
        RAISE EXCEPTION 'T14c the ranch count did not post after Approvals was cleared';
    END IF;
    RAISE NOTICE 'PASS T14 a ranch count waits for the Approvals queue; a buyer count does not';
END $t$;

-- ---------------------------------------------------------------- T15
-- med_consume refuses nonsense rather than booking it.
DO $t$
DECLARE
    v_ranch uuid; n integer := 0;
BEGIN
    SELECT id INTO v_ranch FROM public.med_stock_locations WHERE name='Ranch';

    BEGIN
        PERFORM public.med_consume('aaaaaaaa-0000-0000-0000-000000000002', v_ranch, 0);
    EXCEPTION WHEN others THEN n := n + 1; END;
    BEGIN
        PERFORM public.med_consume('aaaaaaaa-0000-0000-0000-000000000002', v_ranch, -5);
    EXCEPTION WHEN others THEN n := n + 1; END;
    BEGIN
        PERFORM public.med_consume('aaaaaaaa-0000-0000-0000-000000000002', v_ranch, 5, 'purchase');
    EXCEPTION WHEN others THEN n := n + 1; END;
    IF n <> 3 THEN
        RAISE EXCEPTION 'T15 expected 3 refusals, got %', n;
    END IF;
    RAISE NOTICE 'PASS T15 med_consume refuses a zero, a negative and a wrong txn_type';
END $t$;

-- ---------------------------------------------------------------- T16
-- A checkout is CUSTODY, not a movement: direction 0, stock unchanged.
DO $t$
DECLARE
    v_ranch uuid; v_before numeric; v_after numeric;
BEGIN
    SELECT id INTO v_ranch FROM public.med_stock_locations WHERE name='Ranch';
    SELECT qty_units INTO v_before FROM public.med_on_hand
     WHERE location_id=v_ranch AND medication_id='aaaaaaaa-0000-0000-0000-000000000002';

    INSERT INTO public.med_txns
      (txn_date, txn_type, medication_id, location_id, qty_units, direction, crew_member_id, notes)
    VALUES ('2026-10-01','checkout','aaaaaaaa-0000-0000-0000-000000000002', v_ranch,
            500, 0, 'bbbbbbbb-0000-0000-0000-000000000001','one bottle to Rudy');

    SELECT qty_units INTO v_after FROM public.med_on_hand
     WHERE location_id=v_ranch AND medication_id='aaaaaaaa-0000-0000-0000-000000000002';
    IF v_before <> v_after THEN
        RAISE EXCEPTION 'T16 a checkout moved stock: % then %', v_before, v_after;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.med_checkout_log
         WHERE crew_member='Rudy' AND bottles = 1.00 AND direction_label='out'
    ) THEN
        RAISE EXCEPTION 'T16 the checkout does not appear in med_checkout_log as 1 bottle out';
    END IF;
    RAISE NOTICE 'PASS T16 a checkout records custody without moving stock';
END $t$;

-- ---------------------------------------------------------------- T17
-- track_inventory = false keeps a medication out of the count sheet.
DO $t$
BEGIN
    IF EXISTS (SELECT 1 FROM public.med_on_hand
                WHERE medication_id='aaaaaaaa-0000-0000-0000-000000000005') THEN
        RAISE EXCEPTION 'T17 an opted-out medication appears in med_on_hand';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.med_on_hand
                WHERE medication_id='aaaaaaaa-0000-0000-0000-000000000006') THEN
        RAISE EXCEPTION 'T17 a tracked medication is missing from med_on_hand';
    END IF;
    RAISE NOTICE 'PASS T17 track_inventory = false opts a medication out of inventory';
END $t$;

-- ---------------------------------------------------------------- T18
-- The rehearsal: a test location erases, a real one refuses.
DO $t$
DECLARE
    v_test uuid := '00000000-0000-0000-0000-00000000c005';
    v_real uuid;
    v_res jsonb; v_refused boolean := false;
BEGIN
    SELECT id INTO v_real FROM public.med_stock_locations WHERE name='Ranch';

    INSERT INTO public.med_purchase_lines
      (medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
    VALUES ('aaaaaaaa-0000-0000-0000-000000000006', v_test, 4, 250, 'mL', 0.40, 1000, '2026-09-01');
    PERFORM public.med_consume('aaaaaaaa-0000-0000-0000-000000000006', v_test, 60,
                               'usage', NULL, 'doctoring_event', NULL, '2026-09-05');

    BEGIN
        PERFORM public.med_purge_location(v_real, false);
    EXCEPTION WHEN others THEN
        v_refused := (SQLERRM LIKE '%not marked as a test location%');
    END;
    IF NOT v_refused THEN
        RAISE EXCEPTION 'T18a med_purge_location erased a REAL location';
    END IF;

    v_res := public.med_purge_location(v_test, true);
    IF EXISTS (SELECT 1 FROM public.med_purchase_lines WHERE location_id = v_test)
       OR EXISTS (SELECT 1 FROM public.med_txns WHERE location_id = v_test)
       OR EXISTS (SELECT 1 FROM public.med_stock_locations WHERE id = v_test) THEN
        RAISE EXCEPTION 'T18b the rehearsal left traces: %', v_res::text;
    END IF;
    RAISE NOTICE 'PASS T18 a test location erases without a trace; a real one refuses';
END $t$;

-- ---------------------------------------------------------------- T19
-- The roll-forward identity, on every row:
--   beginning + purchases + opening - used + adjustments + uncovered = ending
DO $t$
DECLARE bad integer;
BEGIN
    SELECT count(*) INTO bad FROM public.med_roll_forward
     WHERE round(beginning_units + purchased_units + opening_units
                 - used_units + adjustment_units + uncovered_units, 4)
        <> round(ending_units, 4);
    IF bad > 0 THEN
        RAISE EXCEPTION 'T19a the unit identity fails on % row(s)', bad;
    END IF;

    SELECT count(*) INTO bad FROM public.med_roll_forward
     WHERE round(beginning_value + purchased_value + opening_value
                 - used_value + adjustment_value + uncovered_value, 2)
        <> round(ending_value, 2);
    IF bad > 0 THEN
        RAISE EXCEPTION 'T19b the value identity fails on % row(s)', bad;
    END IF;
    RAISE NOTICE 'PASS T19 the roll-forward ties in units and in dollars on every row';
END $t$;

-- ---------------------------------------------------------------- T20
-- med_roll_forward's last month must agree with med_on_hand. They used to
-- differ by exactly the shortfall, which is why uncovered is a column.
DO $t$
DECLARE bad integer;
BEGIN
    WITH last_period AS (
        SELECT DISTINCT ON (location_id, medication_id)
               location_id, medication_id, ending_units, ending_value
          FROM public.med_roll_forward
         ORDER BY location_id, medication_id, period_month DESC
    )
    SELECT count(*) INTO bad
      FROM last_period lp
      JOIN public.med_on_hand oh
        ON oh.location_id = lp.location_id AND oh.medication_id = lp.medication_id
     WHERE round(lp.ending_units, 4) <> round(oh.qty_units, 4)
        OR round(lp.ending_value, 2) <> round(oh.value_fifo, 2);
    IF bad > 0 THEN
        RAISE EXCEPTION 'T20 med_roll_forward and med_on_hand disagree on % pair(s)', bad;
    END IF;
    RAISE NOTICE 'PASS T20 the roll-forward''s ending balance equals med_on_hand';
END $t$;

-- ---------------------------------------------------------------- T21
-- The buyer report compares what he drew against what the cattle should
-- have got, and does not invent its own dose arithmetic.
DO $t$
DECLARE
    v_buyer uuid := '00000000-0000-0000-0000-00000000c004';
    v_lot uuid := 'eeeeeeee-0000-0000-0000-000000000001';
    v_proto uuid := 'ffffffff-0000-0000-0000-000000000001';
    v_exp numeric; v_drawn numeric; v_head integer;
BEGIN
    INSERT INTO public.lots (id, lot_number, source) VALUES (v_lot, '70X', 'ACME');
    INSERT INTO public.protocols (id, name) VALUES (v_proto, 'Receiving 2027');
    INSERT INTO public.protocol_meds (protocol_id, medication_id)
    VALUES (v_proto, 'aaaaaaaa-0000-0000-0000-000000000001');
    INSERT INTO public.invoices (id, lot_id, head_count, total_weight_lb, total_cost)
    VALUES ('eeeeeeee-0000-0000-0000-000000000002', v_lot, 100, 55000, 100000);
    INSERT INTO public.delivery_receipts (lot_id, receipt_date, head_count, receiving_protocol_id, invoice_id)
    VALUES (v_lot, '2026-11-05', 100, v_proto, 'eeeeeeee-0000-0000-0000-000000000002');

    -- He picked up 700 mL for 100 head at 550 lb: 1.1 mL per cwt, rounded up
    -- to the whole mL, is 7 mL a head -- 700 expected.
    INSERT INTO public.med_purchase_lines
      (medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
    VALUES ('aaaaaaaa-0000-0000-0000-000000000001', v_buyer, 1.6, 500, 'mL', 2.00, 800, '2026-11-01');

    SELECT expected_units, drawn_units, head_processed INTO v_exp, v_drawn, v_head
      FROM public.med_buyer_reconciliation
     WHERE location_id = v_buyer AND medication_id='aaaaaaaa-0000-0000-0000-000000000001'
       AND period_month = '2026-11-01';

    IF v_head <> 100 THEN
        RAISE EXCEPTION 'T21 head_processed %, expected 100', v_head;
    END IF;
    IF v_exp <> 700 THEN
        RAISE EXCEPTION 'T21 expected_units %, expected 700', v_exp;
    END IF;
    IF v_drawn <> 800 THEN
        RAISE EXCEPTION 'T21 drawn_units %, expected 800', v_drawn;
    END IF;
    RAISE NOTICE 'PASS T21 the buyer report ties his pickups to the head he processed';
END $t$;

-- ---------------------------------------------------------------- T22
-- Deleting a purchase line takes its ledger row with it, and is BLOCKED
-- once something has drawn on that layer.
DO $t$
DECLARE
    v_ranch uuid; v_line uuid; v_blocked boolean := false;
BEGIN
    SELECT id INTO v_ranch FROM public.med_stock_locations WHERE name='Ranch';

    INSERT INTO public.med_purchase_lines
      (id, medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
    VALUES ('cccccccc-0000-0000-0000-000000000020','aaaaaaaa-0000-0000-0000-000000000006',
            v_ranch, 1, 250, 'mL', 0.40, 250, '2026-10-05')
    RETURNING id INTO v_line;

    IF NOT EXISTS (SELECT 1 FROM public.med_txns
                    WHERE ref_kind='med_purchase_line' AND ref_id = v_line
                      AND txn_type='purchase' AND direction = 1 AND total_cost = 100.00) THEN
        RAISE EXCEPTION 'T22a no ledger row was written for a new purchase line';
    END IF;

    DELETE FROM public.med_purchase_lines WHERE id = v_line;
    IF EXISTS (SELECT 1 FROM public.med_txns WHERE ref_kind='med_purchase_line' AND ref_id = v_line) THEN
        RAISE EXCEPTION 'T22b the ledger row outlived its purchase line';
    END IF;

    -- Now one that has been drawn on.
    INSERT INTO public.med_purchase_lines
      (id, medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
    VALUES ('cccccccc-0000-0000-0000-000000000021','aaaaaaaa-0000-0000-0000-000000000006',
            v_ranch, 1, 250, 'mL', 0.40, 250, '2026-10-06');
    PERFORM public.med_consume('aaaaaaaa-0000-0000-0000-000000000006', v_ranch, 30,
                               'usage', NULL, 'doctoring_event', NULL, '2026-10-07');
    BEGIN
        DELETE FROM public.med_purchase_lines WHERE id='cccccccc-0000-0000-0000-000000000021';
    EXCEPTION WHEN others THEN
        v_blocked := true;
    END;
    IF NOT v_blocked THEN
        RAISE EXCEPTION 'T22c a purchase line whose stock had been used was deleted';
    END IF;
    RAISE NOTICE 'PASS T22 a layer and its ledger row live and die together, and used stock cannot be deleted';
END $t$;

-- ---------------------------------------------------------------- T23
-- RLS, under real logins. Crew sees no dollars at all; the accountant reads
-- and writes nothing; office writes but does not delete.
SET SESSION AUTHORIZATION office_user;
SET test.role = 'crew';
DO $t$
DECLARE n integer; v_denied boolean := false;
BEGIN
    SELECT count(*) INTO n FROM public.med_on_hand;
    IF n <> 0 THEN RAISE EXCEPTION 'T23a crew read % med_on_hand rows', n; END IF;
    SELECT count(*) INTO n FROM public.med_txns;
    IF n <> 0 THEN RAISE EXCEPTION 'T23a crew read % med_txns rows', n; END IF;
    SELECT count(*) INTO n FROM public.med_purchase_lines;
    IF n <> 0 THEN RAISE EXCEPTION 'T23a crew read % layer rows', n; END IF;

    BEGIN
        INSERT INTO public.med_crew_members (name) VALUES ('crew should not');
    EXCEPTION WHEN others THEN v_denied := true; END;
    IF NOT v_denied THEN RAISE EXCEPTION 'T23a crew wrote a med row'; END IF;
    RAISE NOTICE 'PASS T23a crew reads zero rows and writes nothing';
END $t$;

SET test.role = 'accountant';
DO $t$
DECLARE n integer; v_denied boolean := false;
BEGIN
    SELECT count(*) INTO n FROM public.med_on_hand;
    IF n = 0 THEN RAISE EXCEPTION 'T23b the accountant cannot read med_on_hand'; END IF;
    SELECT count(*) INTO n FROM public.med_txns;
    IF n = 0 THEN RAISE EXCEPTION 'T23b the accountant cannot read med_txns'; END IF;

    BEGIN
        INSERT INTO public.med_crew_members (name) VALUES ('accountant should not');
    EXCEPTION WHEN others THEN v_denied := true; END;
    IF NOT v_denied THEN RAISE EXCEPTION 'T23b the accountant wrote a med row'; END IF;
    RAISE NOTICE 'PASS T23b the accountant reads the books and writes nothing';
END $t$;

SET test.role = 'office';
DO $t$
DECLARE n integer; v_denied boolean := false;
BEGIN
    SELECT count(*) INTO n FROM public.med_on_hand;
    IF n = 0 THEN RAISE EXCEPTION 'T23c office cannot read med_on_hand'; END IF;

    INSERT INTO public.med_crew_members (id, name)
    VALUES ('bbbbbbbb-0000-0000-0000-00000000000f','Office Added');

    BEGIN
        DELETE FROM public.med_crew_members WHERE id='bbbbbbbb-0000-0000-0000-00000000000f';
        IF NOT FOUND THEN v_denied := true; END IF;
    EXCEPTION WHEN others THEN v_denied := true; END;
    IF NOT v_denied THEN RAISE EXCEPTION 'T23c office deleted a med row'; END IF;
    RAISE NOTICE 'PASS T23c office reads and writes but cannot delete';
END $t$;

SET test.role = 'owner';
DO $t$
BEGIN
    DELETE FROM public.med_crew_members WHERE id='bbbbbbbb-0000-0000-0000-00000000000f';
    IF FOUND THEN
        RAISE NOTICE 'PASS T23d the owner can delete';
    ELSE
        RAISE EXCEPTION 'T23d the owner could not delete';
    END IF;
END $t$;

-- An unknown or inactive role is NULL, and NULL must deny.
SET test.role = '';
DO $t$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM public.med_on_hand;
    IF n <> 0 THEN RAISE EXCEPTION 'T23e a NULL role read % rows', n; END IF;
    RAISE NOTICE 'PASS T23e a NULL role reads nothing';
END $t$;

RESET SESSION AUTHORIZATION;
SET test.role = 'owner';

-- ---------------------------------------------------------------- T24
-- An ADJUSTMENT that itself ran short -- a waste entry against an empty
-- shelf. This is the row that broke the roll-forward identity while
-- adjustment_units netted the uncovered part out and uncovered_units added
-- it back: the same units were removed twice.
DO $t$
DECLARE
    v_loc uuid := '00000000-0000-0000-0000-00000000c003';
    v_res jsonb; v_unc numeric; v_adj numeric; bad integer;
BEGIN
    v_res := public.med_consume('aaaaaaaa-0000-0000-0000-000000000006', v_loc, 40,
                                'adjustment', 'waste', NULL, NULL, '2026-11-15',
                                'broke a bottle, nothing on the shelf to take it off');

    IF (v_res->>'shortfall_units')::numeric <> 40 THEN
        RAISE EXCEPTION 'T24 expected a 40-unit shortfall on the adjustment, got %',
            v_res->>'shortfall_units';
    END IF;

    SELECT uncovered_units, adjustment_units INTO v_unc, v_adj
      FROM public.med_roll_forward
     WHERE location_id = v_loc AND medication_id='aaaaaaaa-0000-0000-0000-000000000006'
       AND period_month = '2026-11-01';

    IF COALESCE(v_unc,0) <= 0 THEN
        RAISE EXCEPTION 'T24 the test did not produce an uncovered adjustment (uncovered %)', v_unc;
    END IF;
    IF v_adj <> -40 THEN
        RAISE EXCEPTION 'T24 adjustment_units is %, expected -40 (gross and signed)', v_adj;
    END IF;

    SELECT count(*) INTO bad FROM public.med_roll_forward
     WHERE round(beginning_units + purchased_units + opening_units
                 - used_units + adjustment_units + uncovered_units, 4)
        <> round(ending_units, 4)
        OR round(beginning_value + purchased_value + opening_value
                 - used_value + adjustment_value + uncovered_value, 2)
        <> round(ending_value, 2);
    IF bad > 0 THEN
        RAISE EXCEPTION 'T24 the identity fails on % row(s) once an adjustment runs short', bad;
    END IF;
    RAISE NOTICE 'PASS T24 the identity still ties when an adjustment itself runs short';
END $t$;

-- ---------------------------------------------------------------- T25
-- And med_on_hand still agrees with the roll-forward after that.
DO $t$
DECLARE bad integer;
BEGIN
    WITH last_period AS (
        SELECT DISTINCT ON (location_id, medication_id)
               location_id, medication_id, ending_units, ending_value
          FROM public.med_roll_forward
         ORDER BY location_id, medication_id, period_month DESC
    )
    SELECT count(*) INTO bad
      FROM last_period lp
      JOIN public.med_on_hand oh
        ON oh.location_id = lp.location_id AND oh.medication_id = lp.medication_id
     WHERE round(lp.ending_units, 4) <> round(oh.qty_units, 4)
        OR round(lp.ending_value, 2) <> round(oh.value_fifo, 2);
    IF bad > 0 THEN
        RAISE EXCEPTION 'T25 med_roll_forward and med_on_hand disagree on % pair(s)', bad;
    END IF;
    RAISE NOTICE 'PASS T25 the two reports still tie with a shorted adjustment in the ledger';
END $t$;
