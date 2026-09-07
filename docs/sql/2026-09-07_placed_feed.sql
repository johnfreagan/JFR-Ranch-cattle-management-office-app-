-- =====================================================================
-- Feed placed before the cattle: name the lot, charge it on arrival
-- (2026-09-07, John: "This generally happens when receiving a new lot")
-- =====================================================================
-- Filling a trap ahead of a new lot used to do one of two wrong things:
-- the pounds were split over whatever OTHER lots that load fed, or - if the
-- whole load went to empty traps - posting refused outright and feed stopped
-- reaching the books.
--
-- The rule now: feed always leaves the bay on the day it left, costed at the
-- layer it came off. If the books show no cattle in that pasture, the usage
-- is booked to the PASTURE (feed_usage already allows that) instead of being
-- handed to somebody else's cattle. When the lot lands, claim_placed_feed()
-- moves it to that lot dated the lot's FIRST DAY WITH CATTLE - they cannot
-- eat on a day they were not there, and cost of gain divides by head-days.
--
-- Which lot? The one named when the feeder was called (bunk_reads.for_lot_id
-- -> feed_drops.for_lot_id). If nobody named one, the first lot to arrive in
-- that pasture after the delivery claims it. If neither exists it stays on
-- the pasture and shows on Needs Attention until somebody decides.
--
-- Apply in the Supabase SQL editor. Idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The lot a feeder is being filled for
-- ---------------------------------------------------------------------
ALTER TABLE public.bunk_reads
    ADD COLUMN IF NOT EXISTS for_lot_id uuid REFERENCES public.lots(id);
ALTER TABLE public.feed_drops
    ADD COLUMN IF NOT EXISTS for_lot_id uuid REFERENCES public.lots(id);

COMMENT ON COLUMN public.bunk_reads.for_lot_id IS
    'Filling this feeder for a lot that is not standing there yet (a trap before receiving). Copied to the drop when the load starts.';
COMMENT ON COLUMN public.feed_drops.for_lot_id IS
    'The lot this drop was placed for when the pasture had no cattle. claim_placed_feed() charges the feed to it on its first day with cattle.';

-- ---------------------------------------------------------------------
-- 2. The load guard learns the RPC bypass
-- ---------------------------------------------------------------------
-- claim_placed_feed() names the lot on a drop of an already posted load.
-- Same bypass the status guard uses, set only inside these RPCs.
CREATE OR REPLACE FUNCTION public.feed_load_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $fn$
DECLARE
    v_load_id uuid;
    v_status  text;
BEGIN
    IF current_setting('feed_truck.rpc', true) = 'on' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_TABLE_NAME = 'feed_drop_lots' THEN
        SELECT d.load_id INTO v_load_id FROM public.feed_drops d
         WHERE d.id = COALESCE(NEW.drop_id, OLD.drop_id);
    ELSE
        v_load_id := COALESCE(NEW.load_id, OLD.load_id);
    END IF;
    SELECT status INTO v_status FROM public.feed_loads WHERE id = v_load_id;
    IF v_status IN ('posted','void') THEN
        RAISE EXCEPTION 'feed_load_guard: load % is %; unpost it before changing its %.',
            v_load_id, v_status, TG_TABLE_NAME;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END
$fn$;

