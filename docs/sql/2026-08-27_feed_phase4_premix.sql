-- =====================================================================
-- Feed phase 4 (cost of gain) + premix batches
-- =====================================================================
-- 2026-08-27. Run AFTER docs/sql/2026-08-27_feed_inventory.sql.
-- Plan: docs/commodity-feed-inventory-plan.md
--
-- WHAT THIS BUILDS
--
--   A. lots.assumed_nonfeed_cog_per_day - the COG split, left NULL until
--      John has the number. While NULL the Closeout Actual column keeps
--      charging assumed COG unchanged and shows feed as its own line, with
--      a visible note that the two overlap. Per lot, not global.
--
--   B. lot_feed_daily / lot_feed_costs - feed cost spread across the
--      head-days inside each usage's period, then rolled to the lot.
--
--   C. feed_cost_unallocated - the exceptions list. A usage whose period
--      contains no head-days for its lot allocates to NOTHING, and silent
--      loss is the failure mode this module exists to prevent. It surfaces
--      here rather than evaporating.
--
--   D. Premix batches - many commodities in, one premix out, into the
--      premix's own bay. The existing transfer generalised.
--
-- WHY THE SPREAD IS BY HEAD-DAYS AND NOT BY DATE
--
-- A weekly feed ticket is not a one-day cost. Charging it on period_end
-- hands a lot that shipped Wednesday two days of feed it never ate, and a
-- lot that arrived Thursday a week of it. Cost is divided across the days
-- in [period_start, period_end] in proportion to the head standing on each
-- of those days. Same reason the app writes one sales row per lot per DAY.
--
-- HEAD-DAYS COME FROM lot_daily_head, THE VIEW. Never lot_head_days(uuid,
-- date), which anchors on invoice dates and read 29% low on 36-27.
--
-- PREMIX COSTING DOES NOT ADD A SECOND PATH
--
-- A batch consumes its inputs through post_feed_usage like anything else,
-- so their cost freezes exactly as it always does. The summed dollars then
-- become ONE ordinary feed_receipts layer for the premix. From that point
-- the premix is an item like corn - fed, counted and reversed by the code
-- that already exists.
--
-- YIELD: output pounds = sum of input pounds (John's call, 2026-08-27,
-- against the recommendation to weigh the output). output_qty_lb is a real
-- stored column that DEFAULTS to that sum rather than being derived, so
-- weighing a batch later is a form field and not a migration. The cost of
-- the choice: real spillage inflates on-hand premix permanently and shows
-- up as shrink at count time instead of as a known yield.
--
-- IDEMPOTENT. Safe to run more than once.
-- APPLY: paste into the Supabase SQL editor.
-- =====================================================================

begin;

DO $pre$
BEGIN
    IF to_regclass('public.feed_usage') IS NULL OR to_regclass('public.feed_receipts') IS NULL THEN
        RAISE EXCEPTION 'The feed tables are missing. Apply 2026-08-27_feed_inventory.sql first.';
    END IF;
    IF to_regclass('public.lot_daily_head') IS NULL THEN
        RAISE EXCEPTION 'lot_daily_head is missing - the whole head-day spread depends on it.';
    END IF;
END
$pre$;


-- ---------------------------------------------------------------------
-- A. The COG split, deferred
-- ---------------------------------------------------------------------
-- NULL means "not known yet", and the app treats that as option A: feed
-- shows on its own line, assumed COG keeps running, and the closeout says
-- out loud that the two overlap. An overlap you can see beats one you
-- cannot. Setting this on a lot switches that lot to option C. Nothing is
-- recomputed retroactively - lots that closed under the assumed rate stay
-- closed under it.
-- ---------------------------------------------------------------------
ALTER TABLE public.lots
    ADD COLUMN IF NOT EXISTS assumed_nonfeed_cog_per_day numeric
        CHECK (assumed_nonfeed_cog_per_day IS NULL OR assumed_nonfeed_cog_per_day >= 0);

COMMENT ON COLUMN public.lots.assumed_nonfeed_cog_per_day IS
    'Non-feed share of cost of gain, $/head/day. NULL = not split yet; the '
    'closeout then charges assumed_cog_per_day unchanged and flags the overlap '
    'with actual feed. Set it and this lot charges actual feed + this rate.';


