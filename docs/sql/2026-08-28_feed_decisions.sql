-- =====================================================================
-- Feed inventory: the 2026-08-28 design decisions
-- =====================================================================
-- Run AFTER 2026-08-27_feed_inventory.sql and 2026-08-27_feed_phase4_premix.sql.
-- Idempotent. Safe to re-run.
--
-- The reasoning for every choice here is in docs/feed-design-decisions.md.
-- What this migration adds, and which decision it implements:
--
--   #2   feed_items.redwing_template_field  - many items -> one Redwing box
--   #3/7 feed_items.default_shrink_allowance_pct + feed_receipts.gross_qty_lb
--        and shrink_allowance_pct           - the entry haircut, per commodity
--   #10  feed_storage_locations.count_interval_days + a status view
--   #15  ranch_settings.feed_direct_from    - the allocation -> actual boundary
--   #20  feed_items.is_premix + a shorts view
--   #25  feed_items.count_variance_meaning  - shrink for commodities,
--        CONSUMPTION for mineral, allocated across lots by head-days
--   #26  post_feed_usage refuses a period_end in the future
--
-- NOTE the booked quantity stays `feed_receipts.qty_lb` and remains the FIFO
-- layer. gross_qty_lb records what actually came in BEFORE the haircut, so
-- next season's allowance calibrates on GROSS. Calibrating on booked
-- compounds each year's estimate error into the next (decision #4).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Guard: the feed module must already be here.
-- ---------------------------------------------------------------------
DO $guard$
BEGIN
    IF to_regclass('public.feed_items') IS NULL
       OR to_regclass('public.feed_receipts') IS NULL
       OR to_regclass('public.feed_batches') IS NULL THEN
        RAISE EXCEPTION 'Apply 2026-08-27_feed_inventory.sql and _feed_phase4_premix.sql first.';
    END IF;
    IF to_regproc('public.ranch_today') IS NULL THEN
        RAISE EXCEPTION 'public.ranch_today() is missing. The database runs UTC; the ranch does not.';
    END IF;
END
$guard$;


-- ---------------------------------------------------------------------
-- 1. feed_items - three new facts about an item
-- ---------------------------------------------------------------------
ALTER TABLE public.feed_items
    ADD COLUMN IF NOT EXISTS redwing_template_field       text,
    ADD COLUMN IF NOT EXISTS default_shrink_allowance_pct numeric,
    ADD COLUMN IF NOT EXISTS count_variance_meaning       text NOT NULL DEFAULT 'shrink',
    ADD COLUMN IF NOT EXISTS is_premix                    boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.feed_items.redwing_template_field IS
'Which box on Redwing''s Feed/Mineral Application template this item feeds.
Several items may share one box and the export sums them - "Corn" and "Corn
hopper bin" are two items because PB encodes the BAY in the commodity name,
which is the only signal telling an import which pile was fed.';

COMMENT ON COLUMN public.feed_items.default_shrink_allowance_pct IS
'Entry haircut, percent. NULL = none (every purchased commodity today).
Silage books gross x (1 - allowance) holding the full harvest cost, so $/lb
rises on day one and every pound fed carries its share. Do NOT switch this on
for a scale-ticketed commodity until its shrink has actually been measured -
haircutting a weighed load breaks the tie to the invoice and to Redwing.';

COMMENT ON COLUMN public.feed_items.count_variance_meaning IS
'What a physical count variance MEANS for this item.
  shrink      - we know what was fed (PB tells us), so the residual is shrink;
                it goes to the variance account and never to a lot.
  consumption - no feeding record exists (mineral), so the residual IS what
                was consumed; it allocates to lots by head-days.
Same mechanism, opposite meaning. Getting this wrong on mineral silently
stops charging cattle for it; getting it wrong on a commodity dumps a bay
of shrink onto whichever lot happens to be standing there.';

COMMENT ON COLUMN public.feed_items.is_premix IS
'A premix going short is not an ordinary short: it means the batch was never
recorded and the INGREDIENTS ARE STILL ON THE BOOKS. Two errors, opposite
directions, and the feed still allocates cleanly so nothing looks broken.
That is how PB reached -1,109,171 lb.';