-- ---------------------------------------------------------------------
-- 2b. split_drop_to_lots stops refusing an empty pasture
-- ---------------------------------------------------------------------
-- It used to RAISE when no lot was standing there, which killed the whole
-- posting run for a load that filled a trap ahead of the cattle. It is a
-- fill-in helper, not a policy: it now returns 0 and lets post_feed_load
-- decide, which books those pounds to the pasture. A drop genuinely made in
-- the wrong pasture surfaces on Needs Attention instead of blocking feed
-- from reaching the books.
CREATE OR REPLACE FUNCTION public.split_drop_to_lots(p_drop_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_drop    record;
    v_date    date;
    v_lots    uuid[];
    v_heads   numeric[];
    v_parts   numeric[];
    i         integer;
BEGIN
    IF EXISTS (SELECT 1 FROM public.feed_drop_lots WHERE drop_id = p_drop_id) THEN
        RETURN 0;
    END IF;
    SELECT d.*, l.load_date INTO v_drop
      FROM public.feed_drops d JOIN public.feed_loads l ON l.id = d.load_id
     WHERE d.id = p_drop_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'split_drop_to_lots: drop % not found.', p_drop_id;
    END IF;
    v_date := v_drop.load_date;

    SELECT array_agg(lot_id ORDER BY lot_id), array_agg(head ORDER BY lot_id)
      INTO v_lots, v_heads
      FROM (SELECT a.lot_id, SUM(a.head_count)::numeric AS head
              FROM public.lot_pasture_assignments a
             WHERE a.pasture_id = v_drop.pasture_id
               AND a.moved_in <= v_date
               AND (a.moved_out IS NULL OR a.moved_out >= v_date)
             GROUP BY a.lot_id
            HAVING SUM(a.head_count) > 0) s;

    IF v_lots IS NULL THEN
        RETURN 0;                      -- nothing standing there: placed feed
    END IF;

    v_parts := public.lr_split(v_drop.lb, v_heads, 2);
    FOR i IN 1..array_length(v_lots, 1) LOOP
        INSERT INTO public.feed_drop_lots (drop_id, lot_id, head_count, lb)
        VALUES (p_drop_id, v_lots[i], v_heads[i]::integer, v_parts[i]);
    END LOOP;
    RETURN array_length(v_lots, 1);
END
$fn$;

-- ---------------------------------------------------------------------
-- 3. post_feed_load: a pasture is a destination too
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_feed_load(p_load_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_load       record;
    v_from       date;
    v_loaded     numeric;
    v_dropped    numeric;
    v_kind       text[];
    v_lots       uuid[];
    v_pastures   uuid[];
    v_dest_lb    numeric[];
    v_parts      numeric[];
    v_line       record;
    v_usage_id   uuid;
    v_rows       integer := 0;
    v_ration     text;
    drop_rec     record;
    i            integer;
BEGIN
    SELECT * INTO v_load FROM public.feed_loads WHERE id = p_load_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'post_feed_load: load % not found.', p_load_id;
    END IF;
    IF v_load.status <> 'closed' THEN
        RAISE EXCEPTION 'post_feed_load: load % is %, only a closed load posts.', p_load_id, v_load.status;
    END IF;
    IF v_load.load_date >= public.ranch_today() THEN
        RAISE EXCEPTION 'post_feed_load: load % is dated % - today''s loads stay editable in the cab until tomorrow.',
            p_load_id, v_load.load_date;
    END IF;
    SELECT feed_truck_post_from INTO v_from FROM public.ranch_settings LIMIT 1;
    IF v_from IS NULL THEN
        RAISE EXCEPTION 'post_feed_load: no cut-over date is set (ranch_settings.feed_truck_post_from). The truck is still running parallel to PB.';
    END IF;
    IF v_load.load_date < v_from THEN
        RAISE EXCEPTION 'post_feed_load: load % is dated %, before the cut-over date %.', p_load_id, v_load.load_date, v_from;
    END IF;

    SELECT COALESCE(SUM(lb), 0) INTO v_loaded FROM public.feed_load_lines WHERE load_id = p_load_id;
    IF v_loaded <= 0 THEN
        RAISE EXCEPTION 'post_feed_load: load % has no pounds on its lines.', p_load_id;
    END IF;

    -- Every drop with pounds needs its lot split; fill any the app missed.
    FOR drop_rec IN SELECT id FROM public.feed_drops WHERE load_id = p_load_id AND lb > 0 LOOP
        PERFORM public.split_drop_to_lots(drop_rec.id);
    END LOOP;

    -- Destinations: the lots this load fed, plus any pasture it fed where
    -- the books show no cattle (a trap filled ahead of a new lot). Without
    -- the second group those pounds would be split over the OTHER lots on
    -- the load - feed charged to cattle that never saw it.
    SELECT array_agg(kind ORDER BY ord, k1, k2), array_agg(lot_id ORDER BY ord, k1, k2),
           array_agg(pasture_id ORDER BY ord, k1, k2), array_agg(lb ORDER BY ord, k1, k2), SUM(lb)
      INTO v_kind, v_lots, v_pastures, v_dest_lb, v_dropped
      FROM (
        SELECT 'lot'::text AS kind, dl.lot_id, NULL::uuid AS pasture_id, SUM(dl.lb) AS lb,
               1 AS ord, dl.lot_id AS k1, NULL::uuid AS k2
          FROM public.feed_drop_lots dl
          JOIN public.feed_drops d ON d.id = dl.drop_id
         WHERE d.load_id = p_load_id AND d.lb > 0
         GROUP BY dl.lot_id
        HAVING SUM(dl.lb) > 0
        UNION ALL
        SELECT 'pasture', NULL::uuid, d.pasture_id, SUM(d.lb),
               2, NULL::uuid, d.pasture_id
          FROM public.feed_drops d
         WHERE d.load_id = p_load_id AND d.lb > 0
           AND NOT EXISTS (SELECT 1 FROM public.feed_drop_lots dl2 WHERE dl2.drop_id = d.id AND dl2.lb > 0)
         GROUP BY d.pasture_id
        HAVING SUM(d.lb) > 0
      ) s;
    IF v_kind IS NULL OR v_dropped <= 0 THEN
        RAISE EXCEPTION 'post_feed_load: load % dropped nothing; there is nothing to charge. If the whole load stayed in the box, void it and let the next load carry the pounds.',
            p_load_id;
    END IF;

    SELECT name INTO v_ration FROM public.rations WHERE id = v_load.ration_id;

    FOR v_line IN
        SELECT * FROM public.feed_load_lines WHERE load_id = p_load_id AND lb > 0 ORDER BY load_order
    LOOP
        v_parts := public.lr_split(v_line.lb, v_dest_lb, 2);
        FOR i IN 1..array_length(v_kind, 1) LOOP
            CONTINUE WHEN v_parts[i] <= 0;
            v_usage_id := public.post_feed_usage(
                p_item_id          => v_line.item_id,
                p_from_location_id => v_line.location_id,
                p_qty_lb           => v_parts[i],
                p_destination_type => v_kind[i],
                p_period_start     => v_load.load_date,
                p_period_end       => v_load.load_date,
                p_lot_id           => v_lots[i],
                p_pasture_id       => v_pastures[i],
                p_usage_date       => v_load.load_date,
                p_source           => 'truck',
                p_notes            => 'Feed truck ' || v_load.load_date::text || ' load ' || v_load.load_seq::text
                                      || ' (' || COALESCE(v_ration, '?') || ')'
                                      || CASE WHEN v_kind[i] = 'pasture'
                                              THEN ' - placed before the cattle; awaiting a lot' ELSE '' END
            );
            INSERT INTO public.feed_load_usage (load_id, usage_id) VALUES (p_load_id, v_usage_id);
            v_rows := v_rows + 1;
        END LOOP;
    END LOOP;

    PERFORM set_config('feed_truck.rpc', 'on', true);
    UPDATE public.feed_loads
       SET status = 'posted', posted_at = now(), posted_by = auth.uid()
     WHERE id = p_load_id;
    PERFORM set_config('feed_truck.rpc', 'off', true);
    RETURN v_rows;
END
$fn$;

-- ---------------------------------------------------------------------
-- 4. claim_placed_feed - the cattle arrive, the feed follows them
-- ---------------------------------------------------------------------
-- Moves pasture-charged truck feed onto the lot that ate it, dated that
-- lot's first day with cattle on or after the delivery. The usage row is
-- UPDATED, not replaced, so feed_load_usage still links it and unposting
-- the load still reverses it. The drop is named with the lot as well, so
-- the load ticket and the PB tie-out show who carries the pounds.
CREATE OR REPLACE FUNCTION public.claim_placed_feed()
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    u_rec     record;
    v_lot     uuid;
    v_day     date;
    v_head    integer;
    v_number  text;
    v_drop    uuid;
    v_n       integer := 0;
BEGIN
    FOR u_rec IN
        SELECT fu.id AS usage_id, fu.pasture_id, fu.usage_date, flu.load_id
          FROM public.feed_usage fu
          JOIN public.feed_load_usage flu ON flu.usage_id = fu.id
         WHERE fu.destination_type = 'pasture'
           AND fu.source = 'truck'
           AND fu.pasture_id IS NOT NULL
         ORDER BY fu.usage_date
    LOOP
        SELECT d.for_lot_id, d.id INTO v_lot, v_drop
          FROM public.feed_drops d
         WHERE d.load_id = u_rec.load_id AND d.pasture_id = u_rec.pasture_id AND d.lb > 0
         ORDER BY d.drop_seq LIMIT 1;

        -- Nobody named a lot: the first one to stand in that pasture after
        -- the feed was placed is the one that ate it.
        IF v_lot IS NULL THEN
            SELECT a.lot_id INTO v_lot
              FROM public.lot_pasture_assignments a
             WHERE a.pasture_id = u_rec.pasture_id
               AND a.head_count > 0
               AND a.moved_in >= u_rec.usage_date
               AND (a.moved_out IS NULL OR a.moved_out > a.moved_in)
             ORDER BY a.moved_in, a.head_count DESC
             LIMIT 1;
        END IF;
        CONTINUE WHEN v_lot IS NULL;

        SELECT min(h.as_of_date) INTO v_day
          FROM public.lot_daily_head h
         WHERE h.lot_id = v_lot AND h.as_of_date >= u_rec.usage_date AND h.head_on_hand > 0;
        CONTINUE WHEN v_day IS NULL;

        SELECT lot_number INTO v_number FROM public.lots WHERE id = v_lot;
        UPDATE public.feed_usage
           SET destination_type = 'lot', lot_id = v_lot, pasture_id = NULL,
               usage_date = v_day, period_start = v_day, period_end = v_day,
               notes = CONCAT_WS(E'\n', notes,
                        '[placed feed charged to ' || COALESCE(v_number,'?') || ' on ' || v_day::text
                        || ', delivered ' || u_rec.usage_date::text || ']')
         WHERE id = u_rec.usage_id;

        -- Name the lot on the drop as well, so the ticket and the tie-out
        -- stop showing pounds nobody carries.
        IF v_drop IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.feed_drop_lots WHERE drop_id = v_drop) THEN
            SELECT COALESCE(h.head_on_hand, 0) INTO v_head
              FROM public.lot_daily_head h WHERE h.lot_id = v_lot AND h.as_of_date = v_day;
            PERFORM set_config('feed_truck.rpc', 'on', true);
            INSERT INTO public.feed_drop_lots (drop_id, lot_id, head_count, lb)
            SELECT v_drop, v_lot, COALESCE(v_head, 0), d.lb FROM public.feed_drops d WHERE d.id = v_drop;
            PERFORM set_config('feed_truck.rpc', 'off', true);
        END IF;
        v_n := v_n + 1;
    END LOOP;
    RETURN v_n;
END
$fn$;

-- ---------------------------------------------------------------------
-- 5. post_due_feed_loads also claims what the cattle have arrived for
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_due_feed_loads()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_from    date;
    v_posted  integer := 0;
    v_claimed integer := 0;
    v_errors  jsonb := '[]'::jsonb;
    l_rec     record;
BEGIN
    SELECT feed_truck_post_from INTO v_from FROM public.ranch_settings LIMIT 1;
    IF v_from IS NULL THEN
        RETURN jsonb_build_object('posted', 0, 'claimed', 0, 'errors', '[]'::jsonb, 'parallel', true);
    END IF;
    FOR l_rec IN
        SELECT id, load_date, load_seq FROM public.feed_loads
         WHERE status = 'closed' AND load_date >= v_from AND load_date < public.ranch_today()
         ORDER BY load_date, load_seq
    LOOP
        BEGIN
            PERFORM public.post_feed_load(l_rec.id);
            v_posted := v_posted + 1;
        EXCEPTION WHEN OTHERS THEN
            v_errors := v_errors || jsonb_build_object(
                'load_id', l_rec.id, 'load_date', l_rec.load_date, 'load_seq', l_rec.load_seq,
                'error', SQLERRM);
        END;
    END LOOP;
    BEGIN
        v_claimed := public.claim_placed_feed();
    EXCEPTION WHEN OTHERS THEN
        v_errors := v_errors || jsonb_build_object('error', 'claim_placed_feed: ' || SQLERRM);
    END;
    RETURN jsonb_build_object('posted', v_posted, 'claimed', v_claimed, 'errors', v_errors, 'parallel', false);
END
$fn$;

-- ---------------------------------------------------------------------
-- 6. What is still sitting in a trap
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS public.inventory_needs_attention;
DROP VIEW IF EXISTS public.feed_placed_unclaimed;
CREATE VIEW public.feed_placed_unclaimed WITH (security_invoker = true) AS
SELECT fu.id                       AS usage_id,
       fu.usage_date,
       fu.pasture_id,
       COALESCE(r.name || ' / ', '') || p.name AS pasture_label,
       fu.item_id,
       fi.name                     AS item_name,
       fu.qty_lb,
       uc.cost                     AS cost_usd,
       d.for_lot_id,
       lo.lot_number               AS for_lot_number,
       flu.load_id,
       public.ranch_today() - fu.usage_date AS age_days
  FROM public.feed_usage fu
  JOIN public.feed_load_usage flu ON flu.usage_id = fu.id
  LEFT JOIN public.feed_usage_costs uc ON uc.usage_id = fu.id
  LEFT JOIN public.pastures p  ON p.id = fu.pasture_id
  LEFT JOIN public.ranches  r  ON r.id = p.ranch_id
  LEFT JOIN public.feed_items fi ON fi.id = fu.item_id
  LEFT JOIN LATERAL (SELECT d2.for_lot_id FROM public.feed_drops d2
                      WHERE d2.load_id = flu.load_id AND d2.pasture_id = fu.pasture_id AND d2.lb > 0
                      ORDER BY d2.drop_seq LIMIT 1) d ON true
  LEFT JOIN public.lots lo ON lo.id = d.for_lot_id
 WHERE fu.destination_type = 'pasture' AND fu.source = 'truck';

CREATE VIEW public.inventory_needs_attention
WITH (security_invoker = true) AS

-- Ordered, and it has not turned up.
SELECT 'ordered_overdue'::text AS kind,
       'warn'::text            AS severity,
       s.item_kind,
       'supply_order_lines'::text AS ref_table,
       s.order_line_id         AS ref_id,
       s.item_name             AS title,
       coalesce(s.vendor_name,'no vendor') || ' · due ' || s.expected_delivery_date::text AS detail,
       s.days_overdue          AS age_days,
       10                      AS sort_rank
FROM public.supply_order_line_status s
WHERE s.days_overdue IS NOT NULL

UNION ALL
-- Delivered and fed, and nobody knows what it cost.
SELECT 'unpriced_load', 'warn', 'feed', 'feed_receipts', r.id,
       i.name,
       'no price · ' || round(r.qty_lb)::text || ' lb into ' || l.name,
       public.ranch_today() - r.receipt_date,
       20
FROM public.feed_receipts r
JOIN public.feed_items i             ON i.id = r.item_id
JOIN public.feed_storage_locations l ON l.id = r.location_id
WHERE r.cost_pending
  AND r.source = 'purchase'

UNION ALL
-- No scale ticket recorded. The ageing number is what tells you when to
-- ring the mill.
SELECT 'awaiting_ticket', 'info', 'feed', 'feed_receipts', r.id,
       i.name,
       coalesce(v.name, r.vendor, 'no vendor') || ' · ' || round(r.qty_lb)::text || ' lb',
       public.ranch_today() - r.receipt_date,
       30
FROM public.feed_receipts r
JOIN public.feed_items i    ON i.id = r.item_id
LEFT JOIN public.vendors v  ON v.id = r.vendor_id
WHERE r.source = 'purchase'
  AND r.paperwork_done = false
  AND (r.ticket_number IS NULL OR btrim(r.ticket_number) = '')

UNION ALL
-- The bill has not arrived. count_adjustment, transfer_in, batch_out and
-- opening_balance never expect one, so they are not here.
SELECT 'awaiting_invoice', 'info', 'feed', 'feed_receipts', r.id,
       i.name,
       coalesce(v.name, r.vendor, 'no vendor') || ' · '
         || coalesce('$' || round(r.total_cost,2)::text, 'unpriced'),
       public.ranch_today() - r.receipt_date,
       40
FROM public.feed_receipts r
JOIN public.feed_items i    ON i.id = r.item_id
LEFT JOIN public.vendors v  ON v.id = r.vendor_id
WHERE r.source = 'purchase'
  AND r.paperwork_done = false
  AND r.invoice_id IS NULL

UNION ALL
-- Recorded with no order behind it. Not an error - the escape hatch is
-- deliberate - but you should be able to see how often it happens.
SELECT 'unordered_load', 'info', 'feed', 'feed_receipts', r.id,
       i.name,
       'no order · ' || coalesce(v.name, r.vendor, 'no vendor'),
       public.ranch_today() - r.receipt_date,
       50
FROM public.feed_receipts r
JOIN public.feed_items i    ON i.id = r.item_id
LEFT JOIN public.vendors v  ON v.id = r.vendor_id
WHERE r.source = 'purchase'
  AND r.order_line_id IS NULL
  AND r.paperwork_done = false

UNION ALL
-- The bill does not add up to what we matched to it.
SELECT 'invoice_does_not_tie', 'alert', 'feed', 'supply_invoices', ir.invoice_id,
       'Invoice ' || ir.invoice_number,
       coalesce(ir.vendor_name,'no vendor') || ' · off by $' || round(ir.variance_usd, 2)::text,
       public.ranch_today() - ir.invoice_date,
       5
FROM public.supply_invoice_reconciliation ir
WHERE abs(ir.variance_usd) >= 0.01

UNION ALL
-- A bay the books think is empty and is not, or the reverse.
SELECT 'bay_short', 'warn', 'feed', 'feed_usage', u.id,
       i.name,
       'went short ' || round(u.qty_lb)::text || ' lb out of ' || l.name,
       public.ranch_today() - u.usage_date,
       60
FROM public.feed_usage u
JOIN public.feed_items i             ON i.id = u.item_id
JOIN public.feed_storage_locations l ON l.id = u.from_location_id
WHERE u.is_short
  AND u.usage_date >= public.ranch_today() - 60

UNION ALL
-- A premix short is not an ordinary short: it means the ingredients are
-- still on the books. Two errors, and the feed still allocates cleanly.
SELECT 'premix_short', 'alert', 'feed', 'feed_usage', p.usage_id,
       p.item_name,
       'premix short ' || round(p.short_lb)::text || ' lb - ingredients may still be on the books',
       public.ranch_today() - p.usage_date,
       6
FROM public.feed_premix_shorts p
WHERE p.usage_date >= public.ranch_today() - 90

UNION ALL
-- Counts are truth, so counts have to actually happen.
SELECT 'count_overdue', 'warn', 'feed', 'feed_storage_locations', c.location_id,
       c.location_name,
       CASE WHEN c.last_counted_on IS NULL THEN 'never counted'
            ELSE 'last counted ' || c.days_since_count::text || ' days ago' END,
       c.days_since_count,
       70
FROM public.feed_location_count_status c
WHERE c.is_overdue

UNION ALL
-- Feed whose period holds no head-days for its lot. It cannot spread, so
-- rather than vanish inside a JOIN it surfaces here.
SELECT 'feed_unallocated', 'warn', 'feed', 'feed_usage', ua.usage_id,
       ua.item_name,
       coalesce(ua.lot_number,'no lot') || ' · $' || round(coalesce(ua.cost_usd,0),2)::text
         || ' · ' || coalesce(ua.why,''),
       public.ranch_today() - ua.usage_date,
       65
FROM public.feed_cost_unallocated ua
UNION ALL
-- Feed put in a trap before the cattle got there. It is out of the bay and
-- costed, but no lot is eating it yet: it stays on the pasture until the
-- cattle land, and it nags until they do (or until somebody decides where
-- it really went).
SELECT 'placed_feed', CASE WHEN p.age_days > 14 THEN 'warn' ELSE 'info' END, 'feed', 'feed_usage', p.usage_id,
       p.pasture_label,
       p.item_name || ' · ' || round(p.qty_lb)::text || ' lb · '
         || coalesce('for ' || p.for_lot_number, 'no lot named yet'),
       p.age_days,
       25
FROM public.feed_placed_unclaimed p;


DO $vgrants$
DECLARE v text;
BEGIN
    FOREACH v IN ARRAY ARRAY['feed_placed_unclaimed','inventory_needs_attention'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', v);
        EXECUTE format('REVOKE ALL ON public.%I FROM anon', v);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', v);
    END LOOP;
END
$vgrants$;

DO $verify$
DECLARE n integer;
BEGIN
    IF to_regclass('public.feed_placed_unclaimed') IS NULL THEN RAISE EXCEPTION 'feed_placed_unclaimed missing'; END IF;
    IF to_regclass('public.inventory_needs_attention') IS NULL THEN RAISE EXCEPTION 'inventory_needs_attention missing'; END IF;
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema = 'public'
       AND ((table_name = 'bunk_reads' AND column_name = 'for_lot_id')
         OR (table_name = 'feed_drops' AND column_name = 'for_lot_id'));
    IF n <> 2 THEN RAISE EXCEPTION 'for_lot_id columns missing (found % of 2)', n; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'claim_placed_feed') THEN
        RAISE EXCEPTION 'claim_placed_feed missing';
    END IF;
    -- every view here must be security_invoker (rule 3)
    SELECT count(*) INTO n FROM pg_class c
     WHERE c.relname IN ('feed_placed_unclaimed','inventory_needs_attention')
       AND c.relkind = 'v'
       AND NOT COALESCE((SELECT option_value = 'true' FROM pg_options_to_table(c.reloptions)
                          WHERE option_name = 'security_invoker'), false);
    IF n > 0 THEN RAISE EXCEPTION '% view(s) are not security_invoker', n; END IF;
    RAISE NOTICE 'placed_feed: OK';
END
$verify$;
