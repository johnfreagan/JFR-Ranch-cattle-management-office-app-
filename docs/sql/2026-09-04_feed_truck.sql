-- =====================================================================
-- Feed truck, phase 1: rations, bunk reads, loads, drops, posting
-- =====================================================================
-- Design record: docs/feed-truck-integration-scope.md (21 decisions taken
-- by John, 2026-09-04). Read it before changing anything here.
--
-- WHAT THIS IS. The feed truck's own ledger. The scale head on the truck is
-- the only source of pounds; the feed app (phase 2) writes what it saw into
-- feed_loads / feed_load_lines / feed_drops / feed_drop_lots, and NOTHING
-- here touches feed_usage until the office posts a load.
--
-- WHY A SEPARATE LEDGER (D1). Performance Beef's Monday entry still posts
-- feed_usage for every lot while the truck runs in parallel. If the truck
-- also posted, every pound would be charged twice and cost of gain would
-- read double while every screen balanced. Truck pounds stay in their own
-- tables; a ranch-level date (ranch_settings.feed_truck_post_from) is the
-- cut-over, and post_feed_load() refuses anything before it.
--
-- HOW A LOAD BECOMES BOOKS (D11, D12). A load's lines are what physically
-- left the bays (item, bay, actual pounds - frozen at the Done tap). Its
-- drops are what physically landed in pastures, split to lots by head
-- (D10, stored per drop). post_feed_load() charges each line's pounds to
-- the load's lots pro-rata by the pounds each lot was dropped, largest-
-- remainder so every line sums back exactly, and runs each slice through
-- post_feed_usage() so FIFO and frozen cost behave exactly as they do for a
-- hand entry. Feed left in the box after the last drop is therefore charged
-- to THIS load's lots (a few hundred pounds across the day's pastures) and
-- the NEXT load draws less from the bays, because Distribute (D9) cut its
-- targets by the leftover. Over a week it is a wash; every pound that left
-- a bay lands on a lot; nothing is stored per drop per commodity.
--
-- NO DELETE, NO CANCEL (D12). A wrong drop is moved or set to zero with a
-- reason; a load that ended early is closed with what it did. Crew hold no
-- DELETE policy on any truck table. Owner keeps the escape hatch.
--
-- EDITABLE UNTIL POSTED (D12). feed_load_guard() refuses any change to the
-- lines, drops or lot splits of a posted or void load; unpost_feed_load()
-- reverses the usage and reopens the load with its rows intact.
--
-- Apply in the Supabase SQL editor (strip begin/commit for the CLI).
-- Run supabase/migrations/20260821000300_rls_verify.sql after.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Pre-flight: everything this builds on must exist
-- ---------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regclass('public.feed_items') IS NULL
       OR to_regclass('public.feed_storage_locations') IS NULL
       OR to_regclass('public.feed_usage') IS NULL
       OR to_regclass('public.ranch_settings') IS NULL THEN
        RAISE EXCEPTION 'feed_truck: the feed inventory migrations (2026-08-27 .. 2026-08-31) must be applied first.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname = 'public' AND p.proname = 'post_feed_usage') THEN
        RAISE EXCEPTION 'feed_truck: post_feed_usage() is missing.';
    END IF;
END
$pre$;


-- ---------------------------------------------------------------------
-- 1. Ranch-wide settings (D2, D6, D17, D1)
-- ---------------------------------------------------------------------
-- Four numbers on the one-row settings table. feed_truck_post_from is the
-- cut-over: NULL means "parallel run, nothing posts".
ALTER TABLE public.ranch_settings
    ADD COLUMN IF NOT EXISTS feed_truck_tolerance_pct numeric NOT NULL DEFAULT 10
        CHECK (feed_truck_tolerance_pct >= 0 AND feed_truck_tolerance_pct <= 100),
    ADD COLUMN IF NOT EXISTS feed_truck_min_split_lb numeric NOT NULL DEFAULT 500
        CHECK (feed_truck_min_split_lb >= 0),
    ADD COLUMN IF NOT EXISTS feed_truck_tieout_pct numeric NOT NULL DEFAULT 5
        CHECK (feed_truck_tieout_pct >= 0 AND feed_truck_tieout_pct <= 100),
    ADD COLUMN IF NOT EXISTS feed_truck_post_from date;

-- D16: office maintains the truck settings. ranch_settings was owner-only;
-- widening UPDATE to office is John's call (the row also carries
-- feed_direct_from, which office can now change - noted in CLAUDE.md).
DROP POLICY IF EXISTS ranch_settings_update ON public.ranch_settings;
CREATE POLICY ranch_settings_update ON public.ranch_settings FOR UPDATE
    USING (public.current_user_role() = ANY (ARRAY['owner','office']))
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));


-- ---------------------------------------------------------------------
-- 2. feed_usage learns where a truck posting came from
-- ---------------------------------------------------------------------
ALTER TABLE public.feed_usage DROP CONSTRAINT IF EXISTS feed_usage_source_check;
ALTER TABLE public.feed_usage ADD CONSTRAINT feed_usage_source_check
    CHECK (source = ANY (ARRAY['manual','pb_import','count','correction','truck']));


