-- Office reversal suite for 2026-10-09c_med_office_reversal.sql. Runs on a
-- database built by scripts/med-charge-harness/build-base.sh (the med
-- fixture, the med migration, the direct-charge fixture and migration) with
-- 2026-10-09c applied on top. Every block raises on failure and prints PASS.
-- Writes run as office_user / crew_user / acct_user (not superusers) so RLS
-- applies; test.role stands in for the profile row.
\set ON_ERROR_STOP 0
SET client_min_messages = notice;
SET test.uid   = '00000000-0000-0000-0000-0000000000b1';
SET test.today = '2026-10-09';

-- Seed, as the owner: three treatments on 61X with real draws off Charge
-- Barn (Draxxin, $2/mL), one load out with a processing draw, one charge.
SET ROLE office_user;
SET test.role = 'owner';
INSERT INTO public.doctoring_events (id, lot_id, event_date) VALUES
  ('d1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', '2026-10-06'),
  ('d1000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002', '2026-10-06'),
  ('d1000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002', '2026-10-03');
INSERT INTO public.doctoring_event_meds (doctoring_event_id, position, medication_id, dose_cc, cost) VALUES
  ('d1000000-0000-0000-0000-000000000001', 1, 'b0000000-0000-0000-0000-000000000002', 10, 20),
  ('d1000000-0000-0000-0000-000000000002', 1, 'b0000000-0000-0000-0000-000000000002', 5, 10),
  ('d1000000-0000-0000-0000-000000000003', 1, 'b0000000-0000-0000-0000-000000000002', 7, 14);
