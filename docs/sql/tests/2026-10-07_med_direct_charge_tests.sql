-- Direct medicine charge assertion suite. Every block raises on failure and
-- prints PASS on success. Run with ON_ERROR_STOP=0 so one failure does not
-- hide the rest, then count the PASS lines and grep for ERROR.
--
-- Roles are real: the write tests run as office_user / crew_user / acct_user
-- (members of authenticated, not superusers) so RLS actually applies, with
-- test.role standing in for the profile row current_user_role() reads.
\set ON_ERROR_STOP 0
SET client_min_messages = notice;
SET test.uid   = '00000000-0000-0000-0000-0000000000b1';
SET test.today = '2026-10-07';

-- Ids, for reading the blocks below:
--   lots   60X a..01  61X a..02  50X (closed) a..03
--   meds   Cydectin b..01 ($0.10 then $0.12 a mL)  Draxxin b..02 ($2)  Mystery b..03 (no price)
--   ccs    Cow/Calf Wip c..01 (no coding)  Bulls c..02 (PC-20 / BULLS)  Old Horses c..03 (inactive)
--   shelf  Charge Barn e..01 (live from 10/1)  Not Live e..02

SET ROLE office_user;
SET test.role = 'office';

-- ---------------------------------------------------------------- C1
-- A lot charge across two layers: FIFO cost, layers drop, the lot gains
-- exactly that under the category chosen, and the usage view resolves it.
DO $t$
DECLARE v jsonb; a numeric; b numeric; r record;
BEGIN
    v := public.post_med_charge('2026-10-06', 'b0000000-0000-0000-0000-000000000001',
            'e0000000-0000-0000-0000-000000000001', 6000, 'lot',
            'a0000000-0000-0000-0000-000000000001', NULL, 'other', 'Pour-on whole lot');
    IF (v->>'total_cost')::numeric <> 620 THEN
        RAISE EXCEPTION 'C1 cost: expected 620 (5000 x 0.10 + 1000 x 0.12), got %', v->>'total_cost';
    END IF;
    IF (v->>'shortfall_units')::numeric <> 0 OR (v->>'cost_provisional')::boolean THEN
        RAISE EXCEPTION 'C1 unexpected shortfall/provisional: %', v;
    END IF;
    IF (v->>'posted_date')::date <> '2026-10-06' THEN
        RAISE EXCEPTION 'C1 posted_date %', v->>'posted_date';
    END IF;
    SELECT qty_remaining INTO a FROM public.med_purchase_lines WHERE id = '90000000-0000-0000-0000-000000000001';
    SELECT qty_remaining INTO b FROM public.med_purchase_lines WHERE id = '90000000-0000-0000-0000-000000000002';
    IF a <> 0 OR b <> 4000 THEN RAISE EXCEPTION 'C1 layers: expected 0 / 4000, got % / %', a, b; END IF;

    SELECT * INTO r FROM public.lot_med_costs_by_category
     WHERE lot_id = 'a0000000-0000-0000-0000-000000000001' AND category = 'other';
    IF r.total_cost IS DISTINCT FROM 620.0000 OR r.event_count <> 1 OR r.med_row_count <> 1 OR r.unpriced_row_count <> 0 THEN
        RAISE EXCEPTION 'C1 lot view other row: %', row_to_json(r);
    END IF;

    SELECT * INTO r FROM public.med_usage_by_lot WHERE txn_id = (v->>'txn_id')::uuid;
    IF r.lot_number <> '60X' OR r.category <> 'other' OR r.ref_kind <> 'med_charge'
       OR r.cost_center_id IS NOT NULL OR r.total_cost <> 620 THEN
        RAISE EXCEPTION 'C1 usage view row: %', row_to_json(r);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.med_charges WHERE id = (v->>'charge_id')::uuid
                    AND txn_id = (v->>'txn_id')::uuid AND notes = 'Pour-on whole lot') THEN
        RAISE EXCEPTION 'C1 charge row missing or wrong';
    END IF;
    RAISE NOTICE 'PASS C1 lot charge draws FIFO and lands on the lot under its category';
END $t$;

