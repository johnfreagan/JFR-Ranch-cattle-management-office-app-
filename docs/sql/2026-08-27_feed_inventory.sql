-- =====================================================================
-- Commodity feed & mineral inventory - phases 1 and 2
-- =====================================================================
-- 2026-08-27. Plan: docs/commodity-feed-inventory-plan.md
--
-- WHAT THIS BUILDS
--
--   phase 1  feed_items, feed_storage_locations, feed_receipts, on-hand
--   phase 2  the usage ledger, FIFO consumption RPCs, physical counts
--
-- THE ONE RULE THIS SCHEMA IS SHAPED BY
--
-- Processing cost in this app is derived LIVE: edit a drug price and it
-- silently rewrites closed lots and prior fiscal years. Treatment cost
-- freezes per row at save time and does not.
--
-- Feed follows treatment. There is NO price column on feed_items - there
-- is nowhere to type one. Price lives on the receipt that brought the load
-- in, and when usage consumes a layer, feed_usage_costs records the layer,
-- the pounds and the dollars as of that moment. Nothing later moves them.
--
-- The single deliberate exception is a receipt that was consumed before it
-- was priced (feed gets delivered before the invoice arrives - it happens).
-- Those cost rows are written NULL and flagged, and recost_pending_usage()
-- fills them in once the receipt is priced. Filling a hole is not the same
-- as rewriting a value, and the function only ever touches rows where cost
-- IS NULL.
--
-- WHY LOCATIONS ARE ONLY WHERE FEED IS STORED
--
-- A location is a bay, a barn or a pallet - somewhere feed is stored and
-- counted. Bulk feeders standing in pastures are deliberately NOT locations
-- (John, 2026-08-27). Feed leaving a bay for a feeder is simply usage, and
-- no book inventory sits out in a pasture.
--
-- WHY FIFO RUNS PER (item, location)
--
-- Corn in Bay 2 and corn in Bay 5 are the same item at two places. FIFO
-- across all locations would let a count on one bay eat a layer physically
-- sitting in another, and on-hand-by-bay would stop reconciling to
-- anything. Physically a bay commingles; FIFO here is a costing convention,
-- not a claim about which kernels went out the door.
--
-- WHY A USAGE ROW CARRIES A PERIOD
--
-- Feed is entered weekly, and the Performance Beef invoice is a date RANGE
-- (the 2026-08-27 sample runs Aug 17-26). A Friday ticket for the week's
-- corn is not a Friday cost: charging it on one date hands a lot that
-- shipped Wednesday two days of feed it never ate. Phase 4 spreads the
-- dollars over the head-days inside [period_start, period_end]. A
-- single-day entry sets both to the same date.
--
-- WHY GOING SHORT IS ALLOWED
--
-- A bulk bay is an estimate. Sooner or later the books think a bay holds
-- 4,200 lb and 6,000 lb gets fed out of it. Refusing to record that does
-- not un-feed the cattle - post_feed_usage costs the shortfall at the
-- item's most recent known price, flags the row is_short, and the next
-- count squares it.
--
-- IDEMPOTENT. Safe to run more than once.
--
-- APPLY: paste into the Supabase SQL editor. If it is ever applied through
-- the CLI instead, strip the begin;/commit; below - the CLI wraps
-- migrations in its own transaction and the inner commit closes it early.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Preconditions
-- ---------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regclass('public.lots') IS NULL
       OR to_regclass('public.pastures') IS NULL
       OR to_regclass('public.ranches') IS NULL THEN
        RAISE EXCEPTION 'Expected tables lots, pastures, ranches are missing. Refusing to proceed.';
    END IF;

    IF NOT EXISTS (
           SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname = 'current_user_role'
       ) THEN
        RAISE EXCEPTION 'public.current_user_role() is missing. Every policy below depends on it.';
    END IF;

    IF NOT EXISTS (
           SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname = 'touch_updated_at'
       ) THEN
        RAISE EXCEPTION 'public.touch_updated_at() is missing - the updated_at triggers depend on it.';
    END IF;

    IF NOT EXISTS (
           SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname = 'ranch_today'
       ) THEN
        RAISE EXCEPTION 'public.ranch_today() is missing - the database runs UTC and the ranch does not.';
    END IF;
END
$pre$;