SELECT public.med_consume('b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 10, 'usage', 'treatment', 'doctoring_event', 'd1000000-0000-0000-0000-000000000001', '2026-10-06');
SELECT public.med_consume('b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 5,  'usage', 'treatment', 'doctoring_event', 'd1000000-0000-0000-0000-000000000002', '2026-10-06');
SELECT public.med_consume('b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 7,  'usage', 'treatment', 'doctoring_event', 'd1000000-0000-0000-0000-000000000003', '2026-10-03');
INSERT INTO public.delivery_receipts (id, lot_id, receipt_date, head_count) VALUES
  ('dd000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', '2026-10-06', 10);
SELECT public.med_consume('b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 20, 'usage', 'processing', 'delivery_receipt', 'dd000000-0000-0000-0000-000000000001', '2026-10-06');
SELECT set_config('test.charge', (public.post_med_charge('2026-10-06', 'b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 3, 'cost_center', NULL, 'c0000000-0000-0000-0000-000000000002', NULL, NULL))->>'charge_id', false);
SELECT set_config('test.charge_early', (public.post_med_charge('2026-10-03', 'b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 2, 'cost_center', NULL, 'c0000000-0000-0000-0000-000000000002', NULL, NULL))->>'charge_id', false);
-- 500 - 10 - 5 - 7 - 20 - 3 - 2 = 453 left on the Draxxin layer.

-- ---------------------------------------------------------------- R1
-- Office voids a treatment: the units go back, the ledger row, the event
-- and its med lines are gone.
SET test.role = 'office';
DO $t$
DECLARE v jsonb; q numeric;
BEGIN
    v := public.med_void_doctoring(ARRAY['d1000000-0000-0000-0000-000000000001']::uuid[]);
    IF (v->>'events_removed')::int <> 1 OR (v->>'draws_reversed')::int <> 1 OR (v->>'restored_units')::numeric <> 10 THEN
        RAISE EXCEPTION 'R1 result %', v;
    END IF;
    SELECT qty_remaining INTO q FROM public.med_purchase_lines WHERE id = '90000000-0000-0000-0000-000000000003';
    IF q <> 463 THEN RAISE EXCEPTION 'R1 layer %, expected 463', q; END IF;
    IF EXISTS (SELECT 1 FROM public.med_txns WHERE ref_id = 'd1000000-0000-0000-0000-000000000001')
       OR EXISTS (SELECT 1 FROM public.doctoring_events WHERE id = 'd1000000-0000-0000-0000-000000000001')
       OR EXISTS (SELECT 1 FROM public.doctoring_event_meds WHERE doctoring_event_id = 'd1000000-0000-0000-0000-000000000001') THEN
        RAISE EXCEPTION 'R1 left a trace';
    END IF;
    RAISE NOTICE 'PASS R1 office void puts the units back and removes the draw, the event and its meds';
END $t$;

-- ---------------------------------------------------------------- R2
-- The month closes: a void that would reach into it is refused whole.
RESET ROLE;
INSERT INTO public.med_counts (location_id, count_date, status, is_opening)
VALUES ('e0000000-0000-0000-0000-000000000001', '2026-10-05', 'posted', false);
SET ROLE office_user;
DO $t$
DECLARE ok boolean := false; msg text; q numeric;
BEGIN
    BEGIN
        PERFORM public.med_void_doctoring(ARRAY['d1000000-0000-0000-0000-000000000002',
                                                'd1000000-0000-0000-0000-000000000003']::uuid[]);
    EXCEPTION WHEN check_violation THEN ok := true; GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT;
    END;
    IF NOT ok OR msg NOT LIKE '%counted and closed through 2026-10-05%' THEN RAISE EXCEPTION 'R2 not refused: %', msg; END IF;
    SELECT qty_remaining INTO q FROM public.med_purchase_lines WHERE id = '90000000-0000-0000-0000-000000000003';
    IF q <> 463 OR (SELECT count(*) FROM public.doctoring_events WHERE id IN ('d1000000-0000-0000-0000-000000000002','d1000000-0000-0000-0000-000000000003')) <> 2 THEN
        RAISE EXCEPTION 'R2 a refused void changed something (layer %)', q;
    END IF;
    RAISE NOTICE 'PASS R2 a void reaching into a closed month is refused and changes nothing';
END $t$;

-- ---------------------------------------------------------------- R3
-- The edit helper: office cannot; the owner gets open draws back and the
-- closed-month draw kept.
DO $t$
DECLARE ok boolean := false;
BEGIN
    BEGIN PERFORM public.med_reverse_doctoring_for_edit('d1000000-0000-0000-0000-000000000002');
    EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
    IF NOT ok THEN RAISE EXCEPTION 'R3 office could run the edit helper'; END IF;
    RAISE NOTICE 'PASS R3a office cannot use the owner edit helper';
END $t$;
SET test.role = 'owner';
DO $t$
DECLARE v jsonb;
BEGIN
    v := public.med_reverse_doctoring_for_edit('d1000000-0000-0000-0000-000000000002');
    IF (v->>'draws_reversed')::int <> 1 OR (v->>'draws_kept_closed_month')::int <> 0 THEN RAISE EXCEPTION 'R3 open %', v; END IF;
    v := public.med_reverse_doctoring_for_edit('d1000000-0000-0000-0000-000000000003');
    IF (v->>'draws_reversed')::int <> 0 OR (v->>'draws_kept_closed_month')::int <> 1 THEN RAISE EXCEPTION 'R3 closed %', v; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.med_txns WHERE ref_id = 'd1000000-0000-0000-0000-000000000003') THEN
        RAISE EXCEPTION 'R3 the closed-month draw was removed';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.doctoring_events WHERE id = 'd1000000-0000-0000-0000-000000000002') THEN
        RAISE EXCEPTION 'R3 the edit helper deleted the event';
    END IF;
    RAISE NOTICE 'PASS R3b owner edit reverses open draws, keeps the closed-month draw, keeps the event';
END $t$;

-- ---------------------------------------------------------------- R4
-- Office re-saves a load out: its draw comes off cleanly.
SET test.role = 'office';
DO $t$
DECLARE v jsonb;
BEGIN
    v := public.med_processing_reverse('dd000000-0000-0000-0000-000000000001');
    IF (v->>'lines_reversed')::int <> 1 OR (v->>'lines_locked')::int <> 0 THEN RAISE EXCEPTION 'R4 %', v; END IF;
    IF EXISTS (SELECT 1 FROM public.med_txns WHERE ref_id = 'dd000000-0000-0000-0000-000000000001') THEN
        RAISE EXCEPTION 'R4 the ledger row survived';
    END IF;
    RAISE NOTICE 'PASS R4 office load-out reversal removes the ledger row';
END $t$;

-- ---------------------------------------------------------------- R5
-- Office undoes a charge in an open month; a charge in the closed month is
-- refused.
DO $t$
DECLARE v jsonb; ok boolean := false;
BEGIN
    v := public.delete_med_charge(current_setting('test.charge')::uuid);
    IF (v->>'restored_units')::numeric <> 3 THEN RAISE EXCEPTION 'R5 %', v; END IF;
    IF EXISTS (SELECT 1 FROM public.med_charges WHERE id = current_setting('test.charge')::uuid)
       OR EXISTS (SELECT 1 FROM public.med_txns WHERE id = (v->>'txn_id')::uuid) THEN
        RAISE EXCEPTION 'R5 undo left a trace';
    END IF;
    BEGIN PERFORM public.delete_med_charge(current_setting('test.charge_early')::uuid);
    EXCEPTION WHEN check_violation THEN ok := true; END;
    IF NOT ok THEN RAISE EXCEPTION 'R5 closed-month undo allowed'; END IF;
    RAISE NOTICE 'PASS R5 office undoes a charge; not one in a closed month';
END $t$;

-- ---------------------------------------------------------------- R6
-- The layer adds back to the unit: 500 less what is still drawn.
DO $t$
DECLARE q numeric; drawn numeric;
BEGIN
    SELECT qty_remaining INTO q FROM public.med_purchase_lines WHERE id = '90000000-0000-0000-0000-000000000003';
    SELECT coalesce(sum(l.qty_units), 0) INTO drawn FROM public.med_txn_layers l
      WHERE l.purchase_line_id = '90000000-0000-0000-0000-000000000003';
    IF q + drawn <> 500 THEN RAISE EXCEPTION 'R6 layer % + drawn % <> 500', q, drawn; END IF;
    IF q <> 491 THEN RAISE EXCEPTION 'R6 layer %, expected 491 (7 closed-month treatment + 2 closed-month charge still drawn)', q; END IF;
    RAISE NOTICE 'PASS R6 the layer ties to the unit: % on the shelf + % still drawn = 500', q, drawn;
END $t$;

-- ---------------------------------------------------------------- R7
-- Office still cannot delete a ledger row directly, and crew and the
-- accountant cannot use any of the functions.
DO $t$
DECLARE n integer;
BEGIN
    DELETE FROM public.med_txns WHERE ref_id = 'd1000000-0000-0000-0000-000000000003';
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n <> 0 THEN RAISE EXCEPTION 'R7 office deleted % ledger row(s) directly', n; END IF;
    RAISE NOTICE 'PASS R7a a direct office DELETE on med_txns still removes nothing';
END $t$;
SET ROLE crew_user;
SET test.role = 'crew';
DO $t$
DECLARE k integer := 0;
BEGIN
    BEGIN PERFORM public.med_void_doctoring(ARRAY['d1000000-0000-0000-0000-000000000002']::uuid[]); EXCEPTION WHEN insufficient_privilege THEN k := k + 1; END;
    BEGIN PERFORM public.med_processing_reverse('dd000000-0000-0000-0000-000000000001'); EXCEPTION WHEN insufficient_privilege THEN k := k + 1; END;
    BEGIN PERFORM public.delete_med_charge(current_setting('test.charge_early')::uuid); EXCEPTION WHEN insufficient_privilege THEN k := k + 1; END;
    IF k <> 3 THEN RAISE EXCEPTION 'R7 crew got through % of 3', 3 - k; END IF;
    RAISE NOTICE 'PASS R7b crew refused by all three';
END $t$;
SET ROLE acct_user;
SET test.role = 'accountant';
DO $t$
DECLARE k integer := 0;
BEGIN
    BEGIN PERFORM public.med_void_doctoring(ARRAY['d1000000-0000-0000-0000-000000000002']::uuid[]); EXCEPTION WHEN insufficient_privilege THEN k := k + 1; END;
    BEGIN PERFORM public.delete_med_charge(current_setting('test.charge_early')::uuid); EXCEPTION WHEN insufficient_privilege THEN k := k + 1; END;
    IF k <> 2 THEN RAISE EXCEPTION 'R7 accountant got through'; END IF;
    RAISE NOTICE 'PASS R7c accountant refused';
END $t$;

-- ---------------------------------------------------------------- R8
-- A void of a treatment with no draw at all still removes the event.
SET ROLE office_user;
SET test.role = 'office';
DO $t$
DECLARE v jsonb;
BEGIN
    INSERT INTO public.doctoring_events (id, lot_id, event_date) VALUES
      ('d1000000-0000-0000-0000-000000000009', 'a0000000-0000-0000-0000-000000000002', '2026-10-08');
    v := public.med_void_doctoring(ARRAY['d1000000-0000-0000-0000-000000000009']::uuid[]);
    IF (v->>'events_removed')::int <> 1 OR (v->>'draws_reversed')::int <> 0 THEN RAISE EXCEPTION 'R8 %', v; END IF;
    RAISE NOTICE 'PASS R8 a treatment with no draw voids cleanly';
END $t$;
RESET ROLE;