-- ---------------------------------------------------------------- C2
-- A cost-centre charge: no lot view moves, the usage view carries the cost
-- centre and its coding.
DO $t$
DECLARE v jsonb; r record; n integer;
BEGIN
    CREATE TEMP TABLE lot_before_c2 AS SELECT * FROM public.lot_med_costs_by_category;
    v := public.post_med_charge('2026-10-06', 'b0000000-0000-0000-0000-000000000002',
            'e0000000-0000-0000-0000-000000000001', 100, 'cost_center',
            NULL, 'c0000000-0000-0000-0000-000000000002', NULL, NULL);
    IF (v->>'total_cost')::numeric <> 200 THEN RAISE EXCEPTION 'C2 cost %', v->>'total_cost'; END IF;

    SELECT count(*) INTO n FROM (
        (SELECT * FROM public.lot_med_costs_by_category EXCEPT SELECT * FROM lot_before_c2)
        UNION ALL
        (SELECT * FROM lot_before_c2 EXCEPT SELECT * FROM public.lot_med_costs_by_category)) x;
    IF n <> 0 THEN RAISE EXCEPTION 'C2 a cost-centre charge moved % lot cost row(s)', n; END IF;

    SELECT * INTO r FROM public.med_usage_by_lot WHERE txn_id = (v->>'txn_id')::uuid;
    IF r.lot_id IS NOT NULL OR r.category <> 'cost_center' OR r.cost_center_name <> 'Bulls'
       OR r.profit_center <> 'PC-20' OR r.redwing_production_center <> 'BULLS' THEN
        RAISE EXCEPTION 'C2 usage view row: %', row_to_json(r);
    END IF;
    DROP TABLE lot_before_c2;
    RAISE NOTICE 'PASS C2 cost-centre charge leaves every lot alone and carries its coding';
END $t$;

-- ---------------------------------------------------------------- C3
-- A charge into a category the lot already has from doctoring: still one
-- row per (lot, category), summed.
DO $t$
DECLARE v jsonb; r record; n integer;
BEGIN
    v := public.post_med_charge('2026-10-06', 'b0000000-0000-0000-0000-000000000002',
            'e0000000-0000-0000-0000-000000000001', 10, 'lot',
            'a0000000-0000-0000-0000-000000000002', NULL, 'treatment', NULL);
    SELECT count(*) INTO n FROM public.lot_med_costs_by_category
     WHERE lot_id = 'a0000000-0000-0000-0000-000000000002' AND category = 'treatment';
    IF n <> 1 THEN RAISE EXCEPTION 'C3 % treatment rows for 61X, expected 1', n; END IF;
    SELECT * INTO r FROM public.lot_med_costs_by_category
     WHERE lot_id = 'a0000000-0000-0000-0000-000000000002' AND category = 'treatment';
    IF r.total_cost <> 26 OR r.event_count <> 2 OR r.med_row_count <> 2 THEN
        RAISE EXCEPTION 'C3 merged row: % (expected 6 doctoring + 20 charge, 2 events, 2 rows)', row_to_json(r);
    END IF;
    RAISE NOTICE 'PASS C3 a charge merges into the lot''s existing category row';
END $t$;

-- ---------------------------------------------------------------- C4
-- Lots and categories with no charge read exactly as before the migration,
-- NULL totals and all.
DO $t$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM (
        SELECT b.* FROM test.lot_med_before b
         WHERE NOT EXISTS (SELECT 1 FROM public.med_charges c
                            WHERE c.lot_id = b.lot_id AND c.category = b.category)
        EXCEPT
        SELECT * FROM public.lot_med_costs_by_category) x;
    IF n <> 0 THEN RAISE EXCEPTION 'C4 % untouched lot/category row(s) changed', n; END IF;
    IF (SELECT count(*) FROM test.lot_med_before) <> 3 THEN
        RAISE EXCEPTION 'C4 fixture expected 3 before rows (60X treatment, 60X processing, 61X treatment)';
    END IF;
    RAISE NOTICE 'PASS C4 lots with no charge read exactly as before the view replace';
END $t$;