DO $c$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'feed_items_variance_meaning_ck') THEN
        ALTER TABLE public.feed_items
            ADD CONSTRAINT feed_items_variance_meaning_ck
            CHECK (count_variance_meaning IN ('shrink','consumption'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'feed_items_shrink_allowance_ck') THEN
        ALTER TABLE public.feed_items
            ADD CONSTRAINT feed_items_shrink_allowance_ck
            CHECK (default_shrink_allowance_pct IS NULL
                   OR (default_shrink_allowance_pct >= 0 AND default_shrink_allowance_pct < 100));
    END IF;
END
$c$;

-- Mineral defaults to consumption. Everything else stays shrink.
UPDATE public.feed_items
   SET count_variance_meaning = 'consumption'
 WHERE item_type = 'mineral'
   AND count_variance_meaning = 'shrink';


-- ---------------------------------------------------------------------
-- 2. feed_receipts - gross and allowance beside the booked layer
-- ---------------------------------------------------------------------
ALTER TABLE public.feed_receipts
    ADD COLUMN IF NOT EXISTS gross_qty_lb         numeric,
    ADD COLUMN IF NOT EXISTS shrink_allowance_pct numeric;

COMMENT ON COLUMN public.feed_receipts.gross_qty_lb IS
'What actually came in, BEFORE the entry haircut. qty_lb stays the booked
figure and the FIFO layer. Actual shrink calibrates as
(gross_qty_lb - total ever fed) / gross_qty_lb - never against qty_lb, or
last year''s estimate error compounds into next year''s allowance.';

DO $c2$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'feed_receipts_gross_ck') THEN
        ALTER TABLE public.feed_receipts
            ADD CONSTRAINT feed_receipts_gross_ck
            CHECK (gross_qty_lb IS NULL OR gross_qty_lb >= qty_lb);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'feed_receipts_allowance_ck') THEN
        ALTER TABLE public.feed_receipts
            ADD CONSTRAINT feed_receipts_allowance_ck
            CHECK (shrink_allowance_pct IS NULL
                   OR (shrink_allowance_pct >= 0 AND shrink_allowance_pct < 100));
    END IF;
END
$c2$;


-- ---------------------------------------------------------------------
-- 3. feed_storage_locations - how often this bay should be counted
-- ---------------------------------------------------------------------
ALTER TABLE public.feed_storage_locations
    ADD COLUMN IF NOT EXISTS count_interval_days integer;

COMMENT ON COLUMN public.feed_storage_locations.count_interval_days IS
'Target days between counts. NULL = no target. Overdue is FLAGGED, never
blocked - refusing to record usage from an overdue bay does not un-feed the
cattle. ~90 for the barn; silage piles are counted at pile close.';

DO $c3$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'feed_locations_count_interval_ck') THEN
        ALTER TABLE public.feed_storage_locations
            ADD CONSTRAINT feed_locations_count_interval_ck
            CHECK (count_interval_days IS NULL OR count_interval_days > 0);
    END IF;
END
$c3$;


