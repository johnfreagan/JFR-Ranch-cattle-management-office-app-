-- =====================================================================
-- Bulk feeders: called, mixed, delivered by allocation (2026-09-06)
-- Design: docs/feed-truck-integration-scope.md, D25
-- =====================================================================
-- There is no scale on the grain cart, so the mixer is the only weight in
-- the chain. A bulk pasture is CALLED in pounds; the load's actual mixed
-- pounds are then allocated across the pastures actually filled, pro-rata
-- to the call, largest-remainder so the parts sum exactly to what left the
-- barn. The result lands in ordinary feed_drops rows, so post_feed_load,
-- head math and cost of gain need no special case.
--
-- Three columns, no new tables:
--   pasture_feed_setup.feeder_capacity_lb  total across the feeders there
--   feed_drops.method / called_lb          how the pounds were measured
--   feed_loads.delivery_mode               which flow the truck ran
--
-- Apply in the Supabase SQL editor. Idempotent.
-- =====================================================================

ALTER TABLE public.pasture_feed_setup
    ADD COLUMN IF NOT EXISTS feeder_capacity_lb numeric
        CHECK (feeder_capacity_lb IS NULL OR feeder_capacity_lb > 0);

ALTER TABLE public.feed_drops
    ADD COLUMN IF NOT EXISTS method text NOT NULL DEFAULT 'scale',
    ADD COLUMN IF NOT EXISTS called_lb numeric
        CHECK (called_lb IS NULL OR called_lb >= 0);

DO $m$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'feed_drops_method_check') THEN
        ALTER TABLE public.feed_drops
            ADD CONSTRAINT feed_drops_method_check CHECK (method IN ('scale', 'allocated'));
    END IF;
END
$m$;

ALTER TABLE public.feed_loads
    ADD COLUMN IF NOT EXISTS delivery_mode text NOT NULL DEFAULT 'direct';

DO $m$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'feed_loads_delivery_mode_check') THEN
        ALTER TABLE public.feed_loads
            ADD CONSTRAINT feed_loads_delivery_mode_check CHECK (delivery_mode IN ('direct', 'cart'));
    END IF;
END
$m$;

COMMENT ON COLUMN public.pasture_feed_setup.feeder_capacity_lb IS
    'Total pounds the bulk feeders in this pasture hold. One bucket per pasture (John, 2026-09-06); used to flag a call that overfills them and to estimate the empty date.';
COMMENT ON COLUMN public.feed_drops.method IS
    'scale = weighed as the fall in gross between Start and Done. allocated = no scale on the cart, so this drop is its pro-rata share of the load''s mixed pounds against called_lb.';
COMMENT ON COLUMN public.feed_drops.called_lb IS
    'The pounds called for this pasture, the weight the allocation was made against. Null on a weighed drop.';
COMMENT ON COLUMN public.feed_loads.delivery_mode IS
    'direct = the truck dropped at each pasture, weighed. cart = mixed into the grain cart and delivered to bulk feeders by allocation.';

DO $verify$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema = 'public'
       AND ((table_name = 'pasture_feed_setup' AND column_name = 'feeder_capacity_lb')
         OR (table_name = 'feed_drops'         AND column_name IN ('method', 'called_lb'))
         OR (table_name = 'feed_loads'         AND column_name = 'delivery_mode'));
    IF n <> 4 THEN RAISE EXCEPTION 'bulk feeder columns missing (found % of 4)', n; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'feed_drops_method_check') THEN
        RAISE EXCEPTION 'feed_drops_method_check missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'feed_loads_delivery_mode_check') THEN
        RAISE EXCEPTION 'feed_loads_delivery_mode_check missing';
    END IF;
    RAISE NOTICE 'bulk_feeders: OK';
END
$verify$;