-- ---------------------------------------------------------------- C5
-- Refusals. Each must raise, and none may leave anything behind.
DO $t$
DECLARE n0 integer; n1 integer; msg text; k integer := 0;
BEGIN
    SELECT count(*) INTO n0 FROM public.med_txns;
    BEGIN PERFORM public.post_med_charge('2026-10-06','b0000000-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000001',1,'lot','a0000000-0000-0000-0000-000000000003',NULL,'other',NULL);
    EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT; IF msg LIKE '%closed%' THEN k := k + 1; END IF; END;
    BEGIN PERFORM public.post_med_charge('2026-10-06','b0000000-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000001',1,'cost_center',NULL,'c0000000-0000-0000-0000-000000000003',NULL,NULL);
    EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT; IF msg LIKE '%inactive%' THEN k := k + 1; END IF; END;
    BEGIN PERFORM public.post_med_charge('2026-10-06','b0000000-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000001',1,'lot','a0000000-0000-0000-0000-000000000001',NULL,NULL,NULL);
    EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT; IF msg LIKE '%category%' THEN k := k + 1; END IF; END;
    BEGIN PERFORM public.post_med_charge('2026-10-06','b0000000-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000001',1,'lot','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000002','other',NULL);
    EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT; IF msg LIKE '%cost centre%' THEN k := k + 1; END IF; END;
    BEGIN PERFORM public.post_med_charge('2026-10-06','b0000000-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000001',1,'cost_center','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000002',NULL,NULL);
    EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT; IF msg LIKE '%names no lot%' THEN k := k + 1; END IF; END;
    BEGIN PERFORM public.post_med_charge('2026-10-06','b0000000-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000001',0,'lot','a0000000-0000-0000-0000-000000000001',NULL,'other',NULL);
    EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT; IF msg LIKE '%more than zero%' THEN k := k + 1; END IF; END;
    BEGIN PERFORM public.post_med_charge('2026-10-06','b0000000-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000002',1,'lot','a0000000-0000-0000-0000-000000000001',NULL,'other',NULL);
    EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT; IF msg LIKE '%not live%' THEN k := k + 1; END IF; END;
    BEGIN PERFORM public.post_med_charge('2026-10-06','b0000000-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000001',1,'pasture',NULL,NULL,NULL,NULL);
    EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT; IF msg LIKE '%destination%' THEN k := k + 1; END IF; END;
    BEGIN PERFORM public.post_med_charge('2026-10-06','b0000000-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000001',1,'lot','a0000000-0000-0000-0000-000000000001',NULL,'feed',NULL);
    EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT; IF msg LIKE '%category%' THEN k := k + 1; END IF; END;
    SELECT count(*) INTO n1 FROM public.med_txns;
    IF k <> 9 THEN RAISE EXCEPTION 'C5 only % of 9 refusals raised the expected message', k; END IF;
    IF n1 <> n0 THEN RAISE EXCEPTION 'C5 a refused charge left % ledger row(s)', n1 - n0; END IF;
    RAISE NOTICE 'PASS C5 closed lot, inactive cost centre, missing/bad category, mixed destination, zero qty, unlive shelf, bad destination all refused, nothing left';
END $t$;

-- ---------------------------------------------------------------- C6
-- Short stock posts uncovered, priced at the last cost; no price at all
-- posts at $0 flagged provisional and counts as unpriced on the lot.
DO $t$
DECLARE v jsonb; r record;
BEGIN
    v := public.post_med_charge('2026-10-06', 'b0000000-0000-0000-0000-000000000002',
            'e0000000-0000-0000-0000-000000000001', 1000, 'lot',
            'a0000000-0000-0000-0000-000000000002', NULL, 'processing', NULL);
    -- 390 left after C2 (100) and C3 (10).
    IF (v->>'shortfall_units')::numeric <> 610 OR (v->>'total_cost')::numeric <> 2000
       OR (v->>'cost_provisional')::boolean THEN
        RAISE EXCEPTION 'C6 short draw: %', v;
    END IF;
    v := public.post_med_charge('2026-10-06', 'b0000000-0000-0000-0000-000000000003',
            'e0000000-0000-0000-0000-000000000001', 50, 'lot',
            'a0000000-0000-0000-0000-000000000002', NULL, 'other', NULL);
    IF NOT (v->>'cost_provisional')::boolean OR (v->>'total_cost')::numeric <> 0 THEN
        RAISE EXCEPTION 'C6 unpriced draw: %', v;
    END IF;
    SELECT * INTO r FROM public.lot_med_costs_by_category
     WHERE lot_id = 'a0000000-0000-0000-0000-000000000002' AND category = 'other';
    IF r.unpriced_row_count <> 1 THEN RAISE EXCEPTION 'C6 unpriced not counted: %', row_to_json(r); END IF;
    SELECT * INTO r FROM public.med_usage_by_lot WHERE txn_id = (v->>'txn_id')::uuid;
    IF NOT r.cost_provisional THEN RAISE EXCEPTION 'C6 usage view lost the provisional flag'; END IF;
    RAISE NOTICE 'PASS C6 short stock posts uncovered and flagged, never refused';