-- ---------------------------------------------------------------------
-- D1. Premix recipes - stored, fixed, and they only PRE-FILL
-- ---------------------------------------------------------------------
-- The formula is authoritative for what is ABOUT to be mixed. The batch
-- record is authoritative for what WAS mixed. A recipe consulted at read
-- time would mean editing it next spring rewrites what every batch since
-- January was made of - the protocol trap in feed form.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.feed_recipes (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name            text NOT NULL,
    output_item_id  uuid NOT NULL REFERENCES public.feed_items(id) ON DELETE RESTRICT,
    batch_size_lb   numeric CHECK (batch_size_lb IS NULL OR batch_size_lb > 0),
    is_active       boolean NOT NULL DEFAULT true,
    notes           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS feed_recipes_name_uniq ON public.feed_recipes (lower(name));

CREATE TABLE IF NOT EXISTS public.feed_recipe_lines (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    recipe_id         uuid NOT NULL REFERENCES public.feed_recipes(id) ON DELETE CASCADE,
    input_item_id     uuid NOT NULL REFERENCES public.feed_items(id) ON DELETE RESTRICT,
    qty_lb_per_batch  numeric NOT NULL CHECK (qty_lb_per_batch > 0),
    sort_order        integer NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT feed_recipe_lines_one_per_item UNIQUE (recipe_id, input_item_id)
);
CREATE INDEX IF NOT EXISTS feed_recipe_lines_recipe_idx ON public.feed_recipe_lines (recipe_id);


-- ---------------------------------------------------------------------
-- D2. feed_batches - one mix
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.feed_batches (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_date           date NOT NULL,
    output_item_id       uuid NOT NULL REFERENCES public.feed_items(id) ON DELETE RESTRICT,
    output_location_id   uuid NOT NULL REFERENCES public.feed_storage_locations(id) ON DELETE RESTRICT,
    -- Stored, not derived. Defaults to the sum of the inputs; the day a
    -- batch gets weighed for real this is where the weight goes.
    output_qty_lb        numeric NOT NULL CHECK (output_qty_lb > 0),
    input_qty_lb         numeric NOT NULL CHECK (input_qty_lb > 0),
    input_cost_usd       numeric,
    recipe_id            uuid REFERENCES public.feed_recipes(id) ON DELETE SET NULL,
    notes                text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid REFERENCES auth.users(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS feed_batches_date_idx ON public.feed_batches (batch_date DESC);
CREATE INDEX IF NOT EXISTS feed_batches_item_idx ON public.feed_batches (output_item_id);

-- Wire the batch into the ledger and the layers.
ALTER TABLE public.feed_usage
    ADD COLUMN IF NOT EXISTS batch_id uuid REFERENCES public.feed_batches(id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS feed_usage_batch_idx ON public.feed_usage (batch_id) WHERE batch_id IS NOT NULL;

ALTER TABLE public.feed_receipts
    ADD COLUMN IF NOT EXISTS from_batch_id uuid REFERENCES public.feed_batches(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS feed_receipts_from_batch_idx
    ON public.feed_receipts (from_batch_id) WHERE from_batch_id IS NOT NULL;

-- 'batch' joins the destination enum; 'batch_out' joins the receipt source.
DO $enums$
BEGIN
    ALTER TABLE public.feed_usage DROP CONSTRAINT IF EXISTS feed_usage_destination_type_check;
    ALTER TABLE public.feed_usage ADD CONSTRAINT feed_usage_destination_type_check
        CHECK (destination_type IN ('lot','pasture','adjustment','transfer','batch'));

    ALTER TABLE public.feed_usage DROP CONSTRAINT IF EXISTS feed_usage_destination_shape;
    ALTER TABLE public.feed_usage ADD CONSTRAINT feed_usage_destination_shape CHECK (
        (destination_type = 'lot'        AND lot_id IS NOT NULL AND to_location_id IS NULL)
     OR (destination_type = 'pasture'    AND pasture_id IS NOT NULL AND to_location_id IS NULL)
     OR (destination_type = 'adjustment' AND to_location_id IS NULL)
     OR (destination_type = 'transfer'   AND to_location_id IS NOT NULL)
     OR (destination_type = 'batch'      AND to_location_id IS NULL)
    );

    ALTER TABLE public.feed_receipts DROP CONSTRAINT IF EXISTS feed_receipts_source_check;
    ALTER TABLE public.feed_receipts ADD CONSTRAINT feed_receipts_source_check
        CHECK (source IN ('purchase','count_adjustment','transfer_in','batch_out'));
END
$enums$;

DO $trg2$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['feed_recipes','feed_batches']
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_touch_updated_at', t);
        EXECUTE format(
            'CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at()',
            t || '_touch_updated_at', t);
    END LOOP;
END
$trg2$;


-- ---------------------------------------------------------------------
-- RLS for the three new tables - office + owner, owner-only delete
-- ---------------------------------------------------------------------
ALTER TABLE public.feed_recipes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_recipe_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_batches      ENABLE ROW LEVEL SECURITY;

DO $pol2$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['feed_recipes','feed_recipe_lines','feed_batches']
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_select', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_insert', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_update', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_delete', t);
        EXECUTE format($f$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
            USING (public.current_user_role() = ANY (ARRAY['owner','office']))$f$, t || '_select', t);
        EXECUTE format($f$CREATE POLICY %I ON public.%I FOR INSERT TO authenticated
            WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']))$f$, t || '_insert', t);
        EXECUTE format($f$CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated
            USING (public.current_user_role() = ANY (ARRAY['owner','office']))
            WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']))$f$, t || '_update', t);
        EXECUTE format($f$CREATE POLICY %I ON public.%I FOR DELETE TO authenticated
            USING (public.current_user_role() = 'owner')$f$, t || '_delete', t);
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', t);
        EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    END LOOP;
END
$pol2$;


-- ---------------------------------------------------------------------
-- post_feed_usage gains p_batch_id
-- ---------------------------------------------------------------------
-- DROP and recreate rather than overload: PostgREST resolves an RPC by the
-- set of argument NAMES it is given, and two overloads of the same name
-- make that ambiguous. One function, one signature.
-- The new parameter is last and defaults to NULL, so every existing caller
-- - the app's feed-out sheet and post_feed_count - is unaffected.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.post_feed_usage(uuid,uuid,numeric,text,date,date,uuid,uuid,uuid,date,text,text,text,text);

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
        RAISE EXCEPTION 'post_feed_usage: quantity must be greater than zero (got %).', p_qty_lb;
    END IF;

    v_usage_date := COALESCE(p_usage_date, public.ranch_today());
    v_start      := COALESCE(p_period_start, v_usage_date);
    v_end        := COALESCE(p_period_end,   v_start);

    IF v_end < v_start THEN
        RAISE EXCEPTION 'post_feed_usage: period_end (%) is before period_start (%).', v_end, v_start;
    END IF;
    IF p_destination_type = 'transfer' AND p_to_location_id = p_from_location_id THEN
        RAISE EXCEPTION 'post_feed_usage: a transfer to the same location is a no-op.';
    END IF;
    IF p_destination_type = 'batch' AND p_batch_id IS NULL THEN
        RAISE EXCEPTION 'post_feed_usage: a batch input needs a batch id. Call make_feed_batch().';
    END IF;

    INSERT INTO public.feed_usage (
        usage_date, period_start, period_end, item_id, from_location_id,
        destination_type, lot_id, pasture_id, to_location_id,
        qty_lb, source, pb_row_key, reason, notes, batch_id, created_by
    ) VALUES (
        v_usage_date, v_start, v_end, p_item_id, p_from_location_id,
        p_destination_type, p_lot_id, p_pasture_id, p_to_location_id,
        p_qty_lb, COALESCE(p_source,'manual'), p_pb_row_key, p_reason, p_notes,
        p_batch_id, auth.uid()
    ) RETURNING id INTO v_usage_id;

    FOR layer_rec IN
        SELECT id, qty_lb_remaining, unit_cost_per_lb, cost_pending
        FROM public.feed_receipts
        WHERE item_id = p_item_id AND location_id = p_from_location_id AND qty_lb_remaining > 0
        ORDER BY receipt_date, created_at
        FOR UPDATE
    LOOP
        EXIT WHEN v_remaining <= 0;
        v_take := LEAST(v_remaining, layer_rec.qty_lb_remaining);
        INSERT INTO public.feed_usage_costs (usage_id, receipt_id, qty_lb, unit_cost_per_lb, cost)
        VALUES (v_usage_id, layer_rec.id, v_take, layer_rec.unit_cost_per_lb,
                CASE WHEN layer_rec.unit_cost_per_lb IS NULL THEN NULL
                     ELSE ROUND(v_take * layer_rec.unit_cost_per_lb, 4) END);
        IF layer_rec.unit_cost_per_lb IS NULL THEN v_pending := true; END IF;
        UPDATE public.feed_receipts SET qty_lb_remaining = qty_lb_remaining - v_take
         WHERE id = layer_rec.id;
        v_remaining := v_remaining - v_take;
    END LOOP;

    IF v_remaining > 0 THEN
        v_short := true;
        SELECT r.unit_cost_per_lb INTO v_last_cost FROM public.feed_receipts r
        WHERE r.item_id = p_item_id AND r.location_id = p_from_location_id
          AND r.unit_cost_per_lb IS NOT NULL
        ORDER BY r.receipt_date DESC, r.created_at DESC LIMIT 1;
        IF v_last_cost IS NULL THEN
            SELECT r.unit_cost_per_lb INTO v_last_cost FROM public.feed_receipts r
            WHERE r.item_id = p_item_id AND r.unit_cost_per_lb IS NOT NULL
            ORDER BY r.receipt_date DESC, r.created_at DESC LIMIT 1;
        END IF;
        INSERT INTO public.feed_usage_costs (usage_id, receipt_id, qty_lb, unit_cost_per_lb, cost, is_short)
        VALUES (v_usage_id, NULL, v_remaining, v_last_cost,
                CASE WHEN v_last_cost IS NULL THEN NULL ELSE ROUND(v_remaining * v_last_cost, 4) END, true);
        IF v_last_cost IS NULL THEN v_pending := true; END IF;
    END IF;

    IF p_destination_type = 'transfer' THEN
        SELECT SUM(qty_lb) AS lb, SUM(cost) AS cost,
               COUNT(*) FILTER (WHERE cost IS NULL) AS pending_lines
          INTO v_to_loc_row
        FROM public.feed_usage_costs WHERE usage_id = v_usage_id;
        INSERT INTO public.feed_receipts (
            receipt_date, item_id, location_id, vendor, notes,
            qty_lb, product_cost, cost_pending, qty_lb_remaining,
            source, from_usage_id, created_by
        ) VALUES (
            v_usage_date, p_item_id, p_to_location_id, '(transfer)', 'Transferred in.',
            p_qty_lb, v_to_loc_row.cost, (v_to_loc_row.pending_lines > 0), p_qty_lb,
            'transfer_in', v_usage_id, auth.uid()
        ) RETURNING id INTO v_new_receipt;
    END IF;

    IF v_short OR v_pending THEN
        UPDATE public.feed_usage SET is_short = v_short, cost_pending = v_pending
         WHERE id = v_usage_id;
    END IF;

    RETURN v_usage_id;
END
$fn$;


-- ---------------------------------------------------------------------
-- D3. make_feed_batch - many commodities in, one premix out
-- ---------------------------------------------------------------------
-- p_inputs is a jsonb array:
--   [{"item_id":"...","location_id":"...","qty_lb":4000}, ...]
--
-- Every input goes through post_feed_usage, so its cost freezes exactly as
-- it always does. The summed dollars become ONE ordinary layer for the
-- premix. There is no second costing path.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.make_feed_batch(
    p_output_item_id      uuid,
    p_output_location_id  uuid,
    p_inputs              jsonb,
    p_batch_date          date DEFAULT NULL,
    p_output_qty_lb       numeric DEFAULT NULL,
    p_recipe_id           uuid DEFAULT NULL,
    p_notes               text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_batch_id   uuid;
    v_date       date;
    in_rec       record;
    v_in_lb      numeric := 0;
    v_in_cost    numeric := 0;
    v_pending    integer := 0;
    v_out_lb     numeric;
BEGIN
    IF p_inputs IS NULL OR jsonb_typeof(p_inputs) <> 'array' OR jsonb_array_length(p_inputs) = 0 THEN
        RAISE EXCEPTION 'make_feed_batch: give it at least one input.';
    END IF;

    v_date := COALESCE(p_batch_date, public.ranch_today());

    -- A premix made out of itself would consume the layer it is about to
    -- create. Cheap to forbid, confusing to debug.
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_inputs) e
        WHERE (e->>'item_id')::uuid = p_output_item_id
          AND (e->>'location_id')::uuid = p_output_location_id
    ) THEN
        RAISE EXCEPTION 'make_feed_batch: the output item cannot also be an input from the same location.';
    END IF;

    INSERT INTO public.feed_batches (
        batch_date, output_item_id, output_location_id,
        output_qty_lb, input_qty_lb, recipe_id, notes, created_by)
    VALUES (v_date, p_output_item_id, p_output_location_id, 1, 1, p_recipe_id, p_notes, auth.uid())
    RETURNING id INTO v_batch_id;

    FOR in_rec IN
        SELECT (e->>'item_id')::uuid      AS item_id,
               (e->>'location_id')::uuid  AS location_id,
               (e->>'qty_lb')::numeric    AS qty_lb
        FROM jsonb_array_elements(p_inputs) e
    LOOP
        IF in_rec.item_id IS NULL OR in_rec.location_id IS NULL THEN
            RAISE EXCEPTION 'make_feed_batch: every input needs an item and a location.';
        END IF;
        IF in_rec.qty_lb IS NULL OR in_rec.qty_lb <= 0 THEN
            RAISE EXCEPTION 'make_feed_batch: every input needs pounds greater than zero.';
        END IF;

        PERFORM public.post_feed_usage(
            p_item_id          => in_rec.item_id,
            p_from_location_id => in_rec.location_id,
            p_qty_lb           => in_rec.qty_lb,
            p_destination_type => 'batch',
            p_period_start     => v_date,
            p_period_end       => v_date,
            p_usage_date       => v_date,
            p_source           => 'manual',
            p_reason           => 'Mixed into a batch',
            p_batch_id         => v_batch_id);

        v_in_lb := v_in_lb + in_rec.qty_lb;
    END LOOP;

    SELECT COALESCE(SUM(fc.cost), 0),
           COUNT(*) FILTER (WHERE fc.cost IS NULL)
      INTO v_in_cost, v_pending
    FROM public.feed_usage_costs fc
    JOIN public.feed_usage u ON u.id = fc.usage_id
    WHERE u.batch_id = v_batch_id;

    -- Yield: output = sum of inputs unless a real weight is supplied.
    v_out_lb := COALESCE(p_output_qty_lb, v_in_lb);
    IF v_out_lb <= 0 THEN
        RAISE EXCEPTION 'make_feed_batch: output pounds must be greater than zero.';
    END IF;

    UPDATE public.feed_batches
       SET output_qty_lb = v_out_lb, input_qty_lb = v_in_lb,
           input_cost_usd = CASE WHEN v_pending > 0 THEN NULL ELSE v_in_cost END
     WHERE id = v_batch_id;

    INSERT INTO public.feed_receipts (
        receipt_date, item_id, location_id, vendor, ticket_number, notes,
        qty_lb, product_cost, cost_pending, qty_lb_remaining,
        source, from_batch_id, created_by)
    VALUES (
        v_date, p_output_item_id, p_output_location_id, '(batch)', 'BATCH',
        'Mixed from ' || jsonb_array_length(p_inputs) || ' ingredient(s).',
        v_out_lb,
        CASE WHEN v_pending > 0 THEN NULL ELSE v_in_cost END,
        (v_pending > 0),
        v_out_lb, 'batch_out', v_batch_id, auth.uid());

    RETURN v_batch_id;
END
$fn$;


-- ---------------------------------------------------------------------
-- D4. delete_feed_batch - unmix
-- ---------------------------------------------------------------------
-- Refuses once any of the premix has been fed, for the same reason
-- delete_feed_receipt does: those pounds carry frozen costs downstream and
-- orphaning them is the disaster this module exists to prevent.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_feed_batch(p_batch_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_used  numeric;
    u_rec   record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.feed_batches WHERE id = p_batch_id) THEN
        RAISE EXCEPTION 'delete_feed_batch: batch % not found.', p_batch_id;
    END IF;

    SELECT COALESCE(SUM(qty_lb - qty_lb_remaining), 0) INTO v_used
    FROM public.feed_receipts WHERE from_batch_id = p_batch_id;

    IF v_used > 0 THEN
        RAISE EXCEPTION
            'delete_feed_batch: % lb of this batch has already been fed or moved. Reverse that first.', v_used;
    END IF;

    DELETE FROM public.feed_receipts WHERE from_batch_id = p_batch_id;

    FOR u_rec IN SELECT id FROM public.feed_usage WHERE batch_id = p_batch_id
    LOOP
        PERFORM public.delete_feed_usage(u_rec.id);
    END LOOP;

    DELETE FROM public.feed_batches WHERE id = p_batch_id;
END
$fn$;


-- ---------------------------------------------------------------------
-- B. lot_feed_daily - the head-day spread
-- ---------------------------------------------------------------------
-- Each lot-destination usage is divided across the days in its period in
-- proportion to the head standing on each day. A week's corn entered on
-- Friday lands on the days the cattle actually ate it.
--
-- head_on_hand comes from lot_daily_head, the VIEW. Never the
-- lot_head_days(uuid,date) FUNCTION, which anchors on invoice dates and
-- read 29% low on 36-27 because the cattle landed Aug 11 and the invoices
-- weighted to Aug 19.
--
-- Batch inputs are excluded on purpose: their cost is already carried by
-- the premix layer they produced, and counting both would double it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.lot_feed_daily
WITH (security_invoker = true) AS
WITH lot_usage AS (
    SELECT u.id, u.lot_id, u.item_id, u.period_start, u.period_end, u.qty_lb,
           COALESCE(c.cost, 0) AS cost_usd
    FROM public.feed_usage u
    LEFT JOIN LATERAL (
        SELECT SUM(fc.cost) AS cost FROM public.feed_usage_costs fc WHERE fc.usage_id = u.id
    ) c ON true
    WHERE u.destination_type = 'lot' AND u.lot_id IS NOT NULL
),
spread AS (
    SELECT lu.id AS usage_id, lu.lot_id, lu.item_id,
           d.as_of_date AS day, d.head_on_hand,
           lu.cost_usd, lu.qty_lb,
           SUM(d.head_on_hand) OVER (PARTITION BY lu.id) AS window_head_days
    FROM lot_usage lu
    JOIN public.lot_daily_head d
      ON d.lot_id = lu.lot_id
     AND d.as_of_date BETWEEN lu.period_start AND lu.period_end
)
SELECT usage_id, lot_id, item_id, day, head_on_hand,
       cost_usd * head_on_hand / NULLIF(window_head_days, 0) AS cost_usd,
       qty_lb   * head_on_hand / NULLIF(window_head_days, 0) AS qty_lb
FROM spread
WHERE window_head_days > 0;

-- ---------------------------------------------------------------------
-- C. feed_cost_unallocated - nothing is allowed to vanish
-- ---------------------------------------------------------------------
-- A usage whose period contains no head-days for its lot cannot spread,
-- and the JOIN above would silently drop it. That is precisely the failure
-- this module is built to avoid, so it surfaces here instead: real dollars
-- charged to a lot that had no cattle standing in that window.
--
-- Usual causes: a period typed before the lot arrived or after it shipped,
-- or a period running past today (lot_daily_head stops at ranch_today()).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.feed_cost_unallocated
WITH (security_invoker = true) AS
SELECT u.id AS usage_id, u.usage_date, u.period_start, u.period_end,
       u.lot_id, l.lot_number, u.item_id, i.name AS item_name,
       u.qty_lb, COALESCE(c.cost, 0) AS cost_usd,
       CASE WHEN u.period_end > public.ranch_today()
            THEN 'period runs past today - head-days do not exist yet'
            ELSE 'no head-days for this lot inside the period' END AS why
FROM public.feed_usage u
JOIN public.lots l       ON l.id = u.lot_id
JOIN public.feed_items i ON i.id = u.item_id
LEFT JOIN LATERAL (
    SELECT SUM(fc.cost) AS cost FROM public.feed_usage_costs fc WHERE fc.usage_id = u.id
) c ON true
WHERE u.destination_type = 'lot' AND u.lot_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.lot_feed_daily fd WHERE fd.usage_id = u.id);

-- ---------------------------------------------------------------------
-- lot_feed_costs - the number this whole module exists to produce
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.lot_feed_costs
WITH (security_invoker = true) AS
SELECT
    ls.lot_id,
    ls.lot_number,
    ls.head_in,
    ls.head_current,
    COALESCE(f.qty_lb, 0)                                   AS feed_lb,
    COALESCE(f.cost_usd, 0)                                 AS feed_cost_usd,
    f.first_day,
    f.last_day,
    hd.head_days,
    CASE WHEN ls.head_in > 0     THEN COALESCE(f.cost_usd,0) / ls.head_in END       AS cost_per_head_in,
    CASE WHEN hd.head_days > 0   THEN COALESCE(f.cost_usd,0) / hd.head_days END     AS cost_per_head_day,
    CASE WHEN hd.head_days > 0   THEN COALESCE(f.qty_lb,0)   / hd.head_days END     AS lb_per_head_day,
    COALESCE(un.unallocated_usd, 0)                         AS unallocated_usd
FROM public.lot_status ls
LEFT JOIN LATERAL (
    SELECT SUM(fd.cost_usd) AS cost_usd, SUM(fd.qty_lb) AS qty_lb,
           MIN(fd.day) AS first_day, MAX(fd.day) AS last_day
    FROM public.lot_feed_daily fd WHERE fd.lot_id = ls.lot_id
) f ON true
LEFT JOIN LATERAL (
    SELECT SUM(d.head_on_hand) AS head_days
    FROM public.lot_daily_head d WHERE d.lot_id = ls.lot_id
) hd ON true
LEFT JOIN LATERAL (
    SELECT SUM(fu.cost_usd) AS unallocated_usd
    FROM public.feed_cost_unallocated fu WHERE fu.lot_id = ls.lot_id
) un ON true;

-- ---------------------------------------------------------------------
-- pasture_feed_allocation - how mineral reaches lots
-- ---------------------------------------------------------------------
-- Pasture-destination feed (mineral, and anything hand-entered to a
-- pasture) splits across the lots standing on that pasture during the
-- usage period, weighted by head x overlapping days.
--
-- CAVEAT, stated rather than hidden: this weights by
-- lot_pasture_assignments, which is the only record of WHICH lots were on
-- a pasture. CLAUDE.md warns that assignment history is not reliable for
-- whole-life head-day math - 37X's assignments start 2026-04-27 against a
-- first invoice of 2025-12-04. Over a one-week window it is the best
-- answer available; over a lot's lifetime it is not, which is why lot-
-- destination feed above never touches it. A pasture usage matching no
-- assignment produces no rows and shows up in feed_cost_unallocated_pasture.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.pasture_feed_allocation
WITH (security_invoker = true) AS
WITH pu AS (
    SELECT u.id, u.pasture_id, u.item_id, u.period_start, u.period_end, u.qty_lb,
           COALESCE(c.cost, 0) AS cost_usd
    FROM public.feed_usage u
    LEFT JOIN LATERAL (
        SELECT SUM(fc.cost) AS cost FROM public.feed_usage_costs fc WHERE fc.usage_id = u.id
    ) c ON true
    WHERE u.destination_type = 'pasture' AND u.pasture_id IS NOT NULL
),
overlap AS (
    SELECT pu.id AS usage_id, pu.pasture_id, pu.item_id, pu.cost_usd, pu.qty_lb,
           a.lot_id,
           a.head_count * (
               (LEAST(pu.period_end, COALESCE(a.moved_out, pu.period_end))
              - GREATEST(pu.period_start, a.moved_in)) + 1
           ) AS weight
    FROM pu
    JOIN public.lot_pasture_assignments a
      ON a.pasture_id = pu.pasture_id
     AND a.moved_in <= pu.period_end
     AND (a.moved_out IS NULL OR a.moved_out >= pu.period_start)
)
SELECT usage_id, pasture_id, lot_id, item_id,
       weight,
       cost_usd * weight / NULLIF(SUM(weight) OVER (PARTITION BY usage_id), 0) AS cost_usd,
       qty_lb   * weight / NULLIF(SUM(weight) OVER (PARTITION BY usage_id), 0) AS qty_lb
FROM overlap
WHERE weight > 0;

CREATE OR REPLACE VIEW public.pasture_feed_costs
WITH (security_invoker = true) AS
SELECT p.id AS pasture_id, p.name AS pasture_name, r.name AS ranch_name,
       p.usable_acres,
       SUM(pa.qty_lb)   AS feed_lb,
       SUM(pa.cost_usd) AS feed_cost_usd,
       COUNT(DISTINCT pa.lot_id) AS lots_served,
       CASE WHEN p.usable_acres > 0 THEN SUM(pa.cost_usd) / p.usable_acres END AS cost_per_acre
FROM public.pasture_feed_allocation pa
JOIN public.pastures p ON p.id = pa.pasture_id
LEFT JOIN public.ranches r ON r.id = p.ranch_id
GROUP BY p.id, p.name, r.name, p.usable_acres;

DO $vgrant2$
DECLARE v text;
BEGIN
    FOREACH v IN ARRAY ARRAY['lot_feed_daily','feed_cost_unallocated','lot_feed_costs',
                             'pasture_feed_allocation','pasture_feed_costs']
    LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', v);
        EXECUTE format('REVOKE ALL ON public.%I FROM anon', v);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', v);
    END LOOP;
END
$vgrant2$;

DO $fgrant2$
DECLARE sig text;
BEGIN
    FOREACH sig IN ARRAY ARRAY[
        'public.post_feed_usage(uuid,uuid,numeric,text,date,date,uuid,uuid,uuid,date,text,text,text,text,uuid)',
        'public.make_feed_batch(uuid,uuid,jsonb,date,numeric,uuid,text)',
        'public.delete_feed_batch(uuid)'
    ]
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', sig);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', sig);
    END LOOP;
END
$fgrant2$;


DO $verify2$
DECLARE t text; v text; n integer;
BEGIN
    FOREACH t IN ARRAY ARRAY['feed_recipes','feed_recipe_lines','feed_batches']
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace ns ON ns.oid=c.relnamespace
                       WHERE ns.nspname='public' AND c.relname=t AND c.relrowsecurity) THEN
            RAISE EXCEPTION 'RLS is not enabled on public.%', t;
        END IF;
        SELECT count(*) INTO n FROM pg_policies WHERE schemaname='public' AND tablename=t;
        IF n < 4 THEN RAISE EXCEPTION 'public.% has only % policies, expected 4.', t, n; END IF;
        IF has_table_privilege('anon','public.'||t,'SELECT') THEN
            RAISE EXCEPTION 'anon can SELECT public.%', t; END IF;
    END LOOP;

    FOREACH v IN ARRAY ARRAY['lot_feed_daily','feed_cost_unallocated','lot_feed_costs',
                             'pasture_feed_allocation','pasture_feed_costs']
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace ns ON ns.oid=c.relnamespace
                       WHERE ns.nspname='public' AND c.relname=v
                         AND c.reloptions @> ARRAY['security_invoker=true']) THEN
            RAISE EXCEPTION 'public.% lacks security_invoker.', v; END IF;
        IF has_table_privilege('anon','public.'||v,'SELECT') THEN
            RAISE EXCEPTION 'anon can SELECT public.% view.', v; END IF;
    END LOOP;

    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
        WHERE ns.nspname='public' AND p.proname='post_feed_usage') <> 1 THEN
        RAISE EXCEPTION 'post_feed_usage is overloaded - PostgREST cannot resolve it by argument names.';
    END IF;

    RAISE NOTICE 'Feed phase 4 + premix: 3 tables, 5 views, 3 functions, lots.assumed_nonfeed_cog_per_day. Verified.';
END
$verify2$;

commit;
