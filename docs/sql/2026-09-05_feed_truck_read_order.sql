-- =====================================================================
-- Feed truck: a bunk READING order separate from the feed ROUTE order,
-- and crew may drag either one (2026-09-05, John's call)
-- =====================================================================
-- "Bunk reading order and feed truck order can be different." The reader
-- walks the pens in one order first thing; the truck drives them in
-- another. Both live on pasture_feed_setup so the office and the feed app
-- read one source.
--
-- Crew may reorder from the cab / the reading walk. RLS cannot restrict an
-- UPDATE to two columns, so the policy lets crew UPDATE and a trigger
-- refuses a crew update that changes anything but the two order columns.
-- Office and owner are unrestricted, as before.
--
-- Apply in the Supabase SQL editor. Idempotent.
-- =====================================================================

ALTER TABLE public.pasture_feed_setup
    ADD COLUMN IF NOT EXISTS read_order integer NOT NULL DEFAULT 0;

-- Start the reading order from the route order so nothing is unordered.
UPDATE public.pasture_feed_setup SET read_order = route_order WHERE read_order = 0 AND route_order <> 0;

CREATE OR REPLACE FUNCTION public.pasture_feed_setup_crew_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $fn$
BEGIN
    IF public.current_user_role() = 'crew' THEN
        IF NEW.pasture_id  IS DISTINCT FROM OLD.pasture_id
        OR NEW.feeder_type IS DISTINCT FROM OLD.feeder_type
        OR NEW.ration_id   IS DISTINCT FROM OLD.ration_id
        OR NEW.ration_since IS DISTINCT FROM OLD.ration_since
        OR NEW.one_pass    IS DISTINCT FROM OLD.one_pass
        OR NEW.is_active   IS DISTINCT FROM OLD.is_active
        OR NEW.notes       IS DISTINCT FROM OLD.notes THEN
            RAISE EXCEPTION 'pasture_feed_setup: crew may change the reading and route order only; the office sets the rest.';
        END IF;
    END IF;
    RETURN NEW;
END
$fn$;
DROP TRIGGER IF EXISTS pasture_feed_setup_crew_guard ON public.pasture_feed_setup;
-- BEFORE the stamp trigger alphabetically? Triggers fire in name order;
-- "pasture_feed_setup_crew_guard" < "pasture_feed_setup_stamp", so the
-- guard sees the row before the stamp rewrites updated_by. Good.
CREATE TRIGGER pasture_feed_setup_crew_guard BEFORE UPDATE ON public.pasture_feed_setup
    FOR EACH ROW EXECUTE FUNCTION public.pasture_feed_setup_crew_guard();

DROP POLICY IF EXISTS pasture_feed_setup_update ON public.pasture_feed_setup;
CREATE POLICY pasture_feed_setup_update ON public.pasture_feed_setup FOR UPDATE
    USING (public.current_user_role() = ANY (ARRAY['owner','office','crew']))
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office','crew']));

DO $verify$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='pasture_feed_setup' AND column_name='read_order') THEN
        RAISE EXCEPTION 'read_order missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='pasture_feed_setup_crew_guard') THEN
        RAISE EXCEPTION 'crew guard trigger missing';
    END IF;
    RAISE NOTICE 'feed_truck read_order: OK';
END
$verify$;