END $t$;

-- ---------------------------------------------------------------- C7
-- Undo restores the layers to the unit and removes the row from every view.
-- Office may not; owner may.
DO $t$
DECLARE v jsonb; v2 jsonb; a0 numeric; b0 numeric; a1 numeric; b1 numeric; msg text; ok boolean := false;
BEGIN
    SELECT qty_remaining INTO a0 FROM public.med_purchase_lines WHERE id = '90000000-0000-0000-0000-000000000001';
    SELECT qty_remaining INTO b0 FROM public.med_purchase_lines WHERE id = '90000000-0000-0000-0000-000000000002';
    v := public.post_med_charge('2026-10-06', 'b0000000-0000-0000-0000-000000000001',
            'e0000000-0000-0000-0000-000000000001', 1500, 'cost_center',
            NULL, 'c0000000-0000-0000-0000-000000000001', NULL, NULL);
    PERFORM set_config('test.c7_charge', v->>'charge_id', false);
    PERFORM set_config('test.c7_txn', v->>'txn_id', false);
    PERFORM set_config('test.c7_b0', b0::text, false);
    BEGIN
        PERFORM public.delete_med_charge((v->>'charge_id')::uuid);
    EXCEPTION WHEN insufficient_privilege THEN ok := true;
    END;
    IF NOT ok THEN RAISE EXCEPTION 'C7 office was allowed to undo'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.med_charges WHERE id = (v->>'charge_id')::uuid)
       OR NOT EXISTS (SELECT 1 FROM public.med_txns WHERE id = (v->>'txn_id')::uuid) THEN
        RAISE EXCEPTION 'C7 a refused undo changed something';
    END IF;
    RAISE NOTICE 'PASS C7a office cannot undo, and the refusal changes nothing';
END $t$;

SET test.role = 'owner';
DO $t$
DECLARE v jsonb; b1 numeric;
BEGIN
    v := public.delete_med_charge(current_setting('test.c7_charge')::uuid);
    IF (v->>'restored_units')::numeric <> 1500 THEN RAISE EXCEPTION 'C7 restored %', v; END IF;
    SELECT qty_remaining INTO b1 FROM public.med_purchase_lines WHERE id = '90000000-0000-0000-0000-000000000002';
    IF b1 <> current_setting('test.c7_b0')::numeric THEN
        RAISE EXCEPTION 'C7 layer back to %, expected %', b1, current_setting('test.c7_b0');
    END IF;
    IF EXISTS (SELECT 1 FROM public.med_charges WHERE id = current_setting('test.c7_charge')::uuid)
       OR EXISTS (SELECT 1 FROM public.med_txns WHERE id = current_setting('test.c7_txn')::uuid)
       OR EXISTS (SELECT 1 FROM public.med_txn_layers WHERE txn_id = current_setting('test.c7_txn')::uuid)
       OR EXISTS (SELECT 1 FROM public.med_usage_by_lot WHERE txn_id = current_setting('test.c7_txn')::uuid) THEN
        RAISE EXCEPTION 'C7 undo left a trace';
    END IF;
    RAISE NOTICE 'PASS C7b owner undo restores the layer to the unit and removes every trace';
END $t$;

