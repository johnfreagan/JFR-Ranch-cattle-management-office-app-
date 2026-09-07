-- =====================================================================
-- Lot transfers — dry run on TEST lots only
-- =====================================================================
-- Touches TEST_DOC1 and TEST_DOC2 and nothing else. It records two
-- transfers, checks every number, reverses both, and checks the books are
-- exactly where they started.
--
-- If ANY check fails the whole thing raises and rolls back, so a failure
-- leaves the database untouched. If it all passes, the reversals have
-- already cleaned up after themselves — so either way nothing is left
-- behind. You should see a run of NOTICE lines ending in ALL CHECKS PASSED.
--
-- The second transfer deliberately EMPTIES a pasture assignment, because
-- that is the case that reverses differently and the one that was a live
-- bug in delete_death_event: 3 head, a death of all 3, a reversal, and the
-- lot came back with 6.
--
-- Note: run from the SQL editor you are the service role, so RLS is
-- bypassed. This tests the LOGIC, not the permissions — those were checked
-- separately.
-- =====================================================================

DO $dry$
DECLARE
    d1 UUID; d2 UUID; front UUID; goat UUID;
    t1 UUID; t2 UUID;
    n INTEGER; m INTEGER; ok BOOLEAN;
    raised BOOLEAN;
BEGIN
    SELECT id INTO d1 FROM public.lots WHERE lot_number = 'TEST_DOC1';
    SELECT id INTO d2 FROM public.lots WHERE lot_number = 'TEST_DOC2';
    IF d1 IS NULL OR d2 IS NULL THEN
        RAISE EXCEPTION 'TEST_DOC1 / TEST_DOC2 not found — nothing safe to test against.';
    END IF;

    SELECT pasture_id INTO front FROM public.lot_pasture_assignments
     WHERE lot_id = d1 AND moved_out IS NULL;
    SELECT pasture_id INTO goat  FROM public.lot_pasture_assignments
     WHERE lot_id = d2 AND moved_out IS NULL;

    -- Baseline
    SELECT head_current INTO n FROM public.lot_status WHERE lot_id = d1;
    SELECT head_current INTO m FROM public.lot_status WHERE lot_id = d2;
    IF n <> 100 OR m <> 50 THEN
        RAISE EXCEPTION 'Expected the test lots at 100 and 50 head, found % and %. Aborting so nothing is disturbed.', n, m;
    END IF;
    RAISE NOTICE 'Baseline OK: TEST_DOC1 100 head, TEST_DOC2 50 head.';

    -- ---------------------------------------------------------------
    -- 1. A partial transfer: 20 of 100 head
    -- ---------------------------------------------------------------
    t1 := public.record_lot_transfer(
        p_source_lot_id  => d1,
        p_dest_lot_id    => d2,
        p_transfer_date  => public.ranch_today(),
        p_kind           => 'sort',
        p_lines          => jsonb_build_array(jsonb_build_object(
                                'from_pasture_id', front::text,
                                'to_pasture_id',   goat::text,
                                'head_count',      20)),
        p_basis_per_head => 1500.00,
        p_basis_total    => 30000.00,
        p_notes          => 'DRY RUN — delete me if you see this'
    );

    SELECT head_current INTO n FROM public.lot_status WHERE lot_id = d1;
    IF n <> 80 THEN RAISE EXCEPTION 'After a 20 head transfer out, TEST_DOC1 should hold 80, holds %.', n; END IF;
    SELECT head_current INTO m FROM public.lot_status WHERE lot_id = d2;
    IF m <> 70 THEN RAISE EXCEPTION 'After a 20 head transfer in, TEST_DOC2 should hold 70, holds %.', m; END IF;

    SELECT head_count INTO n FROM public.lot_pasture_assignments
     WHERE lot_id = d1 AND pasture_id = front AND moved_out IS NULL;
    IF n <> 80 THEN RAISE EXCEPTION 'Source assignment should hold 80, holds %.', n; END IF;
    SELECT head_count INTO m FROM public.lot_pasture_assignments
     WHERE lot_id = d2 AND pasture_id = goat AND moved_out IS NULL;
    IF m <> 70 THEN RAISE EXCEPTION 'Destination assignment should hold 70, holds %.', m; END IF;

    SELECT count(*) INTO n FROM public.lot_events
     WHERE source_record_id = t1 AND event_type IN ('transfer_in','transfer_out');
    IF n <> 2 THEN RAISE EXCEPTION 'Expected 2 head-math events, found %.', n; END IF;

    SELECT transferred_out_usd INTO n FROM public.lot_transfer_costs WHERE lot_id = d1;
    IF n <> 30000 THEN RAISE EXCEPTION 'TEST_DOC1 should show 30000 transferred out, shows %.', n; END IF;
    SELECT transferred_in_usd INTO m FROM public.lot_transfer_costs WHERE lot_id = d2;
    IF m <> 30000 THEN RAISE EXCEPTION 'TEST_DOC2 should show 30000 transferred in, shows %.', m; END IF;
    RAISE NOTICE '1. Partial transfer OK: 80 / 70 head, assignments correct, $30,000 moved.';

    -- ---------------------------------------------------------------
    -- 2. The guards
    -- ---------------------------------------------------------------
    raised := false;
    BEGIN
        PERFORM public.record_lot_transfer(d1, d2, DATE '2026-03-20', 'sort',
            jsonb_build_array(jsonb_build_object('from_pasture_id', front::text,
                'to_pasture_id', goat::text, 'head_count', 5)), 1500.00, 7500.00);
    EXCEPTION WHEN OTHERS THEN raised := true;
    END;
    IF NOT raised THEN RAISE EXCEPTION 'A date before the destination lot existed was ACCEPTED. That silently backdates head-days.'; END IF;

    raised := false;
    BEGIN
        PERFORM public.record_lot_transfer(d1, d2, public.ranch_today(), 'sort',
            jsonb_build_array(jsonb_build_object('from_pasture_id', front::text,
                'to_pasture_id', goat::text, 'head_count', 5)), 1500.00, 999.00);
    EXCEPTION WHEN OTHERS THEN raised := true;
    END;
    IF NOT raised THEN RAISE EXCEPTION 'A basis total that disagrees with head x rate was ACCEPTED.'; END IF;

    raised := false;
    BEGIN
        PERFORM public.record_lot_transfer(d1, d2, public.ranch_today(), 'sort',
            jsonb_build_array(jsonb_build_object('from_pasture_id', front::text,
                'to_pasture_id', goat::text, 'head_count', 500)), 1500.00, 750000.00);
    EXCEPTION WHEN OTHERS THEN raised := true;
    END;
    IF NOT raised THEN RAISE EXCEPTION 'Transferring more head than the pasture holds was ACCEPTED.'; END IF;

    raised := false;
    BEGIN
        PERFORM public.recompute_transfer_basis(t1, 1600.00, 32000.00);
    EXCEPTION WHEN OTHERS THEN raised := true;
    END;
    IF NOT raised THEN RAISE EXCEPTION 'recompute_transfer_basis ran without an owner role.'; END IF;
    RAISE NOTICE '2. Guards OK: bad date, bad basis, overdraw and non-owner recompute all refused.';

    -- ---------------------------------------------------------------
    -- 3. A transfer that EMPTIES the source assignment
    -- ---------------------------------------------------------------
    t2 := public.record_lot_transfer(
        p_source_lot_id  => d1,
        p_dest_lot_id    => d2,
        p_transfer_date  => public.ranch_today(),
        p_kind           => 'fold_in',
        p_lines          => jsonb_build_array(jsonb_build_object(
                                'from_pasture_id', front::text,
                                'to_pasture_id',   goat::text,
                                'head_count',      80)),
        p_basis_per_head => 1500.00,
        p_basis_total    => 120000.00,
        p_notes          => 'DRY RUN — empties the source'
    );

    SELECT head_current INTO n FROM public.lot_status WHERE lot_id = d1;
    IF n <> 0 THEN RAISE EXCEPTION 'TEST_DOC1 should be empty, holds %.', n; END IF;

    SELECT head_count INTO n FROM public.lot_pasture_assignments
     WHERE lot_id = d1 AND pasture_id = front AND moved_out IS NOT NULL;
    IF n IS NULL THEN RAISE EXCEPTION 'The emptied source assignment was not closed.'; END IF;
    IF n <> 80 THEN RAISE EXCEPTION 'A closed assignment must keep head_count intact (80), it reads %. Zeroing it makes the reversal restore nothing.', n; END IF;
    RAISE NOTICE '3. Emptying transfer OK: source at 0, assignment closed with head_count kept at 80.';

    -- ---------------------------------------------------------------
    -- 4. Reverse it — THE delete_death_event TRAP
    -- ---------------------------------------------------------------
    PERFORM public.delete_lot_transfer(t2);

    SELECT head_count INTO n FROM public.lot_pasture_assignments
     WHERE lot_id = d1 AND pasture_id = front AND moved_out IS NULL;
    IF n IS NULL THEN RAISE EXCEPTION 'The closed source assignment was not reopened.'; END IF;
    IF n = 160 THEN RAISE EXCEPTION 'THE TRAP: reopening added 80 head on top of the 80 already recorded. 80 expected, got 160.'; END IF;
    IF n <> 80 THEN RAISE EXCEPTION 'Reopened source assignment should hold 80, holds %.', n; END IF;

    SELECT head_current INTO n FROM public.lot_status WHERE lot_id = d1;
    SELECT head_current INTO m FROM public.lot_status WHERE lot_id = d2;
    IF n <> 80 OR m <> 70 THEN RAISE EXCEPTION 'After reversing, expected 80 / 70 head, found % / %.', n, m; END IF;
    RAISE NOTICE '4. Reversal of the emptying transfer OK: 80 head back, NOT 160.';

    -- ---------------------------------------------------------------
    -- 5. Reverse the first one and check we are exactly back
    -- ---------------------------------------------------------------
    PERFORM public.delete_lot_transfer(t1);

    SELECT head_current INTO n FROM public.lot_status WHERE lot_id = d1;
    SELECT head_current INTO m FROM public.lot_status WHERE lot_id = d2;
    IF n <> 100 OR m <> 50 THEN RAISE EXCEPTION 'Expected the books back at 100 / 50, found % / %.', n, m; END IF;

    SELECT head_count INTO n FROM public.lot_pasture_assignments
     WHERE lot_id = d1 AND pasture_id = front AND moved_out IS NULL;
    SELECT head_count INTO m FROM public.lot_pasture_assignments
     WHERE lot_id = d2 AND pasture_id = goat AND moved_out IS NULL;
    IF n <> 100 OR m <> 50 THEN RAISE EXCEPTION 'Assignments should be back at 100 / 50, found % / %.', n, m; END IF;

    SELECT count(*) INTO n FROM public.lot_transfers WHERE source_lot_id = d1 OR dest_lot_id = d1;
    IF n <> 0 THEN RAISE EXCEPTION '% transfer rows left behind.', n; END IF;

    SELECT count(*) INTO n FROM public.lot_events
     WHERE event_type IN ('transfer_in','transfer_out');
    IF n <> 0 THEN RAISE EXCEPTION '% transfer head-math events left behind.', n; END IF;

    SELECT count(*) INTO n FROM public.lot_transfer_costs WHERE lot_id IN (d1, d2);
    IF n <> 0 THEN RAISE EXCEPTION 'lot_transfer_costs still shows rows for the test lots.'; END IF;

    RAISE NOTICE '5. Full reversal OK: books exactly back at 100 / 50, nothing left behind.';
    RAISE NOTICE '-----------------------------------------------------------';
    RAISE NOTICE 'ALL CHECKS PASSED. Head math, cost, guards and both reversals.';
    RAISE NOTICE 'The test lots are exactly as they were.';
END
$dry$;
