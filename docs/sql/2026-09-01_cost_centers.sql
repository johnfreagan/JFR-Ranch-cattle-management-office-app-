-- =====================================================================
-- Cost centres: feed that leaves inventory for something that is not a lot
-- =====================================================================
-- Commodities go to the cowherd, the bulls, the horses. The pounds are
-- really gone and the money is really spent, but there is no stocker lot
-- to carry it, and Redwing wants it as a journal entry against its own
-- account rather than against a production centre.
--
-- WHY NOT REUSE 'adjustment': that destination means the VARIANCE ACCOUNT,
-- whose balance is supposed to answer "how good are the shrink
-- allowances". Feeding the cowherd is real, deliberate consumption. Put it
-- there and the one number that measures shrink accuracy stops meaning
-- anything - the same argument that keeps found feed out of it.
--
-- WHY NOT REUSE 'pasture': a cowherd is not a pasture, and a pasture
-- carries no Redwing account.
--
-- WHAT COMES FREE: lot_feed_daily and feed_cost_unallocated both read
-- ONLY destination_type = 'lot'. A cost-centre usage therefore draws its
-- FIFO layer, freezes its cost, and contributes nothing to any lot's cost
-- of gain without either view being touched.
--
-- Apply in the Supabase SQL editor.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. The cost centres themselves
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.cost_centers (
    id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name                      text NOT NULL,
    redwing_account           text,
    redwing_production_center text,
    profit_center             text,
    notes                     text,
    is_active                 boolean NOT NULL DEFAULT true,
    created_at                timestamptz NOT NULL DEFAULT now(),
    updated_at                timestamptz NOT NULL DEFAULT now(),
    created_by                uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

-- Case-insensitive, so "Cowherd" and "cowherd" cannot both exist. The
-- vendor seed learned this the hard way: a unique index on lower(name)
-- and a loader that deduped on the raw string collide at the worst moment.
CREATE UNIQUE INDEX IF NOT EXISTS cost_centers_name_uniq
    ON public.cost_centers (lower(name));

DROP TRIGGER IF EXISTS cost_centers_touch ON public.cost_centers;
CREATE TRIGGER cost_centers_touch BEFORE UPDATE ON public.cost_centers
    FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

ALTER TABLE public.cost_centers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cost_centers_select ON public.cost_centers;
DROP POLICY IF EXISTS cost_centers_insert ON public.cost_centers;
DROP POLICY IF EXISTS cost_centers_update ON public.cost_centers;
DROP POLICY IF EXISTS cost_centers_delete ON public.cost_centers;

-- Same shape as feed_items: books-readers see them, office and owner
-- maintain them, owner alone deletes.
CREATE POLICY cost_centers_select ON public.cost_centers FOR SELECT
    USING (public.can_read_books());
CREATE POLICY cost_centers_insert ON public.cost_centers FOR INSERT
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));
CREATE POLICY cost_centers_update ON public.cost_centers FOR UPDATE
    USING (public.current_user_role() = ANY (ARRAY['owner','office']))
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));
CREATE POLICY cost_centers_delete ON public.cost_centers FOR DELETE
    USING (public.current_user_role() = 'owner');