-- ---------------------------------------------------------------------
-- 4. ranch_settings - one row, holding the allocation -> actual boundary
-- ---------------------------------------------------------------------
-- feed_direct_from MUST be a ranch-level date, not a per-lot flag. The flag
-- phase 4 shipped has no date and rewrites a lot's WHOLE LIFE: setting it on
-- 36-27 on 9/1 would re-price August from $2.00 to ~$1.00/head/day with no
-- actual feed to replace it - about 6,441 head-days, ~$6,400 evaporating.
-- The closeout SPLITS head-days on this date.
CREATE TABLE IF NOT EXISTS public.ranch_settings (
    id                boolean PRIMARY KEY DEFAULT true CHECK (id),
    feed_direct_from  date,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

INSERT INTO public.ranch_settings (id, feed_direct_from)
VALUES (true, DATE '2026-09-01')
ON CONFLICT (id) DO NOTHING;

COMMENT ON TABLE public.ranch_settings IS
'One row. Ranch-wide policy that is not a property of any lot.';
COMMENT ON COLUMN public.ranch_settings.feed_direct_from IS
'From this date every lot charges ACTUAL feed plus assumed_nonfeed_cog_per_day.
Before it, feed stays inside the assumed cost of gain and the cost allocation.
The closeout splits a lot''s head-days on this date; it never re-prices the
days before it.';

ALTER TABLE public.ranch_settings ENABLE ROW LEVEL SECURITY;

DO $rls$
BEGIN
    DROP POLICY IF EXISTS ranch_settings_select ON public.ranch_settings;
    DROP POLICY IF EXISTS ranch_settings_update ON public.ranch_settings;
    DROP POLICY IF EXISTS ranch_settings_insert ON public.ranch_settings;

    -- Readable by anyone with a role. It is a date, not a dollar, and a
    -- settings table nobody can read becomes a settings table nobody uses.
    EXECUTE 'CREATE POLICY ranch_settings_select ON public.ranch_settings
             FOR SELECT TO authenticated
             USING (public.current_user_role() IS NOT NULL)';
    -- Owner only: changing this date moves money between periods.
    EXECUTE 'CREATE POLICY ranch_settings_update ON public.ranch_settings
             FOR UPDATE TO authenticated
             USING (public.current_user_role() = ''owner'')
             WITH CHECK (public.current_user_role() = ''owner'')';
    EXECUTE 'CREATE POLICY ranch_settings_insert ON public.ranch_settings
             FOR INSERT TO authenticated
             WITH CHECK (public.current_user_role() = ''owner'')';
END
$rls$;

REVOKE ALL ON public.ranch_settings FROM PUBLIC;
REVOKE ALL ON public.ranch_settings FROM anon;
GRANT SELECT, INSERT, UPDATE ON public.ranch_settings TO authenticated;

DROP TRIGGER IF EXISTS trg_ranch_settings_touch ON public.ranch_settings;
CREATE TRIGGER trg_ranch_settings_touch
    BEFORE UPDATE ON public.ranch_settings
    FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


-- ---------------------------------------------------------------------
-- 5. post_feed_usage - refuse a period_end in the future
-- ---------------------------------------------------------------------
-- A partial period spreads real dollars across days nothing was fed on.
-- The Mon-Sun-entered-Monday cycle means this should never fire; it costs
-- nothing and stops the one entry that would be silently wrong.
--
-- Same signature, so CREATE OR REPLACE keeps the existing grants. The body
-- is the phase 4 body with one guard inserted after the dates resolve.
CREATE OR REPLACE FUNCTION public.post_feed_usage(
    p_item_id           uuid,
    p_from_location_id  uuid,
    p_qty_lb            numeric,
    p_destination_type  text,
    p_period_start      date    DEFAULT NULL,
    p_period_end        date    DEFAULT NULL,
    p_lot_id            uuid    DEFAULT NULL,
    p_pasture_id        uuid    DEFAULT NULL,
    p_to_location_id    uuid    DEFAULT NULL,
    p_usage_date        date    DEFAULT NULL,
    p_source            text    DEFAULT 'manual',
    p_pb_row_key        text    DEFAULT NULL,
    p_reason            text    DEFAULT NULL,
    p_notes             text    DEFAULT NULL,
    p_batch_id          uuid    DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_usage_id     uuid;
    v_remaining    numeric := p_qty_lb;
    v_take         numeric;
    v_usage_date   date;
    v_start        date;
    v_end          date;
    v_short        boolean := false;
    v_pending      boolean := false;
    v_last_cost    numeric;
    v_to_loc_row   record;
    v_new_receipt  uuid;
    layer_rec      record;
BEGIN
    IF p_qty_lb IS NULL OR p_qty_lb <= 0 THEN
        RAISE EXCEPTION 'post_feed_usage: qty_lb must be greater than zero.';
    END IF;

    v_usage_date := COALESCE(p_usage_date, public.ranch_today());
    v_start      := COALESCE(p_period_start, v_usage_date);
    v_end        := COALESCE(p_period_end,   v_usage_date);

    IF v_end < v_start THEN
        RAISE EXCEPTION 'post_feed_usage: period_end (%) is before period_start (%).', v_end, v_start;
    END IF;

    -- Decision #26. A period that has not finished spreads real dollars over
    -- days nothing was fed on. There is no legitimate case for it.
    IF v_end > public.ranch_today() THEN
        RAISE EXCEPTION
          'post_feed_usage: period_end % has not happened yet (today is %). Enter a completed period.',
          v_end, public.ranch_today();
    END IF;

    INSERT INTO public.feed_usage (
        usage_date, period_start, period_end, item_id, from_location_id,
        destination_type, lot_id, pasture_id, to_location_id, qty_lb,
        source, pb_row_key, reason, notes, batch_id, created_by
    ) VALUES (
        v_usage_date, v_start, v_end, p_item_id, p_from_location_id,
        p_destination_type, p_lot_id, p_pasture_id, p_to_location_id, p_qty_lb,
        p_source, p_pb_row_key, p_reason, p_notes, p_batch_id, auth.uid()
    ) RETURNING id INTO v_usage_id;

    -- FIFO, scoped to (item, location). Corn in Bay 2 and Bay 5 are one item
    -- in two places; global FIFO would let a count on one bay eat a layer
    -- sitting in another and on-hand-by-bay would stop reconciling.
    FOR layer_rec IN
        SELECT id, qty_lb_remaining, unit_cost_per_lb, cost_pending
          FROM public.feed_receipts
         WHERE item_id = p_item_id
           AND location_id = p_from_location_id
           AND qty_lb_remaining > 0
         ORDER BY receipt_date, created_at
         FOR UPDATE
    LOOP
        EXIT WHEN v_remaining <= 0;
        v_take := LEAST(v_remaining, layer_rec.qty_lb_remaining);

        UPDATE public.feed_receipts
           SET qty_lb_remaining = qty_lb_remaining - v_take
         WHERE id = layer_rec.id;

        INSERT INTO public.feed_usage_costs (usage_id, receipt_id, qty_lb, unit_cost_per_lb, cost, is_short)
        VALUES (v_usage_id, layer_rec.id, v_take, layer_rec.unit_cost_per_lb,
                CASE WHEN layer_rec.unit_cost_per_lb IS NULL THEN NULL
                     ELSE ROUND(v_take * layer_rec.unit_cost_per_lb, 4) END,
                false);

        IF layer_rec.unit_cost_per_lb IS NULL THEN
            v_pending := true;
        END IF;

        v_remaining := v_remaining - v_take;
    END LOOP;

    -- Going short is ALLOWED, flagged, never blocked. A bulk bay is an
    -- estimate; refusing does not un-feed the cattle. Physical MORE than
    -- book means a delivery was never entered.
    IF v_remaining > 0 THEN
        v_short := true;

        SELECT r.unit_cost_per_lb INTO v_last_cost
          FROM public.feed_receipts r
         WHERE r.item_id = p_item_id AND r.location_id = p_from_location_id
           AND r.unit_cost_per_lb IS NOT NULL
         ORDER BY r.receipt_date DESC, r.created_at DESC
         LIMIT 1;

        IF v_last_cost IS NULL THEN
            SELECT r.unit_cost_per_lb INTO v_last_cost
              FROM public.feed_receipts r
             WHERE r.item_id = p_item_id AND r.unit_cost_per_lb IS NOT NULL
             ORDER BY r.receipt_date DESC, r.created_at DESC
             LIMIT 1;
        END IF;

        INSERT INTO public.feed_usage_costs (usage_id, receipt_id, qty_lb, unit_cost_per_lb, cost, is_short)
        VALUES (v_usage_id, NULL, v_remaining, v_last_cost,
                CASE WHEN v_last_cost IS NULL THEN NULL
                     ELSE ROUND(v_remaining * v_last_cost, 4) END,
                true);

        IF v_last_cost IS NULL THEN
            v_pending := true;
        END IF;
    END IF;

    UPDATE public.feed_usage
       SET is_short = v_short, cost_pending = v_pending
     WHERE id = v_usage_id;

    -- A transfer lays a new layer in the far bay at the cost it left at.
    IF p_destination_type = 'transfer' THEN
        SELECT COALESCE(SUM(qty_lb),0) AS lb, COALESCE(SUM(cost),0) AS usd,
               bool_or(cost IS NULL) AS any_null
          INTO v_to_loc_row
          FROM public.feed_usage_costs
         WHERE usage_id = v_usage_id;

        INSERT INTO public.feed_receipts (
            receipt_date, item_id, location_id, vendor, notes,
            qty_lb, product_cost, cost_pending, qty_lb_remaining,
            source, from_usage_id, created_by
        ) VALUES (
            v_usage_date, p_item_id, p_to_location_id, '(transfer)',
            'Transferred in on ' || v_usage_date::text || '.',
            p_qty_lb,
            CASE WHEN v_to_loc_row.any_null THEN NULL ELSE v_to_loc_row.usd END,
            v_to_loc_row.any_null,
            p_qty_lb, 'transfer_in', v_usage_id, auth.uid()
        ) RETURNING id INTO v_new_receipt;
    END IF;

    RETURN v_usage_id;
END
$fn$;


-- ---------------------------------------------------------------------
-- 6. post_feed_count - a variance means different things per item
-- ---------------------------------------------------------------------
-- Short of book:
--   count_variance_meaning = 'shrink'      -> one 'adjustment' usage,
--       charged to nobody. Discovery date has no relationship to which
--       cattle were on feed, so charging a lot would be arbitrary.
--   count_variance_meaning = 'consumption' -> the residual IS what was
--       consumed. Allocated across every open lot by head-days over the
--       window since the previous posted count for this location.
-- Over book (either meaning) -> a receipt at the bay's own last known cost.
-- Nothing is ever free.
CREATE OR REPLACE FUNCTION public.post_feed_count(p_count_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_c          record;
    v_line       record;
    v_item       record;
    v_book       numeric;
    v_var        numeric;
    v_last_cost  numeric;
    v_usage_id   uuid;
    v_receipt_id uuid;
    v_posted     integer := 0;

    v_prev_count date;
    v_period     date;
    v_total_hd   numeric;
    v_lot_ids    uuid[];
    v_hd         numeric[];
    v_floor      numeric[];
    v_rem        numeric[];
    v_n          integer;
    v_i          integer;
    v_cents      integer;
    v_share      numeric;
    v_order      integer[];
BEGIN
    SELECT * INTO v_c FROM public.feed_counts WHERE id = p_count_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'post_feed_count: count % not found.', p_count_id;
    END IF;
    IF v_c.status = 'posted' THEN
        RAISE EXCEPTION 'post_feed_count: this count was already posted. Start a new one.';
    END IF;

    -- The window a consumption variance covers: since the previous posted
    -- count on this location.
    SELECT max(c.count_date) INTO v_prev_count
      FROM public.feed_counts c
     WHERE c.location_id = v_c.location_id
       AND c.status = 'posted'
       AND c.count_date < v_c.count_date;

    FOR v_line IN
        SELECT * FROM public.feed_count_lines WHERE count_id = p_count_id
    LOOP
        SELECT * INTO v_item FROM public.feed_items WHERE id = v_line.item_id;

        SELECT COALESCE(SUM(qty_lb_remaining), 0) INTO v_book
          FROM public.feed_receipts
         WHERE item_id = v_line.item_id AND location_id = v_c.location_id;

        v_var := v_line.counted_qty_lb - v_book;
        v_usage_id := NULL;
        v_receipt_id := NULL;

        IF v_var < 0 AND v_item.count_variance_meaning = 'consumption' THEN
            -- ---------- mineral: the count IS the usage record ----------
            v_period := COALESCE(
                v_prev_count + 1,
                (SELECT min(r.receipt_date) FROM public.feed_receipts r
                  WHERE r.item_id = v_line.item_id AND r.location_id = v_c.location_id),
                v_c.count_date);
            IF v_period > v_c.count_date THEN
                v_period := v_c.count_date;
            END IF;

            SELECT array_agg(t.lot_id ORDER BY t.lot_id),
                   array_agg(t.head_days ORDER BY t.lot_id),
                   SUM(t.head_days)
              INTO v_lot_ids, v_hd, v_total_hd
              FROM (
                    SELECT d.lot_id, SUM(d.head_on_hand)::numeric AS head_days
                      FROM public.lot_daily_head d
                      JOIN public.lots l ON l.id = d.lot_id
                     WHERE d.as_of_date BETWEEN v_period AND v_c.count_date
                       AND l.lot_number NOT LIKE 'TEST\_%'
                       AND l.lot_number NOT LIKE 'TEST-%'
                     GROUP BY d.lot_id
                    HAVING SUM(d.head_on_hand) > 0
                   ) t;

            IF v_total_hd IS NULL OR v_total_hd <= 0 THEN
                -- Nothing to spread it over. Do NOT silently drop it: fall
                -- back to an adjustment so the pounds still leave the bay
                -- and the reason says why.
                v_usage_id := public.post_feed_usage(
                    p_item_id          => v_line.item_id,
                    p_from_location_id => v_c.location_id,
                    p_qty_lb           => -v_var,
                    p_destination_type => 'adjustment',
                    p_period_start     => v_period,
                    p_period_end       => v_c.count_date,
                    p_usage_date       => v_c.count_date,
                    p_source           => 'count',
                    p_reason           => 'Count ' || v_c.count_date::text
                                          || ' - consumption, but no head-days in the window to allocate over');
                v_posted := v_posted + 1;
            ELSE
                v_n := array_length(v_lot_ids, 1);

                -- Largest remainder, to the cent of a pound, so the parts
                -- sum EXACTLY to the variance. Not "round each and dump the
                -- residual on the last lot" - that always parks the error on
                -- whichever lot sorted last.
                v_floor := ARRAY[]::numeric[];
                v_rem   := ARRAY[]::numeric[];
                FOR v_i IN 1 .. v_n LOOP
                    v_share := (-v_var) * v_hd[v_i] / v_total_hd;
                    v_floor := v_floor || FLOOR(v_share * 100) / 100;
                    v_rem   := v_rem   || (v_share - FLOOR(v_share * 100) / 100);
                END LOOP;

                v_cents := ROUND(((-v_var) - (SELECT SUM(x) FROM unnest(v_floor) x)) * 100)::integer;

                SELECT array_agg(i ORDER BY v_rem[i] DESC, i) INTO v_order
                  FROM generate_series(1, v_n) i;

                FOR v_i IN 1 .. GREATEST(v_cents, 0) LOOP
                    v_floor[v_order[v_i]] := v_floor[v_order[v_i]] + 0.01;
                END LOOP;

                FOR v_i IN 1 .. v_n LOOP
                    IF v_floor[v_i] > 0 THEN
                        PERFORM public.post_feed_usage(
                            p_item_id          => v_line.item_id,
                            p_from_location_id => v_c.location_id,
                            p_qty_lb           => v_floor[v_i],
                            p_destination_type => 'lot',
                            p_lot_id           => v_lot_ids[v_i],
                            p_period_start     => v_period,
                            p_period_end       => v_c.count_date,
                            p_usage_date       => v_c.count_date,
                            p_source           => 'count',
                            p_reason           => 'Count ' || v_c.count_date::text
                                                  || ' - consumption allocated by head-days');
                        v_posted := v_posted + 1;
                    END IF;
                END LOOP;
                -- The line records the aggregate, not one of the splits.
                v_usage_id := NULL;
            END IF;

        ELSIF v_var < 0 THEN
            -- ---------- commodity: the residual is SHRINK ----------
            v_usage_id := public.post_feed_usage(
                p_item_id          => v_line.item_id,
                p_from_location_id => v_c.location_id,
                p_qty_lb           => -v_var,
                p_destination_type => 'adjustment',
                p_period_start     => v_c.count_date,
                p_period_end       => v_c.count_date,
                p_usage_date       => v_c.count_date,
                p_source           => 'count',
                p_reason           => 'Count ' || v_c.count_date::text || ' - short of book'
            );
            v_posted := v_posted + 1;

        ELSIF v_var > 0 THEN
            -- ---------- found feed, either meaning ----------
            SELECT r.unit_cost_per_lb INTO v_last_cost
              FROM public.feed_receipts r
             WHERE r.item_id = v_line.item_id AND r.location_id = v_c.location_id
               AND r.unit_cost_per_lb IS NOT NULL
             ORDER BY r.receipt_date DESC, r.created_at DESC LIMIT 1;

            IF v_last_cost IS NULL THEN
                SELECT r.unit_cost_per_lb INTO v_last_cost
                  FROM public.feed_receipts r
                 WHERE r.item_id = v_line.item_id AND r.unit_cost_per_lb IS NOT NULL
                 ORDER BY r.receipt_date DESC, r.created_at DESC LIMIT 1;
            END IF;

            INSERT INTO public.feed_receipts (
                receipt_date, item_id, location_id, vendor, notes,
                qty_lb, product_cost, cost_pending, qty_lb_remaining, source, created_by
            ) VALUES (
                v_c.count_date, v_line.item_id, v_c.location_id, '(count adjustment)',
                'Found by the count on ' || v_c.count_date::text || '.',
                v_var,
                CASE WHEN v_last_cost IS NULL THEN NULL ELSE ROUND(v_var * v_last_cost, 4) END,
                (v_last_cost IS NULL),
                v_var, 'count_adjustment', auth.uid()
            ) RETURNING id INTO v_receipt_id;
            v_posted := v_posted + 1;
        END IF;

        UPDATE public.feed_count_lines
           SET book_qty_lb           = v_book,
               variance_lb           = v_var,
               adjustment_usage_id   = v_usage_id,
               adjustment_receipt_id = v_receipt_id
         WHERE id = v_line.id;
    END LOOP;

    UPDATE public.feed_counts
       SET status = 'posted', posted_at = now(), posted_by = auth.uid()
     WHERE id = p_count_id;

    RETURN v_posted;
END
$fn$;


-- ---------------------------------------------------------------------
-- 7. Views
-- ---------------------------------------------------------------------

-- Which bays are overdue for a count. Flagged, never blocked.
DROP VIEW IF EXISTS public.feed_location_count_status;
CREATE VIEW public.feed_location_count_status
WITH (security_invoker = true) AS
SELECT
    l.id                AS location_id,
    l.name              AS location_name,
    l.is_active,
    l.is_bulk,
    l.count_interval_days,
    c.last_counted_on,
    CASE WHEN c.last_counted_on IS NULL THEN NULL
         ELSE (public.ranch_today() - c.last_counted_on) END       AS days_since_count,
    CASE
        WHEN l.count_interval_days IS NULL THEN false
        WHEN c.last_counted_on IS NULL     THEN true
        ELSE (public.ranch_today() - c.last_counted_on) > l.count_interval_days
    END                                                            AS is_overdue,
    COALESCE(oh.on_hand_lb, 0)                                     AS on_hand_lb
FROM public.feed_storage_locations l
LEFT JOIN LATERAL (
    SELECT max(fc.count_date) AS last_counted_on
      FROM public.feed_counts fc
     WHERE fc.location_id = l.id AND fc.status = 'posted'
) c ON true
LEFT JOIN LATERAL (
    SELECT SUM(r.qty_lb_remaining) AS on_hand_lb
      FROM public.feed_receipts r
     WHERE r.location_id = l.id AND r.qty_lb_remaining > 0
) oh ON true;

COMMENT ON VIEW public.feed_location_count_status IS
'Days since each bay was last counted, and whether that is past its target.
The app is the system of record for feed on hand only if the counts actually
happen; a bay quietly six months without one is otherwise indistinguishable
from one counted last week.';

-- A premix that went short. Its own signal, because the ingredients are
-- still on the books.
DROP VIEW IF EXISTS public.feed_premix_shorts;
CREATE VIEW public.feed_premix_shorts
WITH (security_invoker = true) AS
SELECT
    u.id            AS usage_id,
    u.usage_date,
    u.period_start,
    u.period_end,
    i.id            AS item_id,
    i.name          AS item_name,
    u.lot_id,
    u.from_location_id,
    fc.qty_lb       AS short_lb,
    fc.cost         AS short_cost
FROM public.feed_usage u
JOIN public.feed_items i         ON i.id = u.item_id
JOIN public.feed_usage_costs fc  ON fc.usage_id = u.id AND fc.is_short
WHERE i.is_premix;

COMMENT ON VIEW public.feed_premix_shorts IS
'A premix short is not an ordinary short. It means the batch was never
recorded and the ingredients are STILL ON THE BOOKS - two errors in opposite
directions, and the feed still allocates cleanly so nothing looks broken.';

-- Shrink by commodity: what the variance account is made of.
DROP VIEW IF EXISTS public.feed_shrink_by_commodity;
CREATE VIEW public.feed_shrink_by_commodity
WITH (security_invoker = true) AS
SELECT
    i.id                                        AS item_id,
    i.name                                      AS item_name,
    i.item_type,
    i.count_variance_meaning,
    date_trunc('month', u.usage_date)::date     AS month,
    SUM(CASE WHEN u.destination_type = 'adjustment' THEN u.qty_lb ELSE 0 END)   AS shrink_lb,
    SUM(CASE WHEN u.destination_type = 'adjustment'
             THEN COALESCE((SELECT SUM(c.cost) FROM public.feed_usage_costs c WHERE c.usage_id = u.id), 0)
             ELSE 0 END)                                                        AS shrink_usd,
    COUNT(*) FILTER (WHERE u.destination_type = 'adjustment')                   AS shrink_events
FROM public.feed_usage u
JOIN public.feed_items i ON i.id = u.item_id
WHERE u.source = 'count'
  AND u.destination_type = 'adjustment'
GROUP BY i.id, i.name, i.item_type, i.count_variance_meaning, date_trunc('month', u.usage_date);

COMMENT ON VIEW public.feed_shrink_by_commodity IS
'Shrink per commodity per month, from count adjustments only. This is what
the two-sided variance account is made of. Found feed lands on the receipt
side and credits the same account, so a balance near zero means the
allowances are about right.';

REVOKE ALL ON public.feed_location_count_status FROM PUBLIC, anon;
REVOKE ALL ON public.feed_premix_shorts        FROM PUBLIC, anon;
REVOKE ALL ON public.feed_shrink_by_commodity  FROM PUBLIC, anon;
GRANT SELECT ON public.feed_location_count_status TO authenticated;
GRANT SELECT ON public.feed_premix_shorts        TO authenticated;
GRANT SELECT ON public.feed_shrink_by_commodity  TO authenticated;


-- ---------------------------------------------------------------------
-- 8. Verify
-- ---------------------------------------------------------------------
DO $verify$
DECLARE
    v_missing text := '';
    v_cnt     integer;
BEGIN
    -- columns
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='feed_items'
                      AND column_name='count_variance_meaning') THEN
        v_missing := v_missing || ' feed_items.count_variance_meaning';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='feed_receipts'
                      AND column_name='gross_qty_lb') THEN
        v_missing := v_missing || ' feed_receipts.gross_qty_lb';
    END IF;
    IF to_regclass('public.ranch_settings') IS NULL THEN
        v_missing := v_missing || ' ranch_settings';
    END IF;

    -- feed_items must still have NO price column. The whole module rests on
    -- price living on the receipt and freezing into feed_usage_costs.
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema='public' AND table_name='feed_items'
                  AND column_name IN ('cost_per_lb','price_per_lb','unit_cost','cost_per_ton')) THEN
        RAISE EXCEPTION 'feed_items has acquired a price column. Price lives on the receipt and freezes on consumption.';
    END IF;

    -- every new view must be security_invoker
    SELECT count(*) INTO v_cnt
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname='public' AND c.relkind='v'
       AND c.relname IN ('feed_location_count_status','feed_premix_shorts','feed_shrink_by_commodity')
       AND COALESCE(array_to_string(c.reloptions,','),'') NOT LIKE '%security_invoker=true%';
    IF v_cnt > 0 THEN
        RAISE EXCEPTION '% new view(s) are missing security_invoker. Without it a view bypasses RLS entirely.', v_cnt;
    END IF;

    -- nothing granted to anon
    SELECT count(*) INTO v_cnt
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname='public'
       AND c.relname IN ('ranch_settings','feed_location_count_status',
                         'feed_premix_shorts','feed_shrink_by_commodity')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_cnt > 0 THEN
        RAISE EXCEPTION '% new object(s) are readable by anon.', v_cnt;
    END IF;

    -- ranch_settings has RLS AND policies
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname='ranch_settings' AND relrowsecurity) THEN
        v_missing := v_missing || ' ranch_settings-RLS';
    END IF;
    SELECT count(*) INTO v_cnt FROM pg_policies WHERE schemaname='public' AND tablename='ranch_settings';
    IF v_cnt < 3 THEN
        v_missing := v_missing || ' ranch_settings-policies';
    END IF;

    -- exactly one post_feed_usage: PostgREST resolves an RPC by argument
    -- names and two overloads make that ambiguous.
    SELECT count(*) INTO v_cnt FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='post_feed_usage';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION 'Expected exactly one post_feed_usage, found %.', v_cnt;
    END IF;

    IF v_missing <> '' THEN
        RAISE EXCEPTION 'Feed decisions migration incomplete:%', v_missing;
    END IF;

    SELECT count(*) INTO v_cnt FROM public.feed_items WHERE count_variance_meaning='consumption';
    RAISE NOTICE 'Feed decisions migration applied. ranch_settings.feed_direct_from = %. % item(s) set to consumption.',
        (SELECT feed_direct_from FROM public.ranch_settings), v_cnt;
END
$verify$;

commit;