-- Undo of a LOT charge takes it back off the lot.
DO $t$
DECLARE v jsonb; before numeric; after numeric;
BEGIN
    SELECT total_cost INTO before FROM public.lot_med_costs_by_category
     WHERE lot_id = 'a0000000-0000-0000-0000-000000000001' AND category = 'other';
    v := public.post_med_charge('2026-10-06', 'b0000000-0000-0000-0000-000000000001',
            'e0000000-0000-0000-0000-000000000001', 10, 'lot',
            'a0000000-0000-0000-0000-000000000001', NULL, 'other', NULL);
    PERFORM public.delete_med_charge((v->>'charge_id')::uuid);
    SELECT total_cost INTO after FROM public.lot_med_costs_by_category
     WHERE lot_id = 'a0000000-0000-0000-0000-000000000001' AND category = 'other';
    IF after IS DISTINCT FROM before THEN RAISE EXCEPTION 'C7c lot other % after undo, was %', after, before; END IF;
    -- And a lot charge whose only row is undone leaves no row at all.
    v := public.post_med_charge('2026-10-06', 'b0000000-0000-0000-0000-000000000001',
            'e0000000-0000-0000-0000-000000000001', 10, 'lot',
            'a0000000-0000-0000-0000-000000000001', NULL, 'treatment', NULL);
    PERFORM public.delete_med_charge((v->>'charge_id')::uuid);
    IF NOT EXISTS (SELECT 1 FROM test.lot_med_before b JOIN public.lot_med_costs_by_category c
                    USING (lot_id, category)
                    WHERE b.lot_id = 'a0000000-0000-0000-0000-000000000001' AND b.category = 'treatment'
                      AND b.total_cost IS NOT DISTINCT FROM c.total_cost
                      AND b.med_row_count = c.med_row_count) THEN
        RAISE EXCEPTION 'C7c 60X treatment not back to its pre-migration value';
    END IF;
    RAISE NOTICE 'PASS C7c undoing a lot charge takes exactly that off the lot';
END $t$;

-- ---------------------------------------------------------------- C8
-- Closed month: a charge dated into a counted month posts to the first open
-- day with its true date in the note; a charge posted in a month since
-- closed cannot be undone.
SET test.role = 'office';
DO $t$
DECLARE v jsonb;
BEGIN
    v := public.post_med_charge('2026-10-04', 'b0000000-0000-0000-0000-000000000001',
            'e0000000-0000-0000-0000-000000000001', 20, 'lot',
            'a0000000-0000-0000-0000-000000000001', NULL, 'other', NULL);
    PERFORM set_config('test.c8_early', v->>'charge_id', false);
END $t$;

RESET ROLE;
INSERT INTO public.med_counts (location_id, count_date, status, is_opening)
VALUES ('e0000000-0000-0000-0000-000000000001', '2026-10-05', 'posted', false);
SET ROLE office_user;

DO $t$
DECLARE v jsonb; r record;
BEGIN
    v := public.post_med_charge('2026-10-03', 'b0000000-0000-0000-0000-000000000001',
            'e0000000-0000-0000-0000-000000000001', 20, 'lot',
            'a0000000-0000-0000-0000-000000000001', NULL, 'other', NULL);
    IF (v->>'posted_date')::date <> '2026-10-06' OR (v->>'charge_date')::date <> '2026-10-03' THEN
        RAISE EXCEPTION 'C8 dates: %', v;
    END IF;
    SELECT * INTO r FROM public.med_txns WHERE id = (v->>'txn_id')::uuid;
    IF r.txn_date <> '2026-10-06' OR r.notes NOT LIKE '%Given 2026-10-03, posted 2026-10-06%' THEN
        RAISE EXCEPTION 'C8 ledger row: % / %', r.txn_date, r.notes;
    END IF;
    IF (SELECT charge_date FROM public.med_charges WHERE id = (v->>'charge_id')::uuid) <> '2026-10-03' THEN
        RAISE EXCEPTION 'C8 charge lost its true date';
    END IF;
    RAISE NOTICE 'PASS C8a a charge into a closed month posts to the first open day, true date kept';
END $t$;

SET test.role = 'owner';
DO $t$
DECLARE ok boolean := false;
BEGIN
    BEGIN
        PERFORM public.delete_med_charge(current_setting('test.c8_early')::uuid);
    EXCEPTION WHEN check_violation THEN ok := true;
    END;
    IF NOT ok THEN RAISE EXCEPTION 'C8 undo of a charge in a closed month was allowed'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.med_charges WHERE id = current_setting('test.c8_early')::uuid) THEN
        RAISE EXCEPTION 'C8 refused undo removed the charge';
    END IF;
    RAISE NOTICE 'PASS C8b a charge in a counted, closed month cannot be undone';
END $t$;

