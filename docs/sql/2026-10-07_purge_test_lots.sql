-- 2026-10-07. Purge the test lots from production (D44 reversed by John 2026-10-07;
-- plan and footprint in docs/test-lots-cleanup.md).
--
-- Removes TEST_DOC1, TEST_DOC2 and Test-1 (lots.is_test) and every row that hangs off them:
--   doctoring_events 16 (+ doctoring_event_meds 22 by cascade), lot_events 2 (deaths),
--   lot_tags 1,000, lot_pasture_assignments 8, pasture_head_log (4 now, plus the 'removed'
--   rows the assignment delete trigger writes), delivery_receipts 3 (+ load_out_destinations 4
--   by cascade), invoices 3, lots 3.
--
-- Not touched here (separate decisions): ue_lot_crosswalk rows 10-12 (synced from outside the
-- app, match_type 'exclude'), the frozen _proc_cost_snapshot_20261002 table, and the four global
-- field_protocols noted 'Seeded for testing' (they are live crew defaults, lot_id NULL).
--
-- Safety, all inside one transaction:
--   1. Refuses to run unless the test footprint is exactly the counts above. Anything new
--      pointing at a test lot (a sale, feed, a med draw, a transfer) aborts it.
--   2. Fingerprints every row that is NOT a test row in each touched table (md5 of the rows),
--      plus the row count of every other public table and the D8 tie-out for real lots.
--   3. Deletes child to parent.
--   4. Re-fingerprints. Any difference in real rows, any other table's count, or any test row
--      left behind raises, and the whole thing rolls back.
-- The test rows themselves are exported to JSON before this runs (kept off the public repo).
-- Idempotent: a second run finds no test lots and stops with a notice.

begin;

do $$
declare
    v_lots   uuid[];
    v_n      bigint;
    v_tbl    text;
    v_before jsonb := '{}'::jsonb;
    v_after  jsonb := '{}'::jsonb;
    v_counts_before jsonb := '{}'::jsonb;
    v_counts_after  jsonb := '{}'::jsonb;
    v_tie_before text;
    v_tie_after  text;