-- ---------------------------------------------------------------------
-- 1. feed_storage_locations - bays, barns, pallets
-- ---------------------------------------------------------------------
-- Managed entirely in the app: add, rename, re-capacity, deactivate.
-- There is no seed list and no migration to run when a bay changes.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.feed_storage_locations (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ranch_id      uuid REFERENCES public.ranches(id) ON DELETE SET NULL,
    name          text NOT NULL,
    kind          text NOT NULL DEFAULT 'bay'
                    CHECK (kind IN ('bay','barn','pallet','other')),
    -- Bulk is estimated at count time; non-bulk is counted in whole sacks.
    is_bulk       boolean NOT NULL DEFAULT true,
    capacity_lb   numeric CHECK (capacity_lb IS NULL OR capacity_lb > 0),
    is_active     boolean NOT NULL DEFAULT true,
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS feed_storage_locations_name_uniq
    ON public.feed_storage_locations (lower(name));
CREATE INDEX IF NOT EXISTS feed_storage_locations_ranch_idx
    ON public.feed_storage_locations (ranch_id);


-- ---------------------------------------------------------------------
-- 2. feed_items - the catalog. The Medications analogue.
-- ---------------------------------------------------------------------
-- NO PRICE COLUMN, DELIBERATELY. See the header. The first person who
-- "just updates the corn price" would rewrite a year of closeouts, so
-- there is nowhere for them to type it.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.feed_items (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name                  text NOT NULL,
    item_type             text NOT NULL DEFAULT 'bulk_commodity'
                            CHECK (item_type IN ('bulk_commodity','bagged_feed','mineral','additive')),
    category              text,

    -- How the ticket reads. Everything is STORED in pounds; this is the
    -- conversion applied at entry. A ton of corn and a 50 lb sack of the
    -- same product have to be comparable, and PB reports pounds.
    purchase_unit         text NOT NULL DEFAULT 'ton'
                            CHECK (purchase_unit IN ('ton','bag','lb','cwt')),
    lb_per_purchase_unit  numeric NOT NULL DEFAULT 2000
                            CHECK (lb_per_purchase_unit > 0),

    -- true  = counted in whole units (sacks on a pallet)
    -- false = estimated (a bulk bay)
    -- Recorded because a -4,000 lb variance on an estimated bay is Tuesday
    -- and the same variance on counted sacks is a theft or a keying error.
    is_counted            boolean NOT NULL DEFAULT false,

    -- Performance Beef's own name for it. "Corn hopper bin" is a commodity
    -- and a bin in one string; the import matches on this, not on `name`.
    pb_name               text,

    -- Redwing coding, carried onto the accounting export (phase 5).
    redwing_account            text,
    redwing_profit_center      text,
    redwing_production_center  text,

    default_location_id   uuid REFERENCES public.feed_storage_locations(id) ON DELETE SET NULL,
    is_active             boolean NOT NULL DEFAULT true,
    notes                 text,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    created_by            uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS feed_items_name_uniq
    ON public.feed_items (lower(name));
-- Two items claiming the same PB name would make the import ambiguous and
-- it would pick one silently.
CREATE UNIQUE INDEX IF NOT EXISTS feed_items_pb_name_uniq
    ON public.feed_items (lower(pb_name)) WHERE pb_name IS NOT NULL;


-- ---------------------------------------------------------------------
-- 3. feed_receipts - a load in. THIS ROW IS THE FIFO LAYER.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.feed_receipts (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_date        date NOT NULL,
    item_id             uuid NOT NULL REFERENCES public.feed_items(id) ON DELETE RESTRICT,
    location_id         uuid NOT NULL REFERENCES public.feed_storage_locations(id) ON DELETE RESTRICT,

    vendor              text,
    ticket_number       text,
    invoice_number      text,

    -- Typed in the unit on the ticket, stored in pounds. Both are kept:
    -- "12.5 ton" is the fact that was observed, and reconstructing it from
    -- 25,000 lb invites an off-by-one when someone edits the conversion.
    qty_purchase_units  numeric CHECK (qty_purchase_units IS NULL OR qty_purchase_units > 0),
    qty_lb              numeric NOT NULL CHECK (qty_lb > 0),

    -- Freight is capitalized into the layer. A delivered $/ton is the only
    -- number that means anything; splitting freight into its own expense
    -- line would make every lot's feed cost read low.
    product_cost        numeric CHECK (product_cost IS NULL OR product_cost >= 0),
    freight_cost        numeric CHECK (freight_cost IS NULL OR freight_cost >= 0),
    other_cost          numeric CHECK (other_cost IS NULL OR other_cost >= 0),

    -- The unpriced-medication trap, headed off. An uncosted receipt yields
    -- NULL, SUM() ignores NULL, and the feed silently becomes free instead
    -- of erroring. So an uncosted receipt only saves under an EXPLICIT
    -- flag, and everything downstream can see it.
    cost_pending        boolean NOT NULL DEFAULT false,

    -- Generated from the base columns. Postgres will not let a generated
    -- column reference another generated column, so both restate the sum.
    total_cost          numeric GENERATED ALWAYS AS (
                            CASE WHEN cost_pending THEN NULL
                                 ELSE COALESCE(product_cost,0) + COALESCE(freight_cost,0) + COALESCE(other_cost,0)
                            END) STORED,
    unit_cost_per_lb    numeric GENERATED ALWAYS AS (
                            CASE WHEN cost_pending THEN NULL
                                 ELSE (COALESCE(product_cost,0) + COALESCE(freight_cost,0) + COALESCE(other_cost,0))
                                      / NULLIF(qty_lb,0)
                            END) STORED,

    -- Only the RPCs touch this.
    qty_lb_remaining    numeric NOT NULL CHECK (qty_lb_remaining >= 0),

    -- 'purchase' is a real load in. 'count_adjustment' is inventory found
    -- by a physical count, priced at the item's last known cost.
    source              text NOT NULL DEFAULT 'purchase'
                            CHECK (source IN ('purchase','count_adjustment','transfer_in')),

    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid REFERENCES auth.users(id) ON DELETE SET NULL,

    CONSTRAINT feed_receipts_remaining_le_qty CHECK (qty_lb_remaining <= qty_lb)
);

-- The FIFO read: oldest un-emptied layer for an (item, location).
CREATE INDEX IF NOT EXISTS feed_receipts_fifo_idx
    ON public.feed_receipts (item_id, location_id, receipt_date, created_at)
    WHERE qty_lb_remaining > 0;
CREATE INDEX IF NOT EXISTS feed_receipts_date_idx ON public.feed_receipts (receipt_date DESC);
CREATE INDEX IF NOT EXISTS feed_receipts_item_idx ON public.feed_receipts (item_id);


-- ---------------------------------------------------------------------
-- 4. feed_usage - the ledger. Feed-outs, adjustments and transfers.
-- ---------------------------------------------------------------------
-- One place to answer "where did the pounds go" beats two.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.feed_usage (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- usage_date is when it was recorded; the PERIOD is what the cost
    -- spreads across in phase 4. A single-day entry sets both to usage_date.
    usage_date        date NOT NULL,
    period_start      date NOT NULL,
    period_end        date NOT NULL,

    item_id           uuid NOT NULL REFERENCES public.feed_items(id) ON DELETE RESTRICT,
    from_location_id  uuid NOT NULL REFERENCES public.feed_storage_locations(id) ON DELETE RESTRICT,

    destination_type  text NOT NULL
                        CHECK (destination_type IN ('lot','pasture','adjustment','transfer')),
    lot_id            uuid REFERENCES public.lots(id) ON DELETE RESTRICT,
    pasture_id        uuid REFERENCES public.pastures(id) ON DELETE SET NULL,
    to_location_id    uuid REFERENCES public.feed_storage_locations(id) ON DELETE RESTRICT,

    qty_lb            numeric NOT NULL CHECK (qty_lb > 0),

    source            text NOT NULL DEFAULT 'manual'
                        CHECK (source IN ('manual','pb_import','count','correction')),

    -- UPSERT key for the PB import, NOT a duplicate check. Re-importing the
    -- same invoice must overwrite, not double-feed. Note this does nothing
    -- about an OVERLAPPING import - see the plan; that guard belongs in
    -- import_pb_usage (phase 3).
    pb_row_key        text,

    -- The bay was short: some of these pounds had no layer to come from and
    -- were costed at the item's most recent known price.
    is_short          boolean NOT NULL DEFAULT false,
    -- Some of these pounds came off a layer that had no price yet.
    -- recost_pending_usage() fills those in once the receipt is priced.
    cost_pending      boolean NOT NULL DEFAULT false,

    reason            text,
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL,

    CONSTRAINT feed_usage_period_ordered CHECK (period_end >= period_start),
    -- A destination that does not identify anything would allocate to
    -- nowhere in phase 4, silently.
    CONSTRAINT feed_usage_destination_shape CHECK (
        (destination_type = 'lot'        AND lot_id IS NOT NULL AND to_location_id IS NULL)
     OR (destination_type = 'pasture'    AND pasture_id IS NOT NULL AND to_location_id IS NULL)
     OR (destination_type = 'adjustment' AND to_location_id IS NULL)
     OR (destination_type = 'transfer'   AND to_location_id IS NOT NULL)
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS feed_usage_pb_row_key_uniq
    ON public.feed_usage (pb_row_key) WHERE pb_row_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS feed_usage_period_idx ON public.feed_usage (period_start, period_end);
CREATE INDEX IF NOT EXISTS feed_usage_lot_idx    ON public.feed_usage (lot_id) WHERE lot_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS feed_usage_item_idx   ON public.feed_usage (item_id);
CREATE INDEX IF NOT EXISTS feed_usage_date_idx   ON public.feed_usage (usage_date DESC);

-- A transfer lays a new layer down at the destination. Link it to the
-- usage that created it BY ID, so the reversal finds it by key rather than
-- by matching a notes string - which is the kind of thing that works until
-- somebody edits the note.
-- Added here rather than in the CREATE TABLE above because feed_receipts
-- is declared before feed_usage exists.
ALTER TABLE public.feed_receipts
    ADD COLUMN IF NOT EXISTS from_usage_id uuid REFERENCES public.feed_usage(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS feed_receipts_from_usage_idx
    ON public.feed_receipts (from_usage_id) WHERE from_usage_id IS NOT NULL;


-- ---------------------------------------------------------------------
-- 5. feed_usage_costs - the frozen money
-- ---------------------------------------------------------------------
-- One row per layer the usage ate through. This is what makes a reversal
-- exact: put qty_lb back on receipt_id and the layers are as they were.
-- It is the doctoring_event_meds.cost of this module.
--
-- receipt_id IS NULL means the bay went short - there was no layer. The
-- cost basis is still recorded so the money is auditable.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.feed_usage_costs (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usage_id          uuid NOT NULL REFERENCES public.feed_usage(id) ON DELETE CASCADE,
    receipt_id        uuid REFERENCES public.feed_receipts(id) ON DELETE RESTRICT,
    qty_lb            numeric NOT NULL CHECK (qty_lb > 0),
    unit_cost_per_lb  numeric,
    cost              numeric,
    is_short          boolean NOT NULL DEFAULT false,
    created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS feed_usage_costs_usage_idx   ON public.feed_usage_costs (usage_id);
CREATE INDEX IF NOT EXISTS feed_usage_costs_receipt_idx ON public.feed_usage_costs (receipt_id);
CREATE INDEX IF NOT EXISTS feed_usage_costs_pending_idx
    ON public.feed_usage_costs (receipt_id) WHERE cost IS NULL AND receipt_id IS NOT NULL;


-- ---------------------------------------------------------------------
-- 6. feed_counts / feed_count_lines - the physical count
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.feed_counts (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    count_date   date NOT NULL,
    location_id  uuid NOT NULL REFERENCES public.feed_storage_locations(id) ON DELETE RESTRICT,
    status       text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted')),
    posted_at    timestamptz,
    posted_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS feed_counts_location_idx ON public.feed_counts (location_id, count_date DESC);

CREATE TABLE IF NOT EXISTS public.feed_count_lines (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    count_id               uuid NOT NULL REFERENCES public.feed_counts(id) ON DELETE CASCADE,
    item_id                uuid NOT NULL REFERENCES public.feed_items(id) ON DELETE RESTRICT,

    counted_qty_lb         numeric NOT NULL CHECK (counted_qty_lb >= 0),
    -- Bagged is counted; bulk is estimated. Which one it was is a fact
    -- about the number, and the variance report must not present them as
    -- the same kind of fact.
    method                 text NOT NULL DEFAULT 'estimated'
                             CHECK (method IN ('counted_bags','estimated','measured')),
    bags_counted           numeric CHECK (bags_counted IS NULL OR bags_counted >= 0),
    estimate_note          text,

    -- Snapshotted at post time, not recomputed later.
    book_qty_lb            numeric,
    variance_lb            numeric,
    adjustment_usage_id    uuid REFERENCES public.feed_usage(id) ON DELETE SET NULL,
    adjustment_receipt_id  uuid REFERENCES public.feed_receipts(id) ON DELETE SET NULL,

    created_at             timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT feed_count_lines_one_per_item UNIQUE (count_id, item_id)
);

CREATE INDEX IF NOT EXISTS feed_count_lines_count_idx ON public.feed_count_lines (count_id);


-- ---------------------------------------------------------------------
-- 7. updated_at triggers
-- ---------------------------------------------------------------------
DO $trg$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['feed_storage_locations','feed_items','feed_receipts','feed_usage','feed_counts']
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_touch_updated_at', t);
        EXECUTE format(
            'CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at()',
            t || '_touch_updated_at', t);
    END LOOP;
END
$trg$;


-- ---------------------------------------------------------------------
-- 8. RLS - office + owner only. Crew sees none of it.
-- ---------------------------------------------------------------------
-- Feed is a cost surface, and the standing rule is that crew cannot read
-- cost or margin data. Deletes are owner-only: feed_usage and feed_receipts
-- are audit trails, and an accidental delete there is unrecoverable in a
-- way an accidental insert is not.
--
-- ENABLE without policies is a total lockout; policies without ENABLE are
-- decoration. Both, every table.
-- ---------------------------------------------------------------------
ALTER TABLE public.feed_storage_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_items             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_receipts          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_usage             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_usage_costs       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_counts            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_count_lines       ENABLE ROW LEVEL SECURITY;

DO $pol$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['feed_storage_locations','feed_items','feed_receipts',
                             'feed_usage','feed_usage_costs','feed_counts','feed_count_lines']
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_select', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_insert', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_update', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_delete', t);

        EXECUTE format($f$
            CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
            USING (public.current_user_role() = ANY (ARRAY['owner','office']))$f$,
            t || '_select', t);
        EXECUTE format($f$
            CREATE POLICY %I ON public.%I FOR INSERT TO authenticated
            WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']))$f$,
            t || '_insert', t);
        EXECUTE format($f$
            CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated
            USING (public.current_user_role() = ANY (ARRAY['owner','office']))
            WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']))$f$,
            t || '_update', t);
        EXECUTE format($f$
            CREATE POLICY %I ON public.%I FOR DELETE TO authenticated
            USING (public.current_user_role() = 'owner')$f$,
            t || '_delete', t);
    END LOOP;
END
$pol$;

-- Never GRANT to anon. authenticated + RLS is the only path. And revoke
-- from PUBLIC, not just anon - Postgres grants EXECUTE to PUBLIC by
-- default, so revoking from anon alone silently does nothing.
DO $grants$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['feed_storage_locations','feed_items','feed_receipts',
                             'feed_usage','feed_usage_costs','feed_counts','feed_count_lines']
    LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', t);
        EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    END LOOP;
END
$grants$;


-- ---------------------------------------------------------------------
-- 9. Views. All security_invoker - without it a view runs as its OWNER
--    and bypasses RLS entirely regardless of the policies above.
-- ---------------------------------------------------------------------

-- What is standing where, and what it is worth.
CREATE OR REPLACE VIEW public.feed_on_hand
WITH (security_invoker = true) AS
SELECT
    r.item_id,
    i.name                                   AS item_name,
    i.item_type,
    i.purchase_unit,
    i.lb_per_purchase_unit,
    r.location_id,
    l.name                                   AS location_name,
    l.is_bulk,
    l.capacity_lb,
    SUM(r.qty_lb_remaining)                                        AS qty_lb,
    SUM(r.qty_lb_remaining) / NULLIF(i.lb_per_purchase_unit,0)     AS qty_purchase_units,
    -- Value counts only the layers that actually have a price. Pounds
    -- sitting on an unpriced layer are reported separately rather than
    -- being valued at zero.
    SUM(CASE WHEN r.cost_pending THEN 0 ELSE r.qty_lb_remaining * r.unit_cost_per_lb END)  AS value_usd,
    SUM(CASE WHEN r.cost_pending THEN r.qty_lb_remaining ELSE 0 END)                       AS pending_cost_lb,
    CASE WHEN SUM(CASE WHEN r.cost_pending THEN 0 ELSE r.qty_lb_remaining END) > 0
         THEN SUM(CASE WHEN r.cost_pending THEN 0 ELSE r.qty_lb_remaining * r.unit_cost_per_lb END)
              / SUM(CASE WHEN r.cost_pending THEN 0 ELSE r.qty_lb_remaining END)
    END                                                            AS avg_cost_per_lb,
    MIN(r.receipt_date)                                            AS oldest_layer_date,
    COUNT(*)                                                       AS layer_count
FROM public.feed_receipts r
JOIN public.feed_items i             ON i.id = r.item_id
JOIN public.feed_storage_locations l ON l.id = r.location_id
WHERE r.qty_lb_remaining > 0
GROUP BY r.item_id, i.name, i.item_type, i.purchase_unit, i.lb_per_purchase_unit,
         r.location_id, l.name, l.is_bulk, l.capacity_lb;

-- Rolled to the item, across every bay.
CREATE OR REPLACE VIEW public.feed_item_on_hand
WITH (security_invoker = true) AS
SELECT
    item_id,
    item_name,
    item_type,
    purchase_unit,
    lb_per_purchase_unit,
    SUM(qty_lb)             AS qty_lb,
    SUM(qty_purchase_units) AS qty_purchase_units,
    SUM(value_usd)          AS value_usd,
    SUM(pending_cost_lb)    AS pending_cost_lb,
    CASE WHEN SUM(qty_lb - pending_cost_lb) > 0
         THEN SUM(value_usd) / SUM(qty_lb - pending_cost_lb) END AS avg_cost_per_lb,
    MIN(oldest_layer_date)  AS oldest_layer_date,
    COUNT(*)                AS location_count
FROM public.feed_on_hand
GROUP BY item_id, item_name, item_type, purchase_unit, lb_per_purchase_unit;

-- The ledger, readable. What went out, where to, and what it cost.
CREATE OR REPLACE VIEW public.feed_usage_detail
WITH (security_invoker = true) AS
SELECT
    u.id                AS usage_id,
    u.usage_date,
    u.period_start,
    u.period_end,
    (u.period_end - u.period_start + 1)              AS period_days,
    u.item_id,
    i.name              AS item_name,
    i.item_type,
    u.from_location_id,
    fl.name             AS from_location_name,
    u.destination_type,
    u.lot_id,
    lo.lot_number,
    u.pasture_id,
    pa.name             AS pasture_name,
    u.to_location_id,
    tl.name             AS to_location_name,
    u.qty_lb,
    u.source,
    u.is_short,
    u.cost_pending,
    u.reason,
    u.notes,
    COALESCE(c.cost, 0)                              AS cost_usd,
    CASE WHEN u.qty_lb > 0 THEN COALESCE(c.cost,0) / u.qty_lb END AS cost_per_lb,
    COALESCE(c.pending_lines, 0)                     AS pending_cost_lines,
    u.created_at
FROM public.feed_usage u
JOIN public.feed_items i               ON i.id = u.item_id
JOIN public.feed_storage_locations fl  ON fl.id = u.from_location_id
LEFT JOIN public.feed_storage_locations tl ON tl.id = u.to_location_id
LEFT JOIN public.lots lo               ON lo.id = u.lot_id
LEFT JOIN public.pastures pa           ON pa.id = u.pasture_id
LEFT JOIN LATERAL (
    SELECT SUM(fc.cost)                                   AS cost,
           COUNT(*) FILTER (WHERE fc.cost IS NULL)        AS pending_lines
    FROM public.feed_usage_costs fc WHERE fc.usage_id = u.id
) c ON true;

-- Book vs counted, with the method carried through.
CREATE OR REPLACE VIEW public.feed_count_variance
WITH (security_invoker = true) AS
SELECT
    c.id            AS count_id,
    c.count_date,
    c.status,
    c.location_id,
    l.name          AS location_name,
    cl.id           AS line_id,
    cl.item_id,
    i.name          AS item_name,
    i.is_counted    AS item_is_counted,
    cl.method,
    cl.bags_counted,
    cl.counted_qty_lb,
    cl.book_qty_lb,
    cl.variance_lb,
    CASE WHEN cl.book_qty_lb > 0 THEN cl.variance_lb / cl.book_qty_lb END AS variance_pct,
    cl.estimate_note
FROM public.feed_counts c
JOIN public.feed_storage_locations l ON l.id = c.location_id
JOIN public.feed_count_lines cl      ON cl.count_id = c.id
JOIN public.feed_items i             ON i.id = cl.item_id;

DO $vgrant$
DECLARE v text;
BEGIN
    FOREACH v IN ARRAY ARRAY['feed_on_hand','feed_item_on_hand','feed_usage_detail','feed_count_variance']
    LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', v);
        EXECUTE format('REVOKE ALL ON public.%I FROM anon', v);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', v);
    END LOOP;
END
$vgrant$;


-- ---------------------------------------------------------------------
-- 10. post_feed_usage - consume FIFO layers, freeze the money
-- ---------------------------------------------------------------------
-- INVOKER, like every other head-math RPC in this app. Nothing here needs
-- to bypass RLS, and SECURITY DEFINER without a reason is how a hole gets
-- opened.
--
-- Consumes oldest-first within (item, from_location). If the layers run
-- out, the remainder is costed at the item's most recent known unit price
-- and flagged is_short - see the header for why that beats refusing.
-- ---------------------------------------------------------------------
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
    p_notes             text    DEFAULT NULL
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

    -- ranch_today(), never CURRENT_DATE. The database runs UTC and the
    -- ranch does not: CURRENT_DATE becomes tomorrow at 7pm Central.
    v_usage_date := COALESCE(p_usage_date, public.ranch_today());
    v_start      := COALESCE(p_period_start, v_usage_date);
    v_end        := COALESCE(p_period_end,   v_start);

    IF v_end < v_start THEN
        RAISE EXCEPTION 'post_feed_usage: period_end (%) is before period_start (%).', v_end, v_start;
    END IF;

    IF p_destination_type = 'transfer' AND p_to_location_id = p_from_location_id THEN
        RAISE EXCEPTION 'post_feed_usage: a transfer to the same location is a no-op.';
    END IF;

    INSERT INTO public.feed_usage (
        usage_date, period_start, period_end, item_id, from_location_id,
        destination_type, lot_id, pasture_id, to_location_id,
        qty_lb, source, pb_row_key, reason, notes, created_by
    ) VALUES (
        v_usage_date, v_start, v_end, p_item_id, p_from_location_id,
        p_destination_type, p_lot_id, p_pasture_id, p_to_location_id,
        p_qty_lb, COALESCE(p_source,'manual'), p_pb_row_key, p_reason, p_notes, auth.uid()
    ) RETURNING id INTO v_usage_id;

    -- FIFO: oldest layer first, within this item AND this location.
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

        INSERT INTO public.feed_usage_costs (usage_id, receipt_id, qty_lb, unit_cost_per_lb, cost)
        VALUES (v_usage_id, layer_rec.id, v_take, layer_rec.unit_cost_per_lb,
                CASE WHEN layer_rec.unit_cost_per_lb IS NULL THEN NULL
                     ELSE ROUND(v_take * layer_rec.unit_cost_per_lb, 4) END);

        IF layer_rec.unit_cost_per_lb IS NULL THEN v_pending := true; END IF;

        UPDATE public.feed_receipts
           SET qty_lb_remaining = qty_lb_remaining - v_take
         WHERE id = layer_rec.id;

        v_remaining := v_remaining - v_take;
    END LOOP;

    -- The bay went short. Cost the remainder at the most recent price we
    -- know for this item - preferring this location, then anywhere.
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
                CASE WHEN v_last_cost IS NULL THEN NULL ELSE ROUND(v_remaining * v_last_cost, 4) END,
                true);

        IF v_last_cost IS NULL THEN v_pending := true; END IF;
    END IF;

    -- A transfer creates the layer on the far side at the cost it left at,
    -- so moving corn between bays does not invent or destroy value.
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
            v_usage_date, p_item_id, p_to_location_id, '(transfer)',
            'Transferred in.',
            p_qty_lb, v_to_loc_row.cost, (v_to_loc_row.pending_lines > 0), p_qty_lb,
            'transfer_in', v_usage_id, auth.uid()
        ) RETURNING id INTO v_new_receipt;
    END IF;

    IF v_short OR v_pending THEN
        UPDATE public.feed_usage
           SET is_short = v_short, cost_pending = v_pending
         WHERE id = v_usage_id;
    END IF;

    RETURN v_usage_id;
END
$fn$;


-- ---------------------------------------------------------------------
-- 11. delete_feed_usage - the reversal
-- ---------------------------------------------------------------------
-- THE TRAP THIS AVOIDS, in its feed form: in delete_death_event, reopening
-- a closed assignment AND adding head back double-counted - 3 head died,
-- the reversal brought back 6. Here the equivalent mistake would be
-- special-casing a layer that was consumed to exactly zero. There is no
-- branch. Every cost row is just "put the pounds back on its receipt".
-- Short rows have no receipt and restore nothing, which is correct: no
-- layer gave those pounds up.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_feed_usage(p_usage_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_usage    record;
    v_moved    numeric;
    cost_rec   record;
BEGIN
    SELECT * INTO v_usage FROM public.feed_usage WHERE id = p_usage_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'delete_feed_usage: usage % not found.', p_usage_id;
    END IF;

    -- A transfer put a layer down on the far side. If any of it has been
    -- fed already, reversing would leave the far bay short of pounds it
    -- no longer has. Refuse rather than silently unbalance two bays.
    IF v_usage.destination_type = 'transfer' THEN
        SELECT COALESCE(SUM(qty_lb - qty_lb_remaining), 0) INTO v_moved
        FROM public.feed_receipts WHERE from_usage_id = p_usage_id;

        IF v_moved > 0 THEN
            RAISE EXCEPTION
                'delete_feed_usage: % lb of the transferred feed has already been used at the destination. Reverse that usage first.',
                v_moved;
        END IF;

        DELETE FROM public.feed_receipts WHERE from_usage_id = p_usage_id;
    END IF;

    FOR cost_rec IN
        SELECT receipt_id, qty_lb FROM public.feed_usage_costs
        WHERE usage_id = p_usage_id AND receipt_id IS NOT NULL
    LOOP
        UPDATE public.feed_receipts
           SET qty_lb_remaining = qty_lb_remaining + cost_rec.qty_lb
         WHERE id = cost_rec.receipt_id;
    END LOOP;

    -- feed_usage_costs cascades.
    DELETE FROM public.feed_usage WHERE id = p_usage_id;
END
$fn$;


-- ---------------------------------------------------------------------
-- 12. delete_feed_receipt - refuses once any of its pounds are consumed
-- ---------------------------------------------------------------------
-- Consumed pounds carry frozen costs downstream. Orphaning them is the
-- whole disaster this module exists to avoid, so the reversal has to come
-- first and in the right order.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_feed_receipt(p_receipt_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE v_r record;
BEGIN
    SELECT * INTO v_r FROM public.feed_receipts WHERE id = p_receipt_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'delete_feed_receipt: receipt % not found.', p_receipt_id;
    END IF;

    IF v_r.qty_lb_remaining <> v_r.qty_lb THEN
        RAISE EXCEPTION
            'delete_feed_receipt: % of % lb on this load has already been fed out. Reverse that usage first, then delete the load.',
            (v_r.qty_lb - v_r.qty_lb_remaining), v_r.qty_lb;
    END IF;

    DELETE FROM public.feed_receipts WHERE id = p_receipt_id;
END
$fn$;


-- ---------------------------------------------------------------------
-- 13. recost_pending_usage - fill the holes, never rewrite a value
-- ---------------------------------------------------------------------
-- Feed gets delivered before the invoice arrives, gets fed, and only then
-- gets priced. Those cost rows were written NULL. This fills them in.
--
-- It is guarded to rows where cost IS NULL, so it can never move a frozen
-- number. That guard is the whole reason this is allowed to exist.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recost_pending_usage(p_receipt_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_r      record;
    v_count  integer;
BEGIN
    SELECT * INTO v_r FROM public.feed_receipts WHERE id = p_receipt_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'recost_pending_usage: receipt % not found.', p_receipt_id;
    END IF;
    IF v_r.unit_cost_per_lb IS NULL THEN
        RAISE EXCEPTION 'recost_pending_usage: receipt % still has no price. Price it first.', p_receipt_id;
    END IF;

    UPDATE public.feed_usage_costs
       SET unit_cost_per_lb = v_r.unit_cost_per_lb,
           cost             = ROUND(qty_lb * v_r.unit_cost_per_lb, 4)
     WHERE receipt_id = p_receipt_id
       AND cost IS NULL;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    -- Clear the flag on any usage that now has no holes left.
    UPDATE public.feed_usage u
       SET cost_pending = false
     WHERE u.cost_pending
       AND NOT EXISTS (
           SELECT 1 FROM public.feed_usage_costs fc
           WHERE fc.usage_id = u.id AND fc.cost IS NULL);

    RETURN v_count;
END
$fn$;


-- ---------------------------------------------------------------------
-- 14. post_feed_count - variance becomes real ledger rows
-- ---------------------------------------------------------------------
-- Short of book  -> an 'adjustment' usage, consuming FIFO like any other.
-- Over book      -> a receipt priced at the item's last known cost, so the
--                   found feed has a cost basis instead of appearing free.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_feed_count(p_count_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_c          record;
    v_line       record;
    v_book       numeric;
    v_var        numeric;
    v_last_cost  numeric;
    v_usage_id   uuid;
    v_receipt_id uuid;
    v_posted     integer := 0;
BEGIN
    SELECT * INTO v_c FROM public.feed_counts WHERE id = p_count_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'post_feed_count: count % not found.', p_count_id;
    END IF;
    IF v_c.status = 'posted' THEN
        RAISE EXCEPTION 'post_feed_count: this count was already posted. Start a new one.';
    END IF;

    FOR v_line IN
        SELECT * FROM public.feed_count_lines WHERE count_id = p_count_id
    LOOP
        SELECT COALESCE(SUM(qty_lb_remaining), 0) INTO v_book
        FROM public.feed_receipts
        WHERE item_id = v_line.item_id AND location_id = v_c.location_id;

        v_var := v_line.counted_qty_lb - v_book;
        v_usage_id := NULL;
        v_receipt_id := NULL;

        IF v_var < 0 THEN
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


-- Function grants: revoke from PUBLIC (Postgres grants EXECUTE to PUBLIC
-- by default, so revoking from anon alone silently does nothing).
DO $fgrant$
DECLARE sig text;
BEGIN
    FOREACH sig IN ARRAY ARRAY[
        'public.post_feed_usage(uuid,uuid,numeric,text,date,date,uuid,uuid,uuid,date,text,text,text,text)',
        'public.delete_feed_usage(uuid)',
        'public.delete_feed_receipt(uuid)',
        'public.recost_pending_usage(uuid)',
        'public.post_feed_count(uuid)'
    ]
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', sig);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', sig);
    END LOOP;
END
$fgrant$;


-- ---------------------------------------------------------------------
-- 15. Verify what we just built
-- ---------------------------------------------------------------------
DO $verify$
DECLARE
    t text;
    v text;
    n integer;
BEGIN
    -- Every table has RLS ENABLED and at least one policy. Either half
    -- alone is useless: ENABLE without policies is a total lockout,
    -- policies without ENABLE are decoration.
    FOREACH t IN ARRAY ARRAY['feed_storage_locations','feed_items','feed_receipts',
                             'feed_usage','feed_usage_costs','feed_counts','feed_count_lines']
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace ns ON ns.oid=c.relnamespace
                       WHERE ns.nspname='public' AND c.relname=t AND c.relrowsecurity) THEN
            RAISE EXCEPTION 'RLS is not enabled on public.%', t;
        END IF;
        SELECT count(*) INTO n FROM pg_policies WHERE schemaname='public' AND tablename=t;
        IF n < 4 THEN
            RAISE EXCEPTION 'public.% has only % policies, expected 4.', t, n;
        END IF;
        IF has_table_privilege('anon', 'public.'||t, 'SELECT') THEN
            RAISE EXCEPTION 'anon can SELECT public.% - the publishable key is public, so that is public.', t;
        END IF;
    END LOOP;

    -- Every view must be security_invoker or it runs as its owner and
    -- bypasses every policy above.
    FOREACH v IN ARRAY ARRAY['feed_on_hand','feed_item_on_hand','feed_usage_detail','feed_count_variance']
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_class c JOIN pg_namespace ns ON ns.oid=c.relnamespace
            WHERE ns.nspname='public' AND c.relname=v
              AND c.reloptions @> ARRAY['security_invoker=true']
        ) THEN
            RAISE EXCEPTION 'public.% lacks security_invoker - it would bypass RLS.', v;
        END IF;
        IF has_table_privilege('anon', 'public.'||v, 'SELECT') THEN
            RAISE EXCEPTION 'anon can SELECT public.% view.', v;
        END IF;
    END LOOP;

    -- And there is no price on the item. If this ever fails, someone added
    -- one and a year of closeouts is about to become editable.
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='feed_items'
                 AND column_name IN ('cost_per_lb','price','cost_per_ton','unit_cost')) THEN
        RAISE EXCEPTION 'feed_items has a price column. Price belongs on the receipt layer - see the header of this file.';
    END IF;

    RAISE NOTICE 'Feed inventory phases 1-2: 7 tables, 4 views, 5 functions. RLS and grants verified.';
END
$verify$;

commit;

-- =====================================================================
-- AFTER APPLYING
--
-- Run supabase/migrations/20260821000300_rls_verify.sql, which asserts the
-- project-wide rules across every object, not just these.
--
-- Then in the app: Feed -> Locations to add your bays, Feed -> Items to
-- add the commodities. The 2026-08-27 PB invoice named eight:
--   Corn hopper bin, Molasses, DDG, Peanut Hulls, SoyHull Pellets,
--   Whole Cottonseed, Deccox-Corrid Crumbles, Pennchlor 50G
-- The last two are feed-grade drugs - item_type 'additive', and they
-- probably want animal-health Redwing coding rather than feed coding.
-- =====================================================================