-- ---------------------------------------------------------------------
-- 3. Rations (D2)
-- ---------------------------------------------------------------------
-- NOT feed_recipes: a recipe must produce a premix item; a ration produces
-- nothing, it feeds cattle. A line's item may itself be a premix.
CREATE TABLE IF NOT EXISTS public.rations (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name          text NOT NULL,
    mix_minutes   integer NOT NULL DEFAULT 0 CHECK (mix_minutes >= 0),
    max_load_lb   numeric CHECK (max_load_lb IS NULL OR max_load_lb > 0),
    is_active     boolean NOT NULL DEFAULT true,
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS rations_name_uniq ON public.rations (lower(name));

CREATE TABLE IF NOT EXISTS public.ration_lines (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ration_id            uuid NOT NULL REFERENCES public.rations(id) ON DELETE CASCADE,
    item_id              uuid NOT NULL REFERENCES public.feed_items(id) ON DELETE RESTRICT,
    pct_as_fed           numeric NOT NULL CHECK (pct_as_fed > 0 AND pct_as_fed <= 100),
    load_order           integer NOT NULL DEFAULT 0,
    default_location_id  uuid REFERENCES public.feed_storage_locations(id) ON DELETE SET NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ration_lines_one_per_item UNIQUE (ration_id, item_id)
);
CREATE INDEX IF NOT EXISTS ration_lines_ration_idx ON public.ration_lines (ration_id, load_order);


-- ---------------------------------------------------------------------
-- 4. Pasture feed setup (D3, D6)
-- ---------------------------------------------------------------------
-- feeder_type: 'bunk' takes lb/hd x head; 'bulk' takes total pounds.
-- one_pass: hard to drive through the cattle twice - the planner never
-- splits it across loads. ration_since is stamped on every ration change
-- so history shows when a step-up happened.
CREATE TABLE IF NOT EXISTS public.pasture_feed_setup (
    pasture_id    uuid PRIMARY KEY REFERENCES public.pastures(id) ON DELETE CASCADE,
    feeder_type   text NOT NULL DEFAULT 'bunk' CHECK (feeder_type IN ('bunk','bulk')),
    ration_id     uuid REFERENCES public.rations(id) ON DELETE SET NULL,
    ration_since  date,
    route_order   integer NOT NULL DEFAULT 0,
    one_pass      boolean NOT NULL DEFAULT false,
    is_active     boolean NOT NULL DEFAULT true,
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE OR REPLACE FUNCTION public.pasture_feed_setup_stamp()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $fn$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.ration_id IS NOT NULL AND NEW.ration_since IS NULL THEN
            NEW.ration_since := public.ranch_today();
        END IF;
    ELSIF NEW.ration_id IS DISTINCT FROM OLD.ration_id THEN
        NEW.ration_since := public.ranch_today();
    END IF;
    NEW.updated_at := now();
    NEW.updated_by := auth.uid();
    RETURN NEW;
END
$fn$;
DROP TRIGGER IF EXISTS pasture_feed_setup_stamp ON public.pasture_feed_setup;
CREATE TRIGGER pasture_feed_setup_stamp BEFORE INSERT OR UPDATE ON public.pasture_feed_setup
    FOR EACH ROW EXECUTE FUNCTION public.pasture_feed_setup_stamp();


-- ---------------------------------------------------------------------
-- 5. Trucks (D13, D14)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.feed_trucks (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name             text NOT NULL,
    scale_device_id  text,
    capacity_lb      numeric CHECK (capacity_lb IS NULL OR capacity_lb > 0),
    is_default       boolean NOT NULL DEFAULT false,
    is_active        boolean NOT NULL DEFAULT true,
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS feed_trucks_name_uniq ON public.feed_trucks (lower(name));
CREATE UNIQUE INDEX IF NOT EXISTS feed_trucks_device_uniq ON public.feed_trucks (scale_device_id)
    WHERE scale_device_id IS NOT NULL;


-- ---------------------------------------------------------------------
-- 6. Bunk reads (D4, D5, D6)
-- ---------------------------------------------------------------------
-- One row per pasture per day. Everything the loading step needs is
-- snapshotted here (feeder type, head, ration, route order) so a change to
-- setup later does not rewrite what the truck was told that morning.
-- frozen_load_id: set by the feed app when loading starts on the load that
-- carries this call (D6). After that the call cannot change.
CREATE TABLE IF NOT EXISTS public.bunk_reads (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    read_date       date NOT NULL,
    pasture_id      uuid NOT NULL REFERENCES public.pastures(id) ON DELETE RESTRICT,
    feeder_type     text NOT NULL DEFAULT 'bunk' CHECK (feeder_type IN ('bunk','bulk')),
    bunk_score      smallint CHECK (bunk_score IS NULL OR (bunk_score >= 0 AND bunk_score <= 3)),
    lb_per_head     numeric CHECK (lb_per_head IS NULL OR lb_per_head >= 0),
    head_count      integer NOT NULL DEFAULT 0 CHECK (head_count >= 0),
    target_lb       numeric NOT NULL DEFAULT 0 CHECK (target_lb >= 0),
    ration_id       uuid REFERENCES public.rations(id) ON DELETE SET NULL,
    route_order     integer NOT NULL DEFAULT 0,
    frozen_load_id  uuid,
    notes           text,
    client_id       text,
    read_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT bunk_reads_one_per_day UNIQUE (read_date, pasture_id)
);
CREATE INDEX IF NOT EXISTS bunk_reads_date_idx ON public.bunk_reads (read_date DESC);
CREATE UNIQUE INDEX IF NOT EXISTS bunk_reads_client_uniq ON public.bunk_reads (client_id)
    WHERE client_id IS NOT NULL;

DROP TRIGGER IF EXISTS bunk_reads_touch ON public.bunk_reads;
CREATE TRIGGER bunk_reads_touch BEFORE UPDATE ON public.bunk_reads
    FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


-- ---------------------------------------------------------------------
-- 7. Loads, lines, drops, lot splits (D7-D13)
-- ---------------------------------------------------------------------
-- status: planned -> loading -> mixing -> dropping -> closed -> posted
--         any of the first five -> void (office/owner, never posted)
-- carried_in_lb / carried_in_ration_id: leftover from the previous load,
-- at that ration's own percentages, for Distribute (D9) and box accounting.
-- It is NOT part of this load's composition for posting (see header).
CREATE TABLE IF NOT EXISTS public.feed_loads (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    load_date             date NOT NULL,
    load_seq              integer NOT NULL DEFAULT 1 CHECK (load_seq > 0),
    ration_id             uuid NOT NULL REFERENCES public.rations(id) ON DELETE RESTRICT,
    truck_id              uuid REFERENCES public.feed_trucks(id) ON DELETE SET NULL,
    scale_device_id       text,
    status                text NOT NULL DEFAULT 'planned'
                          CHECK (status IN ('planned','loading','mixing','dropping','closed','posted','void')),
    planned_lb            numeric CHECK (planned_lb IS NULL OR planned_lb >= 0),
    carried_in_lb         numeric NOT NULL DEFAULT 0 CHECK (carried_in_lb >= 0),
    carried_in_ration_id  uuid REFERENCES public.rations(id) ON DELETE SET NULL,
    left_in_box_lb        numeric NOT NULL DEFAULT 0 CHECK (left_in_box_lb >= 0),
    mix_minutes_required  integer NOT NULL DEFAULT 0 CHECK (mix_minutes_required >= 0),
    loading_started_at    timestamptz,
    mix_started_at        timestamptz,
    first_drop_at         timestamptz,
    closed_at             timestamptz,
    posted_at             timestamptz,
    posted_by             uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    voided_at             timestamptz,
    voided_by             uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    void_reason           text,
    notes                 text,
    client_id             text,
    created_by            uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS feed_loads_date_idx   ON public.feed_loads (load_date DESC, load_seq);
CREATE INDEX IF NOT EXISTS feed_loads_status_idx ON public.feed_loads (status);
CREATE UNIQUE INDEX IF NOT EXISTS feed_loads_client_uniq ON public.feed_loads (client_id)
    WHERE client_id IS NOT NULL;

-- One ingredient of one load. scale_lb is what the head said at Done; lb is
-- what the books use, equal to scale_lb unless someone overrode it, in
-- which case edited_* say who and why. The scale reading is never
-- overwritten (D12).
CREATE TABLE IF NOT EXISTS public.feed_load_lines (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    load_id       uuid NOT NULL REFERENCES public.feed_loads(id) ON DELETE CASCADE,
    item_id       uuid NOT NULL REFERENCES public.feed_items(id) ON DELETE RESTRICT,
    location_id   uuid NOT NULL REFERENCES public.feed_storage_locations(id) ON DELETE RESTRICT,
    load_order    integer NOT NULL DEFAULT 0,
    target_lb     numeric NOT NULL DEFAULT 0 CHECK (target_lb >= 0),
    scale_lb      numeric CHECK (scale_lb IS NULL OR scale_lb >= 0),
    lb            numeric NOT NULL DEFAULT 0 CHECK (lb >= 0),
    done_at       timestamptz,
    link_ok       boolean,
    edited_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    edited_at     timestamptz,
    edit_reason   text,
    client_id     text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT feed_load_lines_one_per_item UNIQUE (load_id, item_id)
);
CREATE INDEX IF NOT EXISTS feed_load_lines_load_idx ON public.feed_load_lines (load_id, load_order);

-- One pasture of one load. scale_lb = start_gross_lb - end_gross_lb.
CREATE TABLE IF NOT EXISTS public.feed_drops (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    load_id         uuid NOT NULL REFERENCES public.feed_loads(id) ON DELETE CASCADE,
    pasture_id      uuid NOT NULL REFERENCES public.pastures(id) ON DELETE RESTRICT,
    drop_seq        integer NOT NULL DEFAULT 1,
    target_lb       numeric NOT NULL DEFAULT 0 CHECK (target_lb >= 0),
    start_gross_lb  numeric,
    end_gross_lb    numeric,
    scale_lb        numeric CHECK (scale_lb IS NULL OR scale_lb >= 0),
    lb              numeric NOT NULL DEFAULT 0 CHECK (lb >= 0),
    started_at      timestamptz,
    done_at         timestamptz,
    link_ok         boolean,
    edited_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    edited_at       timestamptz,
    edit_reason     text,
    client_id       text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS feed_drops_load_idx    ON public.feed_drops (load_id, drop_seq);
CREATE INDEX IF NOT EXISTS feed_drops_pasture_idx ON public.feed_drops (pasture_id);
CREATE UNIQUE INDEX IF NOT EXISTS feed_drops_client_uniq ON public.feed_drops (client_id)
    WHERE client_id IS NOT NULL;

-- The head split of one drop (D10). Written by the feed app from the head
-- it cached at the barn; split_drop_to_lots() fills it at posting time if
-- the app could not.
CREATE TABLE IF NOT EXISTS public.feed_drop_lots (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    drop_id     uuid NOT NULL REFERENCES public.feed_drops(id) ON DELETE CASCADE,
    lot_id      uuid NOT NULL REFERENCES public.lots(id) ON DELETE RESTRICT,
    head_count  integer NOT NULL DEFAULT 0 CHECK (head_count >= 0),
    lb          numeric NOT NULL DEFAULT 0 CHECK (lb >= 0),
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT feed_drop_lots_one_per_lot UNIQUE (drop_id, lot_id)
);
CREATE INDEX IF NOT EXISTS feed_drop_lots_lot_idx ON public.feed_drop_lots (lot_id);

-- Which feed_usage rows a posted load created, so unpost can reverse
-- exactly those and nothing else.
CREATE TABLE IF NOT EXISTS public.feed_load_usage (
    load_id   uuid NOT NULL REFERENCES public.feed_loads(id) ON DELETE CASCADE,
    usage_id  uuid NOT NULL REFERENCES public.feed_usage(id) ON DELETE CASCADE,
    PRIMARY KEY (load_id, usage_id)
);

DROP TRIGGER IF EXISTS rations_touch ON public.rations;
CREATE TRIGGER rations_touch BEFORE UPDATE ON public.rations
    FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
DROP TRIGGER IF EXISTS feed_trucks_touch ON public.feed_trucks;
CREATE TRIGGER feed_trucks_touch BEFORE UPDATE ON public.feed_trucks
    FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
DROP TRIGGER IF EXISTS feed_loads_touch ON public.feed_loads;
CREATE TRIGGER feed_loads_touch BEFORE UPDATE ON public.feed_loads
    FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
DROP TRIGGER IF EXISTS feed_load_lines_touch ON public.feed_load_lines;
CREATE TRIGGER feed_load_lines_touch BEFORE UPDATE ON public.feed_load_lines
    FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
DROP TRIGGER IF EXISTS feed_drops_touch ON public.feed_drops;
CREATE TRIGGER feed_drops_touch BEFORE UPDATE ON public.feed_drops
    FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


-- ---------------------------------------------------------------------
-- 8. Guards
-- ---------------------------------------------------------------------
-- 8a. Nothing under a posted or void load changes (D12). The RPCs below
-- change the load's own status first and never touch its rows, so they
-- need no bypass.
CREATE OR REPLACE FUNCTION public.feed_load_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $fn$
DECLARE
    v_load_id uuid;
    v_status  text;
BEGIN
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

DROP TRIGGER IF EXISTS feed_load_lines_guard ON public.feed_load_lines;
CREATE TRIGGER feed_load_lines_guard BEFORE INSERT OR UPDATE OR DELETE ON public.feed_load_lines
    FOR EACH ROW EXECUTE FUNCTION public.feed_load_guard();
DROP TRIGGER IF EXISTS feed_drops_guard ON public.feed_drops;
CREATE TRIGGER feed_drops_guard BEFORE INSERT OR UPDATE OR DELETE ON public.feed_drops
    FOR EACH ROW EXECUTE FUNCTION public.feed_load_guard();
DROP TRIGGER IF EXISTS feed_drop_lots_guard ON public.feed_drop_lots;
CREATE TRIGGER feed_drop_lots_guard BEFORE INSERT OR UPDATE OR DELETE ON public.feed_drop_lots
    FOR EACH ROW EXECUTE FUNCTION public.feed_load_guard();

-- 8b. A load's status only moves through the RPCs into posted/void, and a
-- posted load's own row is frozen except through unpost. Office and owner
-- pass RLS on UPDATE deliberately (same reasoning as lot_budgets) so this
-- raises a real error rather than PostgREST returning zero rows.
CREATE OR REPLACE FUNCTION public.feed_loads_status_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $fn$
BEGIN
    IF current_setting('feed_truck.rpc', true) = 'on' THEN
        RETURN NEW;
    END IF;
    IF OLD.status IN ('posted','void') THEN
        RAISE EXCEPTION 'feed_loads_status_guard: load % is %; use unpost_feed_load() first.', OLD.id, OLD.status;
    END IF;
    IF NEW.status IN ('posted','void') THEN
        RAISE EXCEPTION 'feed_loads_status_guard: a load is posted or voided through post_feed_load() / void_feed_load(), not by setting status.';
    END IF;
    RETURN NEW;
END
$fn$;
DROP TRIGGER IF EXISTS feed_loads_status_guard ON public.feed_loads;
CREATE TRIGGER feed_loads_status_guard BEFORE UPDATE ON public.feed_loads
    FOR EACH ROW EXECUTE FUNCTION public.feed_loads_status_guard();

-- 8c. A frozen bunk read cannot change its call (D6). Route order and notes
-- may still move; the pounds the truck was loaded against may not.
CREATE OR REPLACE FUNCTION public.bunk_reads_frozen_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $fn$
BEGIN
    IF OLD.frozen_load_id IS NOT NULL
       AND (NEW.target_lb IS DISTINCT FROM OLD.target_lb
            OR NEW.lb_per_head IS DISTINCT FROM OLD.lb_per_head
            OR NEW.head_count IS DISTINCT FROM OLD.head_count
            OR NEW.ration_id IS DISTINCT FROM OLD.ration_id
            OR NEW.pasture_id IS DISTINCT FROM OLD.pasture_id
            OR NEW.read_date IS DISTINCT FROM OLD.read_date)
       AND EXISTS (SELECT 1 FROM public.feed_loads l
                    WHERE l.id = OLD.frozen_load_id AND l.status <> 'void') THEN
        RAISE EXCEPTION 'bunk_reads_frozen_guard: this call is already loaded on the truck (load %). Change the drop instead.',
            OLD.frozen_load_id;
    END IF;
    RETURN NEW;
END
$fn$;
DROP TRIGGER IF EXISTS bunk_reads_frozen_guard ON public.bunk_reads;
CREATE TRIGGER bunk_reads_frozen_guard BEFORE UPDATE ON public.bunk_reads
    FOR EACH ROW EXECUTE FUNCTION public.bunk_reads_frozen_guard();


-- ---------------------------------------------------------------------
-- 9. Largest-remainder split, reusable
-- ---------------------------------------------------------------------
-- Splits p_total over p_weights to p_scale decimals so the parts sum
-- EXACTLY to p_total. Same rule as the shipment allocation: never "round
-- each and dump the residual on the last one".
CREATE OR REPLACE FUNCTION public.lr_split(p_total numeric, p_weights numeric[], p_scale integer DEFAULT 2)
RETURNS numeric[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_catalog
AS $fn$
DECLARE
    n        integer := COALESCE(array_length(p_weights, 1), 0);
    wsum     numeric := 0;
    unit     numeric := power(10::numeric, -p_scale);
    parts    numeric[] := '{}';
    fracs    numeric[] := '{}';
    exact    numeric;
    floored  numeric;
    given    numeric := 0;
    remain   integer;
    i        integer;
    best     integer;
    bestv    numeric;
BEGIN
    IF n = 0 THEN RETURN '{}'; END IF;
    FOR i IN 1..n LOOP wsum := wsum + COALESCE(p_weights[i], 0); END LOOP;
    IF wsum <= 0 THEN
        -- Nothing to weight by: everything to the first part.
        parts := array_fill(0::numeric, ARRAY[n]);
        parts[1] := p_total;
        RETURN parts;
    END IF;
    FOR i IN 1..n LOOP
        exact   := p_total * COALESCE(p_weights[i], 0) / wsum;
        floored := floor(exact / unit) * unit;
        parts   := parts || floored;
        fracs   := fracs || (exact - floored);
        given   := given + floored;
    END LOOP;
    remain := round((p_total - given) / unit)::integer;
    WHILE remain > 0 LOOP
        best := 1; bestv := -1;
        FOR i IN 1..n LOOP
            IF fracs[i] > bestv THEN bestv := fracs[i]; best := i; END IF;
        END LOOP;
        parts[best] := parts[best] + unit;
        fracs[best] := -1;
        remain := remain - 1;
    END LOOP;
    RETURN parts;
END
$fn$;


-- ---------------------------------------------------------------------
-- 10. split_drop_to_lots - the head split, computed from the books (D10)
-- ---------------------------------------------------------------------
-- Fallback for a drop the feed app saved without its split. Uses the open
-- assignments on the load date; cattle that moved out ON that date were
-- there in the morning and are counted. Does nothing if rows exist.
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
        RAISE EXCEPTION 'split_drop_to_lots: no lot was standing in that pasture on % (drop %). Move the drop to the right pasture.',
            v_date, p_drop_id;
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
-- 11. post_feed_load - a closed load becomes feed_usage rows (D11, D12)
-- ---------------------------------------------------------------------
-- Refuses: not closed; today's load (one-day grace); before the cut-over;
-- no pounds loaded; no pounds dropped. Each line's pounds are split over
-- the lots by the pounds each was dropped (largest-remainder) and posted
-- through post_feed_usage(), one usage row per (line, lot), dated the load
-- date so head-days stay honest.
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
    v_lots       uuid[];
    v_lot_lb     numeric[];
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

    SELECT array_agg(lot_id ORDER BY lot_id), array_agg(lb ORDER BY lot_id), SUM(lb)
      INTO v_lots, v_lot_lb, v_dropped
      FROM (SELECT dl.lot_id, SUM(dl.lb) AS lb
              FROM public.feed_drop_lots dl
              JOIN public.feed_drops d ON d.id = dl.drop_id
             WHERE d.load_id = p_load_id AND d.lb > 0
             GROUP BY dl.lot_id
            HAVING SUM(dl.lb) > 0) s;
    IF v_lots IS NULL OR v_dropped <= 0 THEN
        RAISE EXCEPTION 'post_feed_load: load % dropped nothing; there is no lot to charge. If the whole load stayed in the box, void it and let the next load carry the pounds.',
            p_load_id;
    END IF;

    SELECT name INTO v_ration FROM public.rations WHERE id = v_load.ration_id;

    FOR v_line IN
        SELECT * FROM public.feed_load_lines WHERE load_id = p_load_id AND lb > 0 ORDER BY load_order
    LOOP
        v_parts := public.lr_split(v_line.lb, v_lot_lb, 2);
        FOR i IN 1..array_length(v_lots, 1) LOOP
            CONTINUE WHEN v_parts[i] <= 0;
            v_usage_id := public.post_feed_usage(
                p_item_id          => v_line.item_id,
                p_from_location_id => v_line.location_id,
                p_qty_lb           => v_parts[i],
                p_destination_type => 'lot',
                p_period_start     => v_load.load_date,
                p_period_end       => v_load.load_date,
                p_lot_id           => v_lots[i],
                p_usage_date       => v_load.load_date,
                p_source           => 'truck',
                p_notes            => 'Feed truck ' || v_load.load_date::text || ' load ' || v_load.load_seq::text
                                      || ' (' || COALESCE(v_ration, '?') || ')'
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
-- 12. unpost_feed_load - reverse, reopen, rows intact (D12)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.unpost_feed_load(p_load_id uuid, p_reason text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_status  text;
    v_n       integer := 0;
    u_rec     record;
BEGIN
    SELECT status INTO v_status FROM public.feed_loads WHERE id = p_load_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unpost_feed_load: load % not found.', p_load_id;
    END IF;
    IF v_status <> 'posted' THEN
        RAISE EXCEPTION 'unpost_feed_load: load % is %, not posted.', p_load_id, v_status;
    END IF;
    FOR u_rec IN SELECT usage_id FROM public.feed_load_usage WHERE load_id = p_load_id LOOP
        PERFORM public.delete_feed_usage(u_rec.usage_id);
        v_n := v_n + 1;
    END LOOP;
    DELETE FROM public.feed_load_usage WHERE load_id = p_load_id;

    PERFORM set_config('feed_truck.rpc', 'on', true);
    UPDATE public.feed_loads
       SET status = 'closed', posted_at = NULL, posted_by = NULL,
           notes = CONCAT_WS(E'\n', notes,
                     '[unposted ' || public.ranch_today()::text || COALESCE(': ' || p_reason, '') || ']')
     WHERE id = p_load_id;
    PERFORM set_config('feed_truck.rpc', 'off', true);
    RETURN v_n;
END
$fn$;


-- ---------------------------------------------------------------------
-- 13. void_feed_load - a load that never happened (D12)
-- ---------------------------------------------------------------------
-- A posted load must be unposted first; void never touches feed_usage.
CREATE OR REPLACE FUNCTION public.void_feed_load(p_load_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_status text;
BEGIN
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'void_feed_load: a reason is required.';
    END IF;
    SELECT status INTO v_status FROM public.feed_loads WHERE id = p_load_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'void_feed_load: load % not found.', p_load_id;
    END IF;
    IF v_status = 'posted' THEN
        RAISE EXCEPTION 'void_feed_load: load % is posted; unpost it first.', p_load_id;
    END IF;
    IF v_status = 'void' THEN
        RETURN;
    END IF;
    PERFORM set_config('feed_truck.rpc', 'on', true);
    UPDATE public.feed_loads
       SET status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
     WHERE id = p_load_id;
    PERFORM set_config('feed_truck.rpc', 'off', true);
    -- The calls it froze may be loaded again.
    UPDATE public.bunk_reads SET frozen_load_id = NULL WHERE frozen_load_id = p_load_id;
END
$fn$;


-- ---------------------------------------------------------------------
-- 14. post_due_feed_loads - what the office app calls on open (D12)
-- ---------------------------------------------------------------------
-- Every closed load from a prior ranch day on/after the cut-over. One
-- failure does not stop the rest; each is its own subtransaction and the
-- errors come back by load so the screen can show them.
CREATE OR REPLACE FUNCTION public.post_due_feed_loads()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_from    date;
    v_posted  integer := 0;
    v_errors  jsonb := '[]'::jsonb;
    l_rec     record;
BEGIN
    SELECT feed_truck_post_from INTO v_from FROM public.ranch_settings LIMIT 1;
    IF v_from IS NULL THEN
        RETURN jsonb_build_object('posted', 0, 'errors', '[]'::jsonb, 'parallel', true);
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
    RETURN jsonb_build_object('posted', v_posted, 'errors', v_errors, 'parallel', false);
END
$fn$;


-- ---------------------------------------------------------------------
-- 15. Views: what the truck fed, by lot and commodity; the PB tie-out (D17)
-- ---------------------------------------------------------------------
-- feed_truck_lot_item_lb: one row per (load, lot, item), the same pro-rata
-- rule post_feed_load uses, live. Void loads excluded. Not rounded - it is
-- a report, the posting is the rounded one.
DROP VIEW IF EXISTS public.feed_truck_tieout;
DROP VIEW IF EXISTS public.feed_truck_tieout_headdays;
DROP VIEW IF EXISTS public.feed_truck_lot_item_lb;
CREATE VIEW public.feed_truck_lot_item_lb WITH (security_invoker = true) AS
WITH dropped AS (
    SELECT d.load_id, dl.lot_id, SUM(dl.lb) AS lot_lb
      FROM public.feed_drops d
      JOIN public.feed_drop_lots dl ON dl.drop_id = d.id
     WHERE d.lb > 0
     GROUP BY d.load_id, dl.lot_id
), load_total AS (
    SELECT load_id, SUM(lot_lb) AS dropped_lb FROM dropped GROUP BY load_id
)
SELECT l.id AS load_id, l.load_date, l.load_seq, l.ration_id, l.status,
       dr.lot_id, ln.item_id, ln.location_id,
       ln.lb * dr.lot_lb / NULLIF(lt.dropped_lb, 0) AS qty_lb
  FROM public.feed_loads l
  JOIN public.feed_load_lines ln ON ln.load_id = l.id AND ln.lb > 0
  JOIN dropped dr ON dr.load_id = l.id
  JOIN load_total lt ON lt.load_id = l.id
 WHERE l.status <> 'void';

-- feed_truck_tieout: PB week (Monday..Sunday) x lot x item. PB side = the
-- Monday entry (feed_usage to a lot, source manual/pb_import, its period
-- spread evenly over its days and bucketed by week). Truck side = the view
-- above. A load's week is its load date's.
CREATE VIEW public.feed_truck_tieout WITH (security_invoker = true) AS
WITH truck AS (
    SELECT date_trunc('week', v.load_date)::date AS week_start, v.lot_id, v.item_id,
           SUM(v.qty_lb) AS truck_lb
      FROM public.feed_truck_lot_item_lb v
     GROUP BY 1, 2, 3
), pb_days AS (
    SELECT u.lot_id, u.item_id,
           gs::date AS day,
           u.qty_lb / (u.period_end - u.period_start + 1) AS day_lb
      FROM public.feed_usage u
      CROSS JOIN LATERAL generate_series(u.period_start::timestamp, u.period_end::timestamp, interval '1 day') gs
     WHERE u.destination_type = 'lot' AND u.lot_id IS NOT NULL
       AND u.source IN ('manual','pb_import')
), pb AS (
    SELECT date_trunc('week', day)::date AS week_start, lot_id, item_id, SUM(day_lb) AS pb_lb
      FROM pb_days GROUP BY 1, 2, 3
)
SELECT COALESCE(t.week_start, p.week_start) AS week_start,
       COALESCE(t.lot_id, p.lot_id)         AS lot_id,
       lo.lot_number,
       COALESCE(t.item_id, p.item_id)       AS item_id,
       fi.name                              AS item_name,
       COALESCE(t.truck_lb, 0)              AS truck_lb,
       COALESCE(p.pb_lb, 0)                 AS pb_lb,
       COALESCE(t.truck_lb, 0) - COALESCE(p.pb_lb, 0) AS diff_lb,
       CASE WHEN COALESCE(p.pb_lb, 0) > 0
            THEN 100 * (COALESCE(t.truck_lb, 0) - p.pb_lb) / p.pb_lb END AS diff_pct
  FROM truck t
  FULL OUTER JOIN pb p ON p.week_start = t.week_start AND p.lot_id = t.lot_id AND p.item_id = t.item_id
  LEFT JOIN public.lots lo ON lo.id = COALESCE(t.lot_id, p.lot_id)
  LEFT JOIN public.feed_items fi ON fi.id = COALESCE(t.item_id, p.item_id);

-- feed_truck_tieout_headdays: per week x lot, the head the truck's splits
-- carried on the days it fed, against the books' head on THOSE SAME DAYS.
-- A lot counts once per pasture per day (two drops on one bunk do not
-- double it) and sums across pastures (a lot split over two bunks adds up).
-- Comparing only fed days is deliberate: the books count every day, the
-- truck only the days it went out, and the question here is whether the
-- split's head matches the books, not whether the truck fed every day.
CREATE VIEW public.feed_truck_tieout_headdays WITH (security_invoker = true) AS
WITH per_pasture AS (
    SELECT l.load_date AS day, dl.lot_id, d.pasture_id, MAX(dl.head_count) AS head
      FROM public.feed_loads l
      JOIN public.feed_drops d ON d.load_id = l.id AND d.lb > 0
      JOIN public.feed_drop_lots dl ON dl.drop_id = d.id
     WHERE l.status <> 'void'
     GROUP BY l.load_date, dl.lot_id, d.pasture_id
), truck_days AS (
    SELECT day, lot_id, SUM(head) AS head FROM per_pasture GROUP BY day, lot_id
)
SELECT date_trunc('week', t.day)::date AS week_start, t.lot_id, lo.lot_number,
       COUNT(*)                          AS days_fed,
       SUM(t.head)                       AS truck_head_days,
       COALESCE(SUM(h.head_on_hand), 0)  AS book_head_days
  FROM truck_days t
  LEFT JOIN public.lot_daily_head h ON h.lot_id = t.lot_id AND h.as_of_date = t.day
  LEFT JOIN public.lots lo ON lo.id = t.lot_id
 GROUP BY 1, 2, 3;


-- ---------------------------------------------------------------------
-- 16. RLS (D16)
-- ---------------------------------------------------------------------
-- Truck tables carry no dollars, so crew reading and writing them changes
-- nothing about "crew can't see dollars". Setup tables: crew read (the
-- feed app needs them), office/owner write, owner delete. Truck tables:
-- any active writer inserts/updates; crew only while the load is open;
-- NOBODY but owner deletes (D12).
ALTER TABLE public.rations             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ration_lines        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pasture_feed_setup  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_trucks         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bunk_reads          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_loads          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_load_lines     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_drops          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_drop_lots      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_load_usage     ENABLE ROW LEVEL SECURITY;

DO $pol$
DECLARE
    t text;
BEGIN
    -- Setup tables: read operational, write office/owner, delete owner.
    FOREACH t IN ARRAY ARRAY['rations','ration_lines','pasture_feed_setup','feed_trucks'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_select', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_insert', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_update', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_delete', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT USING (public.can_read_operational())', t || '_select', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT WITH CHECK (public.current_user_role() = ANY (ARRAY[''owner'',''office'']))', t || '_insert', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE USING (public.current_user_role() = ANY (ARRAY[''owner'',''office''])) WITH CHECK (public.current_user_role() = ANY (ARRAY[''owner'',''office'']))', t || '_update', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE USING (public.current_user_role() = ''owner'')', t || '_delete', t);
    END LOOP;

    -- ration_lines are rewritten whole when a ration is saved (the office
    -- screen deletes and re-inserts them), so office needs DELETE here. It
    -- is a setup table, not an audit trail.
    DROP POLICY IF EXISTS ration_lines_delete ON public.ration_lines;
    CREATE POLICY ration_lines_delete ON public.ration_lines FOR DELETE
        USING (public.current_user_role() = ANY (ARRAY['owner','office']));

    -- Truck tables written from the cab: crew included. Delete: owner only.
    FOREACH t IN ARRAY ARRAY['bunk_reads','feed_load_lines','feed_drops','feed_drop_lots'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_select', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_insert', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_update', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_delete', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT USING (public.can_read_operational())', t || '_select', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT WITH CHECK (public.current_user_role() = ANY (ARRAY[''owner'',''office'',''crew'']))', t || '_insert', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE USING (public.current_user_role() = ANY (ARRAY[''owner'',''office'',''crew''])) WITH CHECK (public.current_user_role() = ANY (ARRAY[''owner'',''office'',''crew'']))', t || '_update', t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE USING (public.current_user_role() = ''owner'')', t || '_delete', t);
    END LOOP;
END
$pol$;

-- feed_loads: crew may only touch an open load. Office/owner pass
-- unconditionally so the status guard raises a real error (see 8b).
DROP POLICY IF EXISTS feed_loads_select ON public.feed_loads;
DROP POLICY IF EXISTS feed_loads_insert ON public.feed_loads;
DROP POLICY IF EXISTS feed_loads_update ON public.feed_loads;
DROP POLICY IF EXISTS feed_loads_delete ON public.feed_loads;
CREATE POLICY feed_loads_select ON public.feed_loads FOR SELECT
    USING (public.can_read_operational());
CREATE POLICY feed_loads_insert ON public.feed_loads FOR INSERT
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office','crew'])
                AND status NOT IN ('posted','void'));
CREATE POLICY feed_loads_update ON public.feed_loads FOR UPDATE
    USING (public.current_user_role() = ANY (ARRAY['owner','office'])
           OR (public.current_user_role() = 'crew' AND status NOT IN ('posted','void')))
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office'])
           OR (public.current_user_role() = 'crew' AND status NOT IN ('posted','void')));
CREATE POLICY feed_loads_delete ON public.feed_loads FOR DELETE
    USING (public.current_user_role() = 'owner');

-- feed_load_usage: books-readers see it; only the posting RPCs (INVOKER,
-- run by office/owner) write it.
DROP POLICY IF EXISTS feed_load_usage_select ON public.feed_load_usage;
DROP POLICY IF EXISTS feed_load_usage_insert ON public.feed_load_usage;
DROP POLICY IF EXISTS feed_load_usage_delete ON public.feed_load_usage;
CREATE POLICY feed_load_usage_select ON public.feed_load_usage FOR SELECT
    USING (public.can_read_books());
CREATE POLICY feed_load_usage_insert ON public.feed_load_usage FOR INSERT
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));
CREATE POLICY feed_load_usage_delete ON public.feed_load_usage FOR DELETE
    USING (public.current_user_role() = ANY (ARRAY['owner','office']));

-- Functions: authenticated only, never PUBLIC/anon (rule 4).
REVOKE ALL ON FUNCTION public.lr_split(numeric, numeric[], integer)     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.split_drop_to_lots(uuid)                   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.post_feed_load(uuid)                       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.unpost_feed_load(uuid, text)               FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.void_feed_load(uuid, text)                 FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.post_due_feed_loads()                      FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lr_split(numeric, numeric[], integer)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.split_drop_to_lots(uuid)                 TO authenticated;
GRANT EXECUTE ON FUNCTION public.post_feed_load(uuid)                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.unpost_feed_load(uuid, text)             TO authenticated;
GRANT EXECUTE ON FUNCTION public.void_feed_load(uuid, text)               TO authenticated;
GRANT EXECUTE ON FUNCTION public.post_due_feed_loads()                    TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.rations, public.ration_lines, public.pasture_feed_setup,
    public.feed_trucks, public.bunk_reads, public.feed_loads, public.feed_load_lines,
    public.feed_drops, public.feed_drop_lots, public.feed_load_usage TO authenticated;
GRANT SELECT ON public.feed_truck_lot_item_lb, public.feed_truck_tieout, public.feed_truck_tieout_headdays
    TO authenticated;
REVOKE ALL ON public.rations, public.ration_lines, public.pasture_feed_setup, public.feed_trucks,
    public.bunk_reads, public.feed_loads, public.feed_load_lines, public.feed_drops,
    public.feed_drop_lots, public.feed_load_usage, public.feed_truck_lot_item_lb,
    public.feed_truck_tieout, public.feed_truck_tieout_headdays FROM PUBLIC, anon;


-- ---------------------------------------------------------------------
-- 17. Verify
-- ---------------------------------------------------------------------
DO $verify$
DECLARE
    n integer;
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['rations','ration_lines','pasture_feed_setup','feed_trucks','bunk_reads',
                             'feed_loads','feed_load_lines','feed_drops','feed_drop_lots','feed_load_usage'] LOOP
        IF to_regclass('public.' || t) IS NULL THEN
            RAISE EXCEPTION 'feed_truck verify: table % missing', t;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
                       WHERE ns.nspname = 'public' AND c.relname = t AND c.relrowsecurity) THEN
            RAISE EXCEPTION 'feed_truck verify: RLS not enabled on %', t;
        END IF;
        SELECT COUNT(*) INTO n FROM pg_policies WHERE schemaname = 'public' AND tablename = t;
        IF n < 3 THEN
            RAISE EXCEPTION 'feed_truck verify: % has only % policies', t, n;
        END IF;
    END LOOP;

    FOREACH t IN ARRAY ARRAY['feed_truck_lot_item_lb','feed_truck_tieout','feed_truck_tieout_headdays'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
                       WHERE ns.nspname = 'public' AND c.relname = t AND c.relkind = 'v'
                         AND c.reloptions::text ILIKE '%security_invoker=true%') THEN
            RAISE EXCEPTION 'feed_truck verify: view % is not security_invoker', t;
        END IF;
    END LOOP;

    FOREACH t IN ARRAY ARRAY['post_feed_load','unpost_feed_load','void_feed_load','post_due_feed_loads','split_drop_to_lots','lr_split'] LOOP
        SELECT COUNT(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
         WHERE ns.nspname = 'public' AND p.proname = t;
        IF n <> 1 THEN
            RAISE EXCEPTION 'feed_truck verify: expected exactly one %(), found %', t, n;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
                   WHERE ns.nspname = 'public' AND p.proname = t AND p.prosecdef) THEN
            RAISE EXCEPTION 'feed_truck verify: %() must be SECURITY INVOKER', t;
        END IF;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = 'ranch_settings'
                     AND column_name = 'feed_truck_post_from') THEN
        RAISE EXCEPTION 'feed_truck verify: ranch_settings.feed_truck_post_from missing';
    END IF;

    -- Largest-remainder sanity: 100 over 3:3:3 must come back 33.34/33.33/33.33.
    IF (SELECT public.lr_split(100, ARRAY[3,3,3]::numeric[], 2)) <> ARRAY[33.34,33.33,33.33]::numeric[] THEN
        RAISE EXCEPTION 'feed_truck verify: lr_split does not sum exactly';
    END IF;

    RAISE NOTICE 'feed_truck: OK - 10 tables, 3 views, 6 functions, settings in place.';
END
$verify$;

commit;
