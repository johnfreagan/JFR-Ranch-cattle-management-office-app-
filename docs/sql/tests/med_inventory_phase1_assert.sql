-- =====================================================================
-- Medicine inventory phase 1 - assertions
-- =====================================================================
-- Run AFTER the fixture and the migration. Raises on the first failure,
-- so "no output but the final NOTICE" is the pass condition.
-- =====================================================================
-- Notices are the pass signal here; do not raise client_min_messages.
SET client_min_messages = notice;

DO $t$
DECLARE
    v_loc     uuid;
    v_res     jsonb;
    v_n       numeric;
    v_count   uuid := '44444444-0000-0000-0000-000000000001';
BEGIN
    SELECT id INTO v_loc FROM public.med_stock_locations WHERE kind = 'ranch';

    -- --- Two layers of the same drug at DIFFERENT costs, older cheaper.
    INSERT INTO public.med_purchases (id, purchase_date, vendor, invoice_number, location_id, invoice_total)
    VALUES ('22222222-0000-0000-0000-000000000001','2026-08-01','Vet Supply','INV-1',v_loc,450.00);
    INSERT INTO public.med_purchase_lines (purchase_id, medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
    VALUES ('22222222-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000001',v_loc,1,500,'mL',0.90,500,'2026-08-01');

    INSERT INTO public.med_purchases (id, purchase_date, vendor, invoice_number, location_id, invoice_total)
    VALUES ('22222222-0000-0000-0000-000000000002','2026-08-20','Vet Supply','INV-2',v_loc,1100.00);
    INSERT INTO public.med_purchase_lines (purchase_id, medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
    VALUES ('22222222-0000-0000-0000-000000000002','11111111-0000-0000-0000-000000000001',v_loc,2,500,'mL',1.10,1000,'2026-08-20');

    -- 1. On hand and value.
    SELECT qty_units INTO v_n FROM public.med_on_hand
     WHERE medication_name='Draxxin' AND location_kind='ranch';
    IF v_n <> 1500 THEN RAISE EXCEPTION 'T1 on-hand units: expected 1500, got %', v_n; END IF;

    SELECT value_fifo INTO v_n FROM public.med_on_hand
     WHERE medication_name='Draxxin' AND location_kind='ranch';
    IF v_n <> 1550.00 THEN RAISE EXCEPTION 'T1 on-hand value: expected 1550.00, got %', v_n; END IF;

    -- 2. Inserting a layer wrote its own ledger row (the trigger).
    SELECT count(*) INTO v_n FROM public.med_txns
     WHERE txn_type='purchase' AND medication_id='11111111-0000-0000-0000-000000000001';
    IF v_n <> 2 THEN RAISE EXCEPTION 'T2 ledger rows: expected 2 purchase txns, got %', v_n; END IF;

    -- 3. Consuming across a layer boundary costs at BOTH layers' prices.
    --    500 @ 0.90 + 200 @ 1.10 = 670.00, not 700 @ anything.
    v_res := public.med_consume('11111111-0000-0000-0000-000000000001'::uuid, v_loc, 700,
             'usage','treatment','doctoring_event','33333333-0000-0000-0000-000000000001'::uuid,'2026-08-25');
    IF (v_res->>'total_cost')::numeric <> 670.00 THEN
        RAISE EXCEPTION 'T3 FIFO cost across layers: expected 670.00, got %', v_res->>'total_cost';
    END IF;
    IF (v_res->>'shortfall_units')::numeric <> 0 THEN
        RAISE EXCEPTION 'T3 shortfall: expected 0, got %', v_res->>'shortfall_units';
    END IF;

    -- 4. It drained the OLDEST layer, not the cheapest or the newest.
    SELECT qty_remaining INTO v_n FROM public.med_purchase_lines
     WHERE medication_id='11111111-0000-0000-0000-000000000001' AND received_date='2026-08-01';
    IF v_n <> 0 THEN RAISE EXCEPTION 'T4 FIFO order: oldest layer should be empty, has %', v_n; END IF;

    -- 5. Reversal restores EXACTLY the layers that were drawn on. This is
    --    the delete_death_event trap: a reversal that recomputes, or that
    --    adds back on top of a restore, double-counts.
    PERFORM public.med_reverse_txn((SELECT id FROM public.med_txns WHERE ref_kind='doctoring_event'));
    SELECT qty_remaining INTO v_n FROM public.med_purchase_lines
     WHERE medication_id='11111111-0000-0000-0000-000000000001' AND received_date='2026-08-01';
    IF v_n <> 500 THEN RAISE EXCEPTION 'T5 reversal (old layer): expected 500, got %', v_n; END IF;
    SELECT qty_remaining INTO v_n FROM public.med_purchase_lines
     WHERE medication_id='11111111-0000-0000-0000-000000000001' AND received_date='2026-08-20';
    IF v_n <> 1000 THEN RAISE EXCEPTION 'T5 reversal (new layer): expected 1000, got %', v_n; END IF;

    -- 6. Using stock that is not there must NOT fail. Animal health data
    --    does not get lost to a bookkeeping gap.
    v_res := public.med_consume('11111111-0000-0000-0000-000000000002'::uuid, v_loc, 40,
             'usage','treatment','doctoring_event','33333333-0000-0000-0000-000000000009'::uuid,'2026-08-26');
    IF (v_res->>'shortfall_units')::numeric <> 40 THEN
        RAISE EXCEPTION 'T6 shortfall: expected 40, got %', v_res->>'shortfall_units';
    END IF;

    -- 7. A count. Short 100 on Draxxin, 250 found of Ultrachoice, Valcor
    --    left BLANK - blank means not counted, never zero.
    INSERT INTO public.med_counts (id, count_date, location_id, counted_by)
    VALUES (v_count,'2026-08-31',v_loc,'test');
    INSERT INTO public.med_count_lines (count_id, medication_id, full_bottles, open_units, bottle_size, counted_units)
    VALUES (v_count,'11111111-0000-0000-0000-000000000001',2,400,500,1400);
    INSERT INTO public.med_count_lines (count_id, medication_id, full_bottles, open_units, bottle_size, counted_units, unit_cost)
    VALUES (v_count,'11111111-0000-0000-0000-000000000003',1,0,250,250,0.75948);
    INSERT INTO public.med_count_lines (count_id, medication_id, counted_units)
    VALUES (v_count,'11111111-0000-0000-0000-000000000002',NULL);

    v_res := public.med_post_count(v_count);

    -- Shrink is valued off the layers it actually came from - oldest
    -- first, same convention usage is costed on. 100 @ 0.90 = 90.00.
    IF (v_res->>'shrink_value')::numeric <> 90.00 THEN
        RAISE EXCEPTION 'T7 shrink value: expected 90.00 (FIFO off the oldest layer), got %', v_res->>'shrink_value';
    END IF;

    -- 8. The blank line touched nothing.
    SELECT count(*) INTO v_n FROM public.med_txns
     WHERE medication_id='11111111-0000-0000-0000-000000000002' AND txn_type='adjustment';
    IF v_n <> 0 THEN RAISE EXCEPTION 'T8 blank count line wrote % adjustment(s); it must write none', v_n; END IF;

    -- 9. A posted count cannot post again.
    BEGIN
        PERFORM public.med_post_count(v_count);
        RAISE EXCEPTION 'T9 double post was allowed';
    EXCEPTION WHEN others THEN
        IF SQLERRM LIKE 'T9%' THEN RAISE; END IF;
    END;

    -- 10. A count that finds an UNPRICED medication over must refuse
    --     rather than book a zero-cost layer that prices every future
    --     draw off it at nothing.
    INSERT INTO public.med_counts (id, count_date, location_id, counted_by)
    VALUES ('44444444-0000-0000-0000-000000000002','2026-09-01',v_loc,'test');
    INSERT INTO public.med_count_lines (count_id, medication_id, counted_units)
    VALUES ('44444444-0000-0000-0000-000000000002','11111111-0000-0000-0000-000000000004',10);
    BEGIN
        PERFORM public.med_post_count('44444444-0000-0000-0000-000000000002');
        RAISE EXCEPTION 'T10 unpriced medication was booked instead of refused';
    EXCEPTION WHEN others THEN
        IF SQLERRM LIKE 'T10%' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'med_inventory phase 1: behaviour assertions passed.';
END
$t$;


-- --- Reporting identities. These are separate because they are the ones
-- --- that quietly rot: a report that stops tying to the shelf is worse
-- --- than no report, because somebody acts on it.
DO $r$
DECLARE
    v_bad int;
BEGIN
    -- beginning + purchases + opening - used + adjustments + uncovered = ending
    SELECT count(*) INTO v_bad FROM public.med_roll_forward
     WHERE ending_units <> beginning_units + purchased_units + opening_units
                           - used_units + adjustment_units + uncovered_units;
    IF v_bad > 0 THEN RAISE EXCEPTION 'Roll-forward UNIT identity broken on % row(s)', v_bad; END IF;

    SELECT count(*) INTO v_bad FROM public.med_roll_forward
     WHERE round(ending_value,2) <> round(beginning_value + purchased_value + opening_value
                           - used_value + adjustment_value + uncovered_value, 2);
    IF v_bad > 0 THEN RAISE EXCEPTION 'Roll-forward VALUE identity broken on % row(s)', v_bad; END IF;

    -- The latest ending balance must equal what the shelf actually holds.
    SELECT count(*) INTO v_bad
      FROM (SELECT DISTINCT ON (medication_id, location_id)
                   medication_id, location_id, ending_units, ending_value
              FROM public.med_roll_forward
             ORDER BY medication_id, location_id, period_month DESC) r
      JOIN public.med_on_hand o
        ON o.medication_id = r.medication_id AND o.location_id = r.location_id
     WHERE r.ending_units <> o.qty_units OR round(r.ending_value,2) <> o.value_fifo;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'Roll-forward ending disagrees with med_on_hand on % row(s)', v_bad;
    END IF;

    -- Nothing here is readable without logging in. The publishable key is
    -- embedded in index.html, so anything granted to anon is public.
    SELECT count(*) INTO v_bad
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname LIKE 'med\_%'
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad > 0 THEN RAISE EXCEPTION '% med_* object(s) readable by anon', v_bad; END IF;

    RAISE NOTICE 'med_inventory phase 1: reporting identities and grants passed.';
END
$r$;