-- ---------------------------------------------------------------------
-- 2. feed_usage learns the new destination
-- ---------------------------------------------------------------------
ALTER TABLE public.feed_usage
    ADD COLUMN IF NOT EXISTS cost_center_id uuid
        REFERENCES public.cost_centers(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS feed_usage_cost_center_idx
    ON public.feed_usage (cost_center_id) WHERE cost_center_id IS NOT NULL;

ALTER TABLE public.feed_usage DROP CONSTRAINT IF EXISTS feed_usage_destination_type_check;
ALTER TABLE public.feed_usage ADD CONSTRAINT feed_usage_destination_type_check
    CHECK (destination_type = ANY (ARRAY['lot','pasture','adjustment','transfer','batch','cost_center']));

-- The shape check also pins cost_center_id to NULL on every other
-- destination, so a lot feed-out cannot quietly carry a stray cost centre
-- and land on two reports.
ALTER TABLE public.feed_usage DROP CONSTRAINT IF EXISTS feed_usage_destination_shape;
ALTER TABLE public.feed_usage ADD CONSTRAINT feed_usage_destination_shape CHECK (
       (destination_type = 'lot'         AND lot_id IS NOT NULL AND to_location_id IS NULL AND cost_center_id IS NULL)
    OR (destination_type = 'pasture'     AND pasture_id IS NOT NULL AND to_location_id IS NULL AND cost_center_id IS NULL)
    OR (destination_type = 'adjustment'  AND to_location_id IS NULL AND cost_center_id IS NULL)
    OR (destination_type = 'transfer'    AND to_location_id IS NOT NULL AND cost_center_id IS NULL)
    OR (destination_type = 'batch'       AND to_location_id IS NULL AND cost_center_id IS NULL)
    OR (destination_type = 'cost_center' AND cost_center_id IS NOT NULL AND to_location_id IS NULL
                                         AND lot_id IS NULL AND pasture_id IS NULL)
);


-- ---------------------------------------------------------------------
-- 3. post_feed_usage gains p_cost_center_id
-- ---------------------------------------------------------------------
-- DROPPED AND RECREATED, NOT OVERLOADED. PostgREST resolves an RPC by its
-- ARGUMENT NAMES; two overloads make that ambiguous and the call fails at
-- runtime with a message that does not say so. The verify block asserts
-- exactly one remains.
DROP FUNCTION IF EXISTS public.post_feed_usage(uuid, uuid, numeric, text, date, date, uuid, uuid, uuid, date, text, text, text, text, uuid);
DROP FUNCTION IF EXISTS public.post_feed_usage(uuid, uuid, numeric, text, date, date, uuid, uuid, uuid, date, text, text, text, text, uuid, uuid);

CREATE FUNCTION public.post_feed_usage(
    p_item_id uuid,
    p_from_location_id uuid,
    p_qty_lb numeric,
    p_destination_type text,
    p_period_start date DEFAULT NULL,
    p_period_end date DEFAULT NULL,
    p_lot_id uuid DEFAULT NULL,
    p_pasture_id uuid DEFAULT NULL,
    p_to_location_id uuid DEFAULT NULL,
    p_usage_date date DEFAULT NULL,
    p_source text DEFAULT 'manual',
    p_pb_row_key text DEFAULT NULL,
    p_reason text DEFAULT NULL,
    p_notes text DEFAULT NULL,
    p_batch_id uuid DEFAULT NULL,
    p_cost_center_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
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

    IF p_destination_type = 'cost_center' AND p_cost_center_id IS NULL THEN
        RAISE EXCEPTION 'post_feed_usage: a cost_center destination needs a cost centre.';
    END IF;

    INSERT INTO public.feed_usage (
        usage_date, period_start, period_end, item_id, from_location_id,
        destination_type, lot_id, pasture_id, to_location_id, cost_center_id, qty_lb,
        source, pb_row_key, reason, notes, batch_id, created_by
    ) VALUES (
        v_usage_date, v_start, v_end, p_item_id, p_from_location_id,
        p_destination_type, p_lot_id, p_pasture_id, p_to_location_id, p_cost_center_id, p_qty_lb,
        p_source, p_pb_row_key, p_reason, p_notes, p_batch_id, auth.uid()
    ) RETURNING id INTO v_usage_id;

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
$function$;

REVOKE ALL ON FUNCTION public.post_feed_usage(uuid,uuid,numeric,text,date,date,uuid,uuid,uuid,date,text,text,text,text,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.post_feed_usage(uuid,uuid,numeric,text,date,date,uuid,uuid,uuid,date,text,text,text,text,uuid,uuid) TO authenticated;


-- ---------------------------------------------------------------------
-- 4. What the journal entry is built from
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS public.feed_cost_center_usage;
CREATE VIEW public.feed_cost_center_usage WITH (security_invoker = true) AS
SELECT u.id                AS usage_id,
       u.usage_date,
       u.period_start,
       u.period_end,
       cc.id               AS cost_center_id,
       cc.name             AS cost_center,
       cc.redwing_account,
       cc.redwing_production_center,
       cc.profit_center,
       i.id                AS item_id,
       i.name              AS item_name,
       i.redwing_template_field AS box,
       l.name              AS from_location,
       u.qty_lb,
       COALESCE(c.cost, 0) AS cost_usd,
       COALESCE(c.pending_lines, 0) AS pending_cost_lines,
       u.is_short,
       u.reason,
       u.notes
  FROM public.feed_usage u
  JOIN public.cost_centers cc ON cc.id = u.cost_center_id
  JOIN public.feed_items i    ON i.id = u.item_id
  JOIN public.feed_storage_locations l ON l.id = u.from_location_id
  LEFT JOIN LATERAL (
        SELECT SUM(fc.cost) AS cost,
               count(*) FILTER (WHERE fc.cost IS NULL) AS pending_lines
          FROM public.feed_usage_costs fc WHERE fc.usage_id = u.id) c ON true
 WHERE u.destination_type = 'cost_center';

REVOKE ALL ON public.feed_cost_center_usage FROM PUBLIC;
GRANT SELECT ON public.feed_cost_center_usage TO authenticated;


-- ---------------------------------------------------------------------
-- 4b. feed_usage_detail learns the cost centre
-- ---------------------------------------------------------------------
-- The Redwing screen reads this one view for a whole period. Joining the
-- centre on in the browser instead would mean the report and the view
-- disagreeing about what a usage row is, which is how a destination goes
-- missing from a posting without anybody noticing.
DROP VIEW IF EXISTS public.feed_usage_detail;
CREATE VIEW public.feed_usage_detail WITH (security_invoker = true) AS
SELECT u.id AS usage_id,
       u.usage_date, u.period_start, u.period_end,
       (u.period_end - u.period_start) + 1 AS period_days,
       u.item_id, i.name AS item_name, i.item_type,
       i.redwing_template_field AS box,
       u.from_location_id, fl.name AS from_location_name,
       u.destination_type,
       u.lot_id, lo.lot_number,
       u.pasture_id, pa.name AS pasture_name,
       u.to_location_id, tl.name AS to_location_name,
       u.cost_center_id,
       cc.name                      AS cost_center,
       cc.redwing_account,
       cc.redwing_production_center,
       u.qty_lb, u.source, u.is_short, u.cost_pending, u.reason, u.notes,
       COALESCE(c.cost, 0) AS cost_usd,
       CASE WHEN u.qty_lb > 0 THEN COALESCE(c.cost, 0) / u.qty_lb ELSE NULL END AS cost_per_lb,
       COALESCE(c.pending_lines, 0) AS pending_cost_lines,
       u.created_at
  FROM public.feed_usage u
  JOIN public.feed_items i ON i.id = u.item_id
  JOIN public.feed_storage_locations fl ON fl.id = u.from_location_id
  LEFT JOIN public.feed_storage_locations tl ON tl.id = u.to_location_id
  LEFT JOIN public.lots lo ON lo.id = u.lot_id
  LEFT JOIN public.pastures pa ON pa.id = u.pasture_id
  LEFT JOIN public.cost_centers cc ON cc.id = u.cost_center_id
  LEFT JOIN LATERAL (
        SELECT SUM(fc.cost) AS cost,
               count(*) FILTER (WHERE fc.cost IS NULL) AS pending_lines
          FROM public.feed_usage_costs fc WHERE fc.usage_id = u.id) c ON true;

REVOKE ALL ON public.feed_usage_detail FROM PUBLIC;
GRANT SELECT ON public.feed_usage_detail TO authenticated;


-- ---------------------------------------------------------------------
-- 5. Verify
-- ---------------------------------------------------------------------
DO $verify$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'public' AND p.proname = 'post_feed_usage';
    IF n <> 1 THEN
        RAISE EXCEPTION 'post_feed_usage must exist exactly once, found %. PostgREST resolves by argument name and cannot choose between overloads.', n;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
                    WHERE ns.nspname='public' AND p.proname='post_feed_usage'
                      AND pg_get_function_identity_arguments(p.oid) LIKE '%p_cost_center_id%') THEN
        RAISE EXCEPTION 'post_feed_usage is missing p_cost_center_id.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_views WHERE schemaname='public' AND viewname='feed_cost_center_usage') THEN
        RAISE EXCEPTION 'feed_cost_center_usage was not created.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='feed_usage_detail'
                      AND column_name='cost_center') THEN
        RAISE EXCEPTION 'feed_usage_detail is missing the cost_center column.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname='feed_usage_detail'
                     AND relkind='v' AND reloptions @> ARRAY['security_invoker=true']) THEN
        RAISE EXCEPTION 'feed_usage_detail lost security_invoker = true when it was recreated.';
    END IF;

    -- Rule 3: a view without security_invoker runs as its owner and ignores RLS.
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname='feed_cost_center_usage'
                     AND relkind='v' AND reloptions @> ARRAY['security_invoker=true']) THEN
        RAISE EXCEPTION 'feed_cost_center_usage is missing security_invoker = true.';
    END IF;

    SELECT count(*) INTO n FROM pg_policy WHERE polrelid = 'public.cost_centers'::regclass;
    IF n <> 4 THEN
        RAISE EXCEPTION 'cost_centers should carry 4 policies, found %.', n;
    END IF;

    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.cost_centers'::regclass) THEN
        RAISE EXCEPTION 'RLS is not enabled on cost_centers.';
    END IF;

    IF has_table_privilege('anon', 'public.cost_centers', 'SELECT') THEN
        RAISE EXCEPTION 'anon can read cost_centers. Revoke it.';
    END IF;

    RAISE NOTICE 'Cost centres installed. post_feed_usage carries p_cost_center_id; feed_cost_center_usage is live.';
END
$verify$;

commit;