begin
    select array_agg(id order by lot_number) into v_lots from public.lots where is_test;
    if v_lots is null then
        raise notice 'No test lots left. Nothing to do.';
        return;
    end if;

    -- 1. The footprint must be exactly what was reviewed.
    if (select string_agg(lot_number, ',' order by lot_number) from public.lots where is_test)
       <> 'TEST_DOC1,TEST_DOC2,Test-1' then
        raise exception 'Test lots are not the three reviewed (TEST_DOC1, TEST_DOC2, Test-1). Aborting.';
    end if;
    if exists (select 1 from public.lots where lot_number ~* '^test' and not is_test) then
        raise exception 'A lot named TEST... is not flagged is_test. Aborting.';
    end if;

    select count(*) into v_n from public.doctoring_events where lot_id = any(v_lots);
    if v_n <> 16 then raise exception 'doctoring_events: expected 16, found %', v_n; end if;
    select count(*) into v_n from public.doctoring_event_meds m join public.doctoring_events d on d.id = m.doctoring_event_id where d.lot_id = any(v_lots);
    if v_n <> 22 then raise exception 'doctoring_event_meds: expected 22, found %', v_n; end if;
    select count(*) into v_n from public.lot_events where lot_id = any(v_lots);
    if v_n <> 2 then raise exception 'lot_events: expected 2, found %', v_n; end if;
    select count(*) into v_n from public.lot_tags where lot_id = any(v_lots);
    if v_n <> 1000 then raise exception 'lot_tags: expected 1000, found %', v_n; end if;
    select count(*) into v_n from public.lot_pasture_assignments where lot_id = any(v_lots);
    if v_n <> 8 then raise exception 'lot_pasture_assignments: expected 8, found %', v_n; end if;
    select count(*) into v_n from public.delivery_receipts where lot_id = any(v_lots);
    if v_n <> 3 then raise exception 'delivery_receipts: expected 3, found %', v_n; end if;
    select count(*) into v_n from public.load_out_destinations where receipt_id in (select id from public.delivery_receipts where lot_id = any(v_lots));
    if v_n <> 4 then raise exception 'load_out_destinations: expected 4, found %', v_n; end if;
    select count(*) into v_n from public.invoices where lot_id = any(v_lots);
    if v_n <> 3 then raise exception 'invoices: expected 3, found %', v_n; end if;
    -- A test receipt or invoice must not be shared with a real lot.
    if exists (select 1 from public.delivery_receipts where invoice_id in (select id from public.invoices where lot_id = any(v_lots)) and not (lot_id = any(v_lots)))
       or exists (select 1 from public.lot_tags where delivery_receipt_id in (select id from public.delivery_receipts where lot_id = any(v_lots)) and not (lot_id = any(v_lots))) then
        raise exception 'A test receipt or invoice is linked to a real lot. Aborting.';
    end if;
    -- Everything else that can point at a lot must be empty for the test lots.
    if exists (select 1 from public.sales where lot_id = any(v_lots))
       or exists (select 1 from public.weights where lot_id = any(v_lots))
       or exists (select 1 from public.feed_usage where lot_id = any(v_lots))
       or exists (select 1 from public.feed_drop_lots where lot_id = any(v_lots))
       or exists (select 1 from public.shipment_load_lines where lot_id = any(v_lots))
       or exists (select 1 from public.lot_transfers where source_lot_id = any(v_lots) or dest_lot_id = any(v_lots))
       or exists (select 1 from public.position_lot_links where lot_id = any(v_lots))
       or exists (select 1 from public.pending_field_entries where lot_id = any(v_lots))
       or exists (select 1 from public.feed_pen_ledger where pen_lot_id = any(v_lots) or source_lot_id = any(v_lots))
       or exists (select 1 from public.feed_pen_removals where pen_lot_id = any(v_lots))
       or exists (select 1 from public.feed_pen_removal_lines where source_lot_id = any(v_lots))
       or exists (select 1 from public.lots where parent_lot_id = any(v_lots))
       or exists (select 1 from public.lot_movements where lot_id = any(v_lots))
       or exists (select 1 from public.lot_budgets where lot_id = any(v_lots))
       or exists (select 1 from public.lot_adg_phases where lot_id = any(v_lots))
       or exists (select 1 from public.lot_assumption_history where lot_id = any(v_lots))
       or exists (select 1 from public.lot_health_overrides where lot_id = any(v_lots))
       or exists (select 1 from public.health_estimated_loads where lot_id = any(v_lots))
       or exists (select 1 from public.field_protocols where lot_id = any(v_lots)) then
        raise exception 'A test lot has rows beyond the reviewed footprint (sale, weight, feed, transfer, position, budget, ...). Aborting.';
    end if;

    -- 2. Fingerprint the real rows in every touched table.
    v_before := jsonb_build_object(
        'lots',                    (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.lots t where not (t.id = any(v_lots))),
        'doctoring_events',        (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.doctoring_events t where t.lot_id is null or not (t.lot_id = any(v_lots))),
        'doctoring_event_meds',    (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.doctoring_event_meds t where t.doctoring_event_id is null or t.doctoring_event_id not in (select id from public.doctoring_events where lot_id = any(v_lots))),
        'lot_events',              (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.lot_events t where t.lot_id is null or not (t.lot_id = any(v_lots))),
        'lot_tags',                (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.lot_tags t where t.lot_id is null or not (t.lot_id = any(v_lots))),
        'lot_pasture_assignments', (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.lot_pasture_assignments t where t.lot_id is null or not (t.lot_id = any(v_lots))),
        'pasture_head_log',        (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.pasture_head_log t where t.lot_id is null or not (t.lot_id = any(v_lots))),
        'delivery_receipts',       (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.delivery_receipts t where t.lot_id is null or not (t.lot_id = any(v_lots))),
        'load_out_destinations',   (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.load_out_destinations t where t.receipt_id is null or t.receipt_id not in (select id from public.delivery_receipts where lot_id = any(v_lots))),
        'invoices',                (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.invoices t where t.lot_id is null or not (t.lot_id = any(v_lots))),
        'feed_pen_removals',       (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.feed_pen_removals t));

    -- Row count of every other public table: a cascade or trigger reaching anything else shows here.
    for v_tbl in
        select c.relname from pg_class c
         where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
           and c.relname not in ('lots','doctoring_events','doctoring_event_meds','lot_events','lot_tags',
                                 'lot_pasture_assignments','pasture_head_log','delivery_receipts',
                                 'load_out_destinations','invoices')
         order by 1
    loop
        execute format('select count(*) from public.%I', v_tbl) into v_n;
        v_counts_before := v_counts_before || jsonb_build_object(v_tbl, v_n);
    end loop;

    -- D8 tie-out for real lots (the view already skips is_test lots).
    select md5(coalesce(string_agg(t::text, '|' order by t::text), '')) into v_tie_before from public.lot_head_tieout t;

    -- 3. Delete, child to parent.
    delete from public.doctoring_events where lot_id = any(v_lots);           -- doctoring_event_meds cascade
    delete from public.lot_events       where lot_id = any(v_lots);           -- death triggers un-retire test tags; tags go next
    delete from public.lot_tags         where lot_id = any(v_lots);
    delete from public.lot_pasture_assignments where lot_id = any(v_lots);    -- trigger writes 'removed' log rows
    delete from public.pasture_head_log where lot_id = any(v_lots);           -- the 4 old rows and those just written
    delete from public.delivery_receipts where lot_id = any(v_lots);          -- load_out_destinations cascade
    delete from public.invoices         where lot_id = any(v_lots);
    delete from public.lots             where id = any(v_lots);

    -- 4. Prove it.
    v_after := jsonb_build_object(
        'lots',                    (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.lots t),
        'doctoring_events',        (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.doctoring_events t),
        'doctoring_event_meds',    (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.doctoring_event_meds t),
        'lot_events',              (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.lot_events t),
        'lot_tags',                (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.lot_tags t),
        'lot_pasture_assignments', (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.lot_pasture_assignments t),
        'pasture_head_log',        (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.pasture_head_log t),
        'delivery_receipts',       (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.delivery_receipts t),
        'load_out_destinations',   (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.load_out_destinations t),
        'invoices',                (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.invoices t),
        'feed_pen_removals',       (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.feed_pen_removals t));
    if v_after <> v_before then
        raise exception 'Real rows changed. Before % After %. Rolled back.', v_before, v_after;
    end if;

    for v_tbl in select key from jsonb_each(v_counts_before) loop
        execute format('select count(*) from public.%I', v_tbl) into v_n;
        v_counts_after := v_counts_after || jsonb_build_object(v_tbl, v_n);
    end loop;
    if v_counts_after <> v_counts_before then
        raise exception 'Another table changed row count. Before % After %. Rolled back.', v_counts_before, v_counts_after;
    end if;

    select md5(coalesce(string_agg(t::text, '|' order by t::text), '')) into v_tie_after from public.lot_head_tieout t;
    if v_tie_after is distinct from v_tie_before then
        raise exception 'D8 tie-out for real lots changed. Rolled back.';
    end if;

    if exists (select 1 from public.lots where is_test or lot_number ~* '^test') then
        raise exception 'A test lot is still there. Rolled back.';
    end if;

    raise notice 'Purged 3 test lots and their rows. Real rows, other tables and the D8 tie-out unchanged.';
end
$$;

commit;