-- ---------------------------------------------------------------- C9
-- Crew and accountant cannot post; crew reads no charge rows (no dollars);
-- accountant reads them.
SET ROLE crew_user;
SET test.role = 'crew';
DO $t$
DECLARE ok boolean := false; n integer;
BEGIN
    BEGIN
        PERFORM public.post_med_charge('2026-10-06','b0000000-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000001',1,'lot','a0000000-0000-0000-0000-000000000001',NULL,'other',NULL);
    EXCEPTION WHEN insufficient_privilege THEN ok := true;
    END;
    IF NOT ok THEN RAISE EXCEPTION 'C9 crew could post a charge'; END IF;
    SELECT count(*) INTO n FROM public.med_charges;
    IF n <> 0 THEN RAISE EXCEPTION 'C9 crew reads % charge rows', n; END IF;
    SELECT count(*) INTO n FROM public.med_usage_by_lot;
    IF n <> 0 THEN RAISE EXCEPTION 'C9 crew reads % usage rows', n; END IF;
    RAISE NOTICE 'PASS C9a crew cannot post and reads no charge or usage rows';
END $t$;

SET ROLE acct_user;
SET test.role = 'accountant';
DO $t$
DECLARE ok boolean := false; n integer;
BEGIN
    BEGIN
        PERFORM public.post_med_charge('2026-10-06','b0000000-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000001',1,'lot','a0000000-0000-0000-0000-000000000001',NULL,'other',NULL);
    EXCEPTION WHEN insufficient_privilege THEN ok := true;
    END;
    IF NOT ok THEN RAISE EXCEPTION 'C9 accountant could post a charge'; END IF;
    SELECT count(*) INTO n FROM public.med_charges;
    IF n = 0 THEN RAISE EXCEPTION 'C9 accountant reads no charges'; END IF;
    RAISE NOTICE 'PASS C9b accountant reads charges and cannot post';
END $t$;

-- ---------------------------------------------------------------- C10
-- The usage view still carries every usage row exactly once, and the rows
-- that existed before the migration read the same in every old column.
RESET ROLE;
DO $t$
DECLARE v_view numeric; v_src numeric; n integer;
BEGIN
    SELECT round(sum(total_cost), 4) INTO v_view FROM public.med_usage_by_lot;
    SELECT round(sum(total_cost), 4) INTO v_src FROM public.med_txns WHERE direction = -1 AND txn_type = 'usage';
    IF v_view IS DISTINCT FROM v_src THEN RAISE EXCEPTION 'C10 view % vs ledger %', v_view, v_src; END IF;
    SELECT count(*) INTO n FROM (SELECT txn_id FROM public.med_usage_by_lot GROUP BY 1 HAVING count(*) > 1) x;
    IF n > 0 THEN RAISE EXCEPTION 'C10 % duplicated usage rows', n; END IF;
    SELECT count(*) INTO n FROM (
        SELECT * FROM test.usage_before
        EXCEPT
        SELECT txn_id, txn_date, fiscal_year, lot_id, lot_number, ref_kind, category, medication_id,
               medication_name, generic_category, redwing_item_code, unit, bottle_size, qty_units,
               total_cost, shortfall_units, cost_provisional, location_id, location_name
          FROM public.med_usage_by_lot) x;
    IF n > 0 THEN RAISE EXCEPTION 'C10 % pre-existing usage row(s) changed', n; END IF;
    IF (SELECT count(*) FROM test.usage_before) <> 2 THEN
        RAISE EXCEPTION 'C10 fixture expected 2 pre-existing usage rows';
    END IF;
    RAISE NOTICE 'PASS C10 usage view ties to the ledger, once each, old rows unchanged';
END $t$;

-- ---------------------------------------------------------------- C11
-- The shape check holds even against a direct insert that skips the RPC.
DO $t$
DECLARE ok boolean := false; t uuid;
BEGIN
    SELECT txn_id INTO t FROM public.med_charges LIMIT 1;
    BEGIN
        INSERT INTO public.med_charges (charge_date, medication_id, location_id, qty_units, destination,
                                        lot_id, cost_center_id, category, txn_id)
        VALUES ('2026-10-06','b0000000-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000001',1,
                'cost_center','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000002',NULL,
                gen_random_uuid());
    EXCEPTION WHEN check_violation THEN ok := true;
    END;
    IF NOT ok THEN RAISE EXCEPTION 'C11 shape check let a cost-centre charge carry a lot'; END IF;
    ok := false;
    BEGIN
        DELETE FROM public.med_txns WHERE id = t;
    EXCEPTION WHEN foreign_key_violation THEN ok := true;
    END;
    IF NOT ok THEN RAISE EXCEPTION 'C11 a charge''s ledger row could be deleted out from under it'; END IF;
    RAISE NOTICE 'PASS C11 shape check and the ledger-row FK hold without the RPC';
END $t$;
