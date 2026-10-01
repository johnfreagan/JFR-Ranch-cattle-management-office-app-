-- =====================================================================
-- Medicine inventory on FIFO - wave 1: the ledger and the count
-- =====================================================================
-- 2026-10-01. Decisions and reasoning: docs/medicine-inventory-design.md
--
-- WHAT THIS BUILDS
--
--   med_stock_locations     the ranch, and one row per buyer who processes
--   med_crew_members        the men who carry bottles (a login is optional)
--   med_purchases           one supplier invoice
--   med_purchase_lines      THE FIFO LAYER - location and qty_remaining on it
--   med_txns                every movement
--   med_txn_layers          which layers a movement took, at what cost
--   med_counts              a physical count
--   med_count_lines         barn + crew, full bottles + the open one
--
-- WHY THIS EXISTS
--
-- Today a bottle is charged out whole when it leaves the barn and spread
-- across lots by head-days, like mineral, because nothing could say which
-- lot actually got the drug. That is what this replaces. John, 2026-08-29:
-- "We can change redwing entry to match lot usage now, just never had
-- capability before this program. Hence my desire to build."
--
-- WHAT THIS WAVE DELIBERATELY DOES NOT DO
--
-- It does not change how anything is COSTED. `doctoring_event_meds.cost`
-- keeps its frozen value and processing cost keeps deriving live off
-- `medications`. Usage is recorded here in PARALLEL, at FIFO cost, so the
-- two numbers can be held against each other over a real month before
-- either cost stream is switched. Shrink allocation to lots, the closeout
-- Animal-health roll-up and the processing draw are wave 2, due before the
-- first month CLOSES rather than before the first count.
--
-- THE SPINE
--
-- `supply_order_lines` already carries meds: `item_kind IN ('feed','med')`,
-- a `medication_id` FK and a CHECK that exactly one catalog is set
-- (docs/inventory-flow-design.md decision 1). This file adds the med
-- LEDGER only; ordering, delivery and invoice paperwork stay shared. The
-- obligation that document records - "when the med design lands, check it
-- against the spine before building" - is discharged by the verify block at
-- the bottom, which asserts a med order line needs no schema change.
--
-- WHY A PURCHASE LINE IS THE FIFO LAYER
--
-- An earlier draft had a separate layer table plus a transfer RPC that split
-- layers and mirrored them at the destination. All of it existed to move
-- stock between locations, and stock does not move: ranch meds stay at the
-- ranch, and a buyer's pickup at the supplier never comes here. So the line
-- carries `location_id` and `qty_remaining` and IS the layer. If stock ever
-- genuinely moves it is an adjustment out and an adjustment in, which the
-- count screen already writes.
--
-- WHY purchase_id IS NULLABLE
--
-- A layer is born three ways: bought, counted in at go-live, or found by a
-- later count. The last two have no invoice. Making it nullable means the
-- opening count is not a special mechanism - it is a count against an empty
-- ledger, running the same code path as every later one.
--
-- APPLY THROUGH THE SQL EDITOR. The begin;/commit; below make it
-- all-or-nothing there; strip both lines for apply_migration or the CLI.
-- Run supabase/migrations/20260821000300_rls_verify.sql afterwards.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Preflight. Refuse to run against a schema that is not what we think.
-- ---------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regclass('public.medications') IS NULL
       OR to_regclass('public.doctoring_event_meds') IS NULL
       OR to_regclass('public.delivery_receipts') IS NULL
       OR to_regclass('public.pending_field_entries') IS NULL
       OR to_regclass('public.lots') IS NULL THEN
        RAISE EXCEPTION 'Expected tables are missing. Refusing to proceed.';
    END IF;

    -- The shared ordering spine. A hard dependency, not an optional
    -- integration: med_purchases.order_line_id points into it, and
    -- docs/inventory-flow-design.md decision 2 made this migration prove
    -- the spine takes a med line with no schema change (section 18).
    IF to_regclass('public.supply_order_lines') IS NULL THEN
        RAISE EXCEPTION 'public.supply_order_lines is missing - apply '
                        '2026-08-31_inventory_flow.sql first. Refusing to proceed.';
    END IF;

    -- The count's approvals gate and the period lock both depend on these.
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname='public' AND p.proname='current_user_role') THEN
        RAISE EXCEPTION 'public.current_user_role() is missing. Every policy below depends on it.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname='public' AND p.proname='can_read_books') THEN
        RAISE EXCEPTION 'public.can_read_books() is missing. SELECT policies below read money and must go through it.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname='public' AND p.proname='ranch_today') THEN
        RAISE EXCEPTION 'public.ranch_today() is missing. The database runs UTC and the ranch does not; every date default here depends on it.';
    END IF;

    -- to_regclass resolves views and sequences too. Anything we ALTER must be
    -- an ordinary table, or the ALTER aborts the migration and silently
    -- leaves everything after it unapplied.
    IF (SELECT relkind FROM pg_class WHERE oid = to_regclass('public.medications')) <> 'r' THEN
        RAISE EXCEPTION 'public.medications is not an ordinary table (relkind %).',
            (SELECT relkind FROM pg_class WHERE oid = to_regclass('public.medications'));
    END IF;
END
$pre$;


-- ---------------------------------------------------------------------
-- 1. medications: the Redwing code, and what is in scope
-- ---------------------------------------------------------------------
-- The opening count is valued at Redwing's carrying value item by item - the
-- physical count sets the QUANTITY, Redwing sets the PRICE - so day one ties
-- to the penny and every later divergence is a real transaction. That needs
-- the items matched, which is what this column is for. The sales accounting
-- report prints lot numbers as the app holds them because we refused to
-- guess Redwing's mapping; here there is nothing to guess, Redwing has an
-- item master.
ALTER TABLE public.medications
    ADD COLUMN IF NOT EXISTS redwing_item_code text;

-- Everything in the catalog is inventory by default - drugs, implants and the
-- three tag products alike, because a box of 50 tags behaves exactly like a
-- 50-dose vaccine and costs real money. This is the switch for anything not
-- worth counting.
--
-- It cannot be retrofitted: once counts exist, changing what is in scope
-- changes what past counts MEANT. So it ships from day one even though it is
-- expected to stay true on nearly everything.
ALTER TABLE public.medications
    ADD COLUMN IF NOT EXISTS track_inventory boolean NOT NULL DEFAULT true;


-- ---------------------------------------------------------------------
-- 2. med_stock_locations - the ranch, and one row per buyer
-- ---------------------------------------------------------------------
-- The barn and the crew boxes are ONE pool. A bottle in a truck has not left
-- the ranch; it is the same inventory in a different hand, and who has it is
-- custody, tracked on the person and not on the stock. Buyer rows exist
-- because a buyer's pickup at the supplier is genuinely separate inventory
-- sitting on his place.
CREATE TABLE IF NOT EXISTS public.med_stock_locations (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text        NOT NULL UNIQUE,
    kind        text        NOT NULL CHECK (kind IN ('ranch','buyer')),

    -- Matches lots.source ('Thigpen', 'Jake Taylor') so a lot's processing
    -- draw knows whose account to pull from, without a schema change to lots.
    -- Null on the ranch row.
    source_key  text,

    is_active   boolean     NOT NULL DEFAULT true,

    -- A sandbox to rehearse the screens on. Test locations hold ordinary rows
    -- through ordinary code paths - the only kind of rehearsal worth doing -
    -- but they are labelled everywhere and med_purge_location() erases one
    -- outright, which it flatly refuses to do to a real location.
    is_test     boolean     NOT NULL DEFAULT false,

    -- GO-LIVE SWITCH. Until this is set, the app records NO doctoring usage
    -- against this location. That is what makes the migration safe to apply
    -- before anybody has decided to start: the tables exist, the screens
    -- work, and real treatments carry on without quietly accruing against an
    -- inventory nobody has counted yet. Set it to the day of the opening
    -- count and usage flows from there.
    usage_from  date,

    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.med_stock_locations (name, kind, notes)
SELECT 'Ranch', 'ranch',
       'Barn and crew boxes together - one pool. Custody is tracked per person, not per location.'
WHERE NOT EXISTS (SELECT 1 FROM public.med_stock_locations WHERE kind = 'ranch' AND NOT is_test);


-- ---------------------------------------------------------------------
-- 3. med_crew_members - a name, and maybe an account
-- ---------------------------------------------------------------------
-- Some hands are regulars who will get field-app logins; some come
-- occasionally and should never see field-app information at all. Both have
-- to be checked out to, with the office or the head crew leader entering on
-- their behalf. So custody points HERE and not at user_profiles - a login is
-- an optional attribute of a crew member, not the definition of one.
--
-- The link exists for the day a regular gets an account. It does NOT enable a
-- per-person shrink figure, and no future change will: two men work together,
-- draw out of ONE man's box, and the OTHER writes the treatment up. His
-- checkouts drain against the other man's records. Where that is the
-- habitual pairing it is a systematic bias, not noise, so it does not average
-- out over a longer window either. Crew logins fix who TYPED it, not whose
-- box it came out of. See med_checkout_log: custody, not accountability.
CREATE TABLE IF NOT EXISTS public.med_crew_members (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text        NOT NULL UNIQUE,
    user_id    uuid,        -- nullable on purpose; most hands never have one
    is_active  boolean     NOT NULL DEFAULT true,
    notes      text,
    created_at timestamptz NOT NULL DEFAULT now()
);


-- ---------------------------------------------------------------------
-- 4. med_purchases / med_purchase_lines
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.med_purchases (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_date   date        NOT NULL DEFAULT public.ranch_today(),
    vendor          text,
    invoice_number  text,
    location_id     uuid        NOT NULL REFERENCES public.med_stock_locations(id),

    -- What the paper says. The entry grid refuses to post until the lines
    -- plus freight add up to this, which is the whole reason it is stored.
    invoice_total   numeric(12,2),

    -- Set when this purchase came in through the shared ordering spine, so a
    -- med delivery can be costed at the ORDERED price like a feed load.
    order_line_id   uuid,
    notes           text,

    -- July-June, named for the ENDING year. Generated rather than triggered
    -- so it cannot drift from the date it describes.
    fiscal_year     integer GENERATED ALWAYS AS (
        EXTRACT(YEAR FROM purchase_date)::int
        + CASE WHEN EXTRACT(MONTH FROM purchase_date) >= 7 THEN 1 ELSE 0 END
    ) STORED,

    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid
);

CREATE INDEX IF NOT EXISTS med_purchases_date_idx     ON public.med_purchases(purchase_date);
CREATE INDEX IF NOT EXISTS med_purchases_location_idx ON public.med_purchases(location_id);
CREATE INDEX IF NOT EXISTS med_purchases_order_line_idx
    ON public.med_purchases(order_line_id) WHERE order_line_id IS NOT NULL;

-- The spine join, added separately rather than inline on the column so a
-- re-run on a database that already has the table still gets it. ON DELETE
-- SET NULL, not CASCADE: deleting an order line must never take a received
-- purchase and its FIFO layers with it. The purchase happened; losing the
-- reminder it came from is the acceptable half.
DO $spine_fk$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.med_purchases'::regclass
          AND conname  = 'med_purchases_order_line_fk'
    ) THEN
        ALTER TABLE public.med_purchases
            ADD CONSTRAINT med_purchases_order_line_fk
            FOREIGN KEY (order_line_id)
            REFERENCES public.supply_order_lines(id) ON DELETE SET NULL;
        RAISE NOTICE 'med_purchases.order_line_id now references supply_order_lines';
    END IF;
END
$spine_fk$;

CREATE TABLE IF NOT EXISTS public.med_purchase_lines (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- NULL for a layer counted in at go-live or found by a later count.
    purchase_id     uuid        REFERENCES public.med_purchases(id) ON DELETE CASCADE,

    medication_id   uuid        NOT NULL REFERENCES public.medications(id),
    location_id     uuid        NOT NULL REFERENCES public.med_stock_locations(id),

    -- How it was bought, and how big the container was AT THE TIME.
    -- bottle_size is snapshotted, never read back from medications: a layer
    -- bought at 500 mL must stay 500 mL after the catalog says 1000.
    qty_bottles     numeric(12,4) NOT NULL CHECK (qty_bottles > 0),
    bottle_size     numeric(12,4) NOT NULL CHECK (bottle_size > 0),
    unit            text          NOT NULL DEFAULT 'mL',

    -- The unit of account is the base unit, not the bottle. A 500 mL bottle
    -- against a 6 cc dose is not a whole number of anything.
    qty_units       numeric(14,4) GENERATED ALWAYS AS (qty_bottles * bottle_size) STORED,

    -- Landed cost per base unit: freight and handling on the invoice are
    -- allocated across lines by value before this is written.
    unit_cost       numeric(14,6) NOT NULL CHECK (unit_cost >= 0),

    -- What is left of this layer. Decremented by med_consume, restored
    -- exactly by med_reverse_txn.
    qty_remaining   numeric(14,4) NOT NULL CHECK (qty_remaining >= 0),

    received_date   date        NOT NULL DEFAULT public.ranch_today(),
    sort_order      integer     NOT NULL DEFAULT 0,

    -- Optional. FIFO needs neither; they are typed when somebody cares.
    mfr_lot_number  text,
    expires_on      date,

    -- How this layer came to exist, for the activity trail.
    origin          text        NOT NULL DEFAULT 'purchase'
                                CHECK (origin IN ('purchase','opening','adjustment')),

    -- Set on the two count-born origins so the ledger row the trigger writes
    -- can point back at the count that found the stock.
    count_id        uuid,

    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,

    CONSTRAINT med_purchase_lines_remaining_le_qty
        CHECK (qty_remaining <= qty_bottles * bottle_size)
);

-- The FIFO scan: oldest open layer for this med at this location.
CREATE INDEX IF NOT EXISTS med_purchase_lines_fifo_idx
    ON public.med_purchase_lines(medication_id, location_id, received_date, sort_order)
    WHERE qty_remaining > 0;

CREATE INDEX IF NOT EXISTS med_purchase_lines_purchase_idx ON public.med_purchase_lines(purchase_id);
CREATE INDEX IF NOT EXISTS med_purchase_lines_expiry_idx   ON public.med_purchase_lines(expires_on)
    WHERE expires_on IS NOT NULL AND qty_remaining > 0;


-- ---------------------------------------------------------------------
-- 5. med_txns / med_txn_layers - every movement, and what it took
-- ---------------------------------------------------------------------
-- Five types, not ten. Treatment and processing are both `usage`, told apart
-- by ref_kind. Waste, expiry, a count variance and a plain correction are all
-- `adjustment`, told apart by reason. One code path, four labels, instead of
-- four near-identical types each needing its own handling. A return is a
-- negative checkout.
CREATE TABLE IF NOT EXISTS public.med_txns (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    txn_date        date        NOT NULL DEFAULT public.ranch_today(),
    txn_type        text        NOT NULL
                                CHECK (txn_type IN ('opening','purchase','checkout','usage','adjustment')),
    medication_id   uuid        NOT NULL REFERENCES public.medications(id),
    location_id     uuid        NOT NULL REFERENCES public.med_stock_locations(id),

    -- Always positive except a checkout return. Direction says what it did.
    qty_units       numeric(14,4) NOT NULL,

    -- Signed so the roll-forward sums without a CASE on every row.
    -- +1 adds to inventory, -1 takes from it, 0 is custody only.
    direction       smallint    NOT NULL DEFAULT -1 CHECK (direction IN (-1,0,1)),

    -- Custody. A checkout does not move stock - the bottle is still ranch
    -- inventory, just in somebody's hand - so this is the only thing a
    -- checkout row records. Points at a crew member rather than a user
    -- account, because most of the men who carry bottles do not have one.
    crew_member_id  uuid REFERENCES public.med_crew_members(id),

    -- 'count' | 'waste' | 'expired' | 'correction' | 'opening' on adjustments.
    reason          text,

    -- 'doctoring_event' | 'delivery_receipt' | 'med_count' | 'med_purchase_line'.
    ref_kind        text,
    ref_id          uuid,

    -- Usage the ledger had no stock behind. Priced at the last cost known and
    -- flagged on the on-hand screen; med_settle_uncovered clears it.
    shortfall_units numeric(14,4) NOT NULL DEFAULT 0,

    -- TRUE when that shortfall could not be priced AT ALL and was booked at
    -- zero, because the medication had no layer and no catalog price. A zero
    -- that looks like a real number is worse than an obvious gap, so it is
    -- marked rather than left to be believed.
    cost_provisional boolean    NOT NULL DEFAULT false,

    -- Frozen FIFO cost of this movement.
    total_cost      numeric(14,4),
    notes           text,

    fiscal_year     integer GENERATED ALWAYS AS (
        EXTRACT(YEAR FROM txn_date)::int
        + CASE WHEN EXTRACT(MONTH FROM txn_date) >= 7 THEN 1 ELSE 0 END
    ) STORED,

    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid
);

CREATE INDEX IF NOT EXISTS med_txns_date_idx ON public.med_txns(txn_date);
CREATE INDEX IF NOT EXISTS med_txns_med_idx  ON public.med_txns(medication_id, location_id, txn_date);
CREATE INDEX IF NOT EXISTS med_txns_ref_idx  ON public.med_txns(ref_kind, ref_id);
CREATE INDEX IF NOT EXISTS med_txns_crew_idx ON public.med_txns(crew_member_id) WHERE crew_member_id IS NOT NULL;

-- The allocation rows. This is where FIFO cost freezes, and it is what makes
-- a reversal exact: put back precisely what was taken, to the layers it was
-- taken from. A reversal that guesses double-counts - the delete_death_event
-- lesson.
CREATE TABLE IF NOT EXISTS public.med_txn_layers (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    txn_id            uuid          NOT NULL REFERENCES public.med_txns(id) ON DELETE CASCADE,

    -- NULL on a shortfall row: nothing was taken, so nothing goes back.
    purchase_line_id  uuid          REFERENCES public.med_purchase_lines(id),

    qty_units         numeric(14,4) NOT NULL,
    unit_cost         numeric(14,6) NOT NULL,
    extended_cost     numeric(14,4) GENERATED ALWAYS AS (qty_units * unit_cost) STORED,
    created_at        timestamptz   NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS med_txn_layers_txn_idx  ON public.med_txn_layers(txn_id);
CREATE INDEX IF NOT EXISTS med_txn_layers_line_idx ON public.med_txn_layers(purchase_line_id);


-- ---------------------------------------------------------------------
-- 6. med_counts / med_count_lines - the physical count
-- ---------------------------------------------------------------------
-- The only thing in this design that produces a shrink number.
CREATE TABLE IF NOT EXISTS public.med_counts (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    count_date  date        NOT NULL DEFAULT public.ranch_today(),
    location_id uuid        NOT NULL REFERENCES public.med_stock_locations(id),
    status      text        NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted')),

    -- The go-live count. Same mechanism as any other: every line is a
    -- positive variance against an empty ledger, so it creates layers.
    is_opening  boolean     NOT NULL DEFAULT false,

    counted_by  text,

    -- TRUE when the crew did not turn a number in and their last reported
    -- figure was carried forward. The month still closes and no fake shrink
    -- is booked out of stock sitting in a truck - but a carried figure looks
    -- exactly like a real one on a report, so it is marked.
    crew_estimated boolean  NOT NULL DEFAULT false,

    -- The date of the last count here where the crew really reported. When a
    -- real count follows estimated months its variance covers the whole span
    -- since this date - the period lock forbids reopening the closed months
    -- to spread it back - so the span is stored and the report says so,
    -- rather than one month appearing to have lost a case.
    crew_counted_since date,

    notes       text,
    posted_at   timestamptz,

    fiscal_year integer GENERATED ALWAYS AS (
        EXTRACT(YEAR FROM count_date)::int
        + CASE WHEN EXTRACT(MONTH FROM count_date) >= 7 THEN 1 ELSE 0 END
    ) STORED,

    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid
);

CREATE INDEX IF NOT EXISTS med_counts_date_idx ON public.med_counts(count_date);

CREATE TABLE IF NOT EXISTS public.med_count_lines (
    id             uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    count_id       uuid NOT NULL REFERENCES public.med_counts(id) ON DELETE CASCADE,
    medication_id  uuid NOT NULL REFERENCES public.medications(id),

    -- Four boxes, because that is how counting actually goes: the barn and
    -- the trucks are counted by different people, possibly on different days,
    -- and full bottles and the open one are separate questions.
    --
    -- Still ONE pool and no transfers - this is only how the count is
    -- GATHERED. Splitting it says whether shrink is sitting in the barn or in
    -- the trucks, which is a stock problem versus a handling problem.
    --
    -- The open columns are a FRACTION OF A BOTTLE, not units: the crew writes
    -- 1/2, not 250. That is the precision a man in a truck can honestly give,
    -- and the app does the multiplication rather than making him do it on a
    -- clipboard - which is where the error gets made.
    barn_full      numeric(12,4),
    barn_open      numeric(6,4) CHECK (barn_open IS NULL OR (barn_open >= 0 AND barn_open < 1)),
    crew_full      numeric(12,4),
    crew_open      numeric(6,4) CHECK (crew_open IS NULL OR (crew_open >= 0 AND crew_open < 1)),

    -- TRUE when the crew half of this line was carried forward rather than
    -- reported. Per line, because the crew may report some meds and not others.
    crew_carried   boolean NOT NULL DEFAULT false,

    -- Snapshotted so a later catalog change cannot rewrite what was counted.
    bottle_size    numeric(12,4),

    -- NULL means NOT COUNTED, which is not the same as zero. A blank line
    -- must never post an adjustment writing the stock to nothing.
    counted_units  numeric(14,4),

    -- Used when a positive variance has to create a layer and there is no
    -- prior cost to inherit - the opening count, priced at Redwing's
    -- carrying value.
    unit_cost      numeric(14,6),

    -- Written at post time, so the sheet keeps saying what it found.
    expected_units numeric(14,4),
    variance_units numeric(14,4),
    variance_value numeric(14,4),

    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT med_count_lines_unique UNIQUE (count_id, medication_id)
);

CREATE INDEX IF NOT EXISTS med_count_lines_count_idx ON public.med_count_lines(count_id);

-- Count-born layers point back at their count. SET NULL rather than CASCADE:
-- deleting a count must not delete the stock it found.
DO $fk$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'med_purchase_lines_count_id_fkey'
           AND conrelid = 'public.med_purchase_lines'::regclass
    ) THEN
        ALTER TABLE public.med_purchase_lines
            ADD CONSTRAINT med_purchase_lines_count_id_fkey
            FOREIGN KEY (count_id) REFERENCES public.med_counts(id) ON DELETE SET NULL;
    END IF;
END
$fk$;


-- ---------------------------------------------------------------------
-- 7. A layer written is a ledger row written
-- ---------------------------------------------------------------------
-- Stock arriving is the one movement the app inserts directly rather than
-- calling an RPC for - a purchase is data entry. So the ledger row is written
-- by trigger instead of being the app's job to remember. The layers and the
-- ledger cannot diverge if only one of them is hand-written.
CREATE OR REPLACE FUNCTION public.med_layer_ledger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_type   text;
    v_reason text;
    v_kind   text;
    v_ref    uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        -- Unwinding an entry mistake: the layer goes, so its ledger row goes.
        -- Anything that CONSUMED this layer is blocked by the med_txn_layers
        -- foreign key long before we get here, which is the correct answer:
        -- an invoice whose stock has been used cannot simply be deleted.
        DELETE FROM public.med_txns
         WHERE ref_kind = 'med_purchase_line' AND ref_id = OLD.id;
        RETURN OLD;
    END IF;

    IF NEW.origin = 'purchase' THEN
        v_type := 'purchase'; v_reason := NULL;
        v_kind := 'med_purchase'; v_ref := NEW.purchase_id;
    ELSIF NEW.origin = 'opening' THEN
        v_type := 'opening'; v_reason := 'opening';
        v_kind := 'med_count'; v_ref := NEW.count_id;
    ELSE
        v_type := 'adjustment'; v_reason := 'count';
        v_kind := 'med_count'; v_ref := NEW.count_id;
    END IF;

    INSERT INTO public.med_txns (
        txn_date, txn_type, medication_id, location_id, qty_units,
        direction, reason, ref_kind, ref_id, total_cost, created_by, notes
    ) VALUES (
        NEW.received_date, v_type, NEW.medication_id, NEW.location_id, NEW.qty_units,
        1, v_reason, 'med_purchase_line', NEW.id,
        round(NEW.qty_units * NEW.unit_cost, 4), NEW.created_by,
        -- The real reference is kept in the notes so the activity trail can
        -- still say which invoice or count it came from; ref_id has to point
        -- at the layer for the DELETE branch above to find it.
        CASE WHEN v_ref IS NULL THEN NULL ELSE v_kind || ':' || v_ref::text END
    );

    RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS med_purchase_lines_ledger_ins ON public.med_purchase_lines;
CREATE TRIGGER med_purchase_lines_ledger_ins
    AFTER INSERT ON public.med_purchase_lines
    FOR EACH ROW EXECUTE FUNCTION public.med_layer_ledger();

DROP TRIGGER IF EXISTS med_purchase_lines_ledger_del ON public.med_purchase_lines;
CREATE TRIGGER med_purchase_lines_ledger_del
    BEFORE DELETE ON public.med_purchase_lines
    FOR EACH ROW EXECUTE FUNCTION public.med_layer_ledger();


-- ---------------------------------------------------------------------
-- 8. The period lock
-- ---------------------------------------------------------------------
-- A posted count is a statement about what was on the shelf on a date. Let
-- anything be dated into the period behind it and that statement quietly
-- stops being true: a vet invoice entered in November dated October rewrites
-- what October's ending balance was, while October's shrink is already booked.
--
-- So once a count posts, that location is closed on and before its date.
-- Later paperwork gets dated after, or an owner un-posts the count, fixes it,
-- and posts again.
--
-- This is NOT the fix for a late invoice that should have covered earlier
-- usage - med_settle_uncovered handles that inside the open period, without
-- backdating anything.
CREATE OR REPLACE FUNCTION public.med_locked_through(p_location_id uuid)
RETURNS date
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
    SELECT MAX(count_date)
      FROM public.med_counts
     WHERE location_id = p_location_id AND status = 'posted';
$fn$;

CREATE OR REPLACE FUNCTION public.med_guard_locked_period()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_locked date;
    v_date   date;
    v_loc    uuid;
BEGIN
    IF TG_TABLE_NAME = 'med_txns' THEN
        v_date := NEW.txn_date;      v_loc := NEW.location_id;
    ELSE
        v_date := NEW.received_date; v_loc := NEW.location_id;
    END IF;

    v_locked := public.med_locked_through(v_loc);

    IF v_locked IS NOT NULL AND v_date <= v_locked THEN
        RAISE EXCEPTION
            'That period is closed. % is dated % and this location was counted through %. Date it after %, or have an owner un-post the count.',
            TG_TABLE_NAME, v_date, v_locked, v_locked
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END
$fn$;

-- A count's OWN adjustments are dated on the count date and post while the
-- count is still a draft, so they never meet a lock of their own making.
DROP TRIGGER IF EXISTS med_txns_period_lock ON public.med_txns;
CREATE TRIGGER med_txns_period_lock
    BEFORE INSERT ON public.med_txns
    FOR EACH ROW EXECUTE FUNCTION public.med_guard_locked_period();

DROP TRIGGER IF EXISTS med_purchase_lines_period_lock ON public.med_purchase_lines;
CREATE TRIGGER med_purchase_lines_period_lock
    BEFORE INSERT ON public.med_purchase_lines
    FOR EACH ROW EXECUTE FUNCTION public.med_guard_locked_period();


-- ---------------------------------------------------------------------
-- 9. med_consume - take units out, oldest layer first
-- ---------------------------------------------------------------------
-- INVOKER, like every other head-math RPC here. It must run as the person
-- calling it so RLS still applies.
CREATE OR REPLACE FUNCTION public.med_consume(
    p_medication_id  uuid,
    p_location_id    uuid,
    p_qty_units      numeric,
    p_txn_type       text    DEFAULT 'usage',
    p_reason         text    DEFAULT NULL,
    p_ref_kind       text    DEFAULT NULL,
    p_ref_id         uuid    DEFAULT NULL,
    p_txn_date       date    DEFAULT NULL,
    p_notes          text    DEFAULT NULL,
    p_crew_member_id uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_txn_id     uuid;
    v_need       numeric := p_qty_units;
    v_take       numeric;
    v_total      numeric := 0;
    v_last_cost  numeric;
    v_prov       boolean := false;
    v_date       date;
    v_locked     date;
    v_note       text := p_notes;
    row_rec      record;
BEGIN
    IF p_qty_units IS NULL OR p_qty_units <= 0 THEN
        RAISE EXCEPTION 'med_consume: qty_units must be positive (got %)', p_qty_units;
    END IF;
    IF p_txn_type NOT IN ('usage','adjustment') THEN
        RAISE EXCEPTION 'med_consume: txn_type must be usage or adjustment (got %)', p_txn_type;
    END IF;

    v_date   := COALESCE(p_txn_date, public.ranch_today());
    v_locked := public.med_locked_through(p_location_id);

    -- A dose given in a month that has since been counted and closed.
    --
    -- It happens: a field entry syncs a week late and is approved after the
    -- count posted. The period lock would reject it, and because the usage
    -- hook is fail-soft that rejection would SILENTLY LOSE the dose - a
    -- treatment that really happened, gone, to satisfy a bookkeeping rule.
    -- Every other rule here bends before that one does.
    --
    -- So usage posts to the first OPEN day instead, carrying its true date in
    -- the note. The closed month keeps the shrink it booked; the open month
    -- comes up long by the same amount and nets it back off. Across the pair
    -- the units and the dollars are right, and nothing is lost. Purchases get
    -- no such relief - an invoice can simply be dated correctly.
    IF v_locked IS NOT NULL AND v_date <= v_locked THEN
        v_note := COALESCE(v_note || ' | ', '')
                  || 'Given ' || v_date || ', posted ' || (v_locked + 1)
                  || ' - ' || v_date || ' was closed by a posted count.';
        v_date := v_locked + 1;
    END IF;

    INSERT INTO public.med_txns (
        txn_date, txn_type, medication_id, location_id, qty_units, direction,
        crew_member_id, reason, ref_kind, ref_id, notes, created_by
    ) VALUES (
        v_date, p_txn_type, p_medication_id, p_location_id, p_qty_units, -1,
        p_crew_member_id, p_reason, p_ref_kind, p_ref_id, v_note, auth.uid()
    )
    RETURNING id INTO v_txn_id;

    -- Oldest open layer first. FOR UPDATE so two people saving doctoring at
    -- the same moment cannot both draw the last of a bottle.
    FOR row_rec IN
        SELECT id, qty_remaining, unit_cost
          FROM public.med_purchase_lines
         WHERE medication_id = p_medication_id
           AND location_id   = p_location_id
           AND qty_remaining > 0
         ORDER BY received_date, sort_order, created_at, id
         FOR UPDATE
    LOOP
        EXIT WHEN v_need <= 0;

        v_take := LEAST(v_need, row_rec.qty_remaining);

        UPDATE public.med_purchase_lines
           SET qty_remaining = qty_remaining - v_take
         WHERE id = row_rec.id;

        INSERT INTO public.med_txn_layers (txn_id, purchase_line_id, qty_units, unit_cost)
        VALUES (v_txn_id, row_rec.id, v_take, row_rec.unit_cost);

        v_total := v_total + (v_take * row_rec.unit_cost);
        v_need  := v_need - v_take;
    END LOOP;

    -- Short. The record still saves - this is animal health data and a
    -- bookkeeping gap is not a reason to lose it - so the remainder is priced
    -- at the last cost we know and flagged for settling to clear.
    IF v_need > 0 THEN
        SELECT unit_cost INTO v_last_cost
          FROM public.med_purchase_lines
         WHERE medication_id = p_medication_id
         ORDER BY (location_id = p_location_id) DESC, received_date DESC, created_at DESC
         LIMIT 1;

        IF v_last_cost IS NULL THEN
            SELECT cost_per_unit INTO v_last_cost FROM public.medications WHERE id = p_medication_id;
        END IF;

        -- No layer and no catalog price: a medication picked up and used
        -- before anybody entered what it cost. It still books - the treatment
        -- happened - but at zero, and zero is a number people believe. Mark it
        -- so the on-hand screen can say "unpriced" rather than showing $0.00
        -- as though that were the answer.
        v_prov := (v_last_cost IS NULL);
        v_last_cost := COALESCE(v_last_cost, 0);

        INSERT INTO public.med_txn_layers (txn_id, purchase_line_id, qty_units, unit_cost)
        VALUES (v_txn_id, NULL, v_need, v_last_cost);

        v_total := v_total + (v_need * v_last_cost);

        UPDATE public.med_txns
           SET shortfall_units = v_need, cost_provisional = v_prov
         WHERE id = v_txn_id;
    END IF;

    UPDATE public.med_txns SET total_cost = round(v_total, 4) WHERE id = v_txn_id;

    RETURN jsonb_build_object(
        'txn_id',          v_txn_id,
        'total_cost',      round(v_total, 4),
        'shortfall_units', GREATEST(v_need, 0),
        'posted_date',     v_date
    );
END
$fn$;

REVOKE ALL ON FUNCTION public.med_consume(uuid,uuid,numeric,text,text,text,uuid,date,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.med_consume(uuid,uuid,numeric,text,text,text,uuid,date,text,uuid) TO authenticated;


-- ---------------------------------------------------------------------
-- 10. med_reverse_txn - put back exactly what was taken
-- ---------------------------------------------------------------------
-- Restores to the layers named in med_txn_layers and nowhere else. A reversal
-- that recomputes which layers "would have" been used gets it wrong the
-- moment a later purchase arrives, and gets it wrong silently.
CREATE OR REPLACE FUNCTION public.med_reverse_txn(p_txn_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_dir      smallint;
    v_type     text;
    v_restored numeric := 0;
    row_rec    record;
BEGIN
    SELECT direction, txn_type INTO v_dir, v_type
      FROM public.med_txns WHERE id = p_txn_id;

    IF v_dir IS NULL THEN
        RAISE EXCEPTION 'med_reverse_txn: no such transaction %', p_txn_id;
    END IF;

    -- Stock that ARRIVED is reversed by deleting its layer, which the trigger
    -- then follows. Reversing it here would hand units back to a layer that
    -- should cease to exist.
    IF v_dir = 1 THEN
        RAISE EXCEPTION 'med_reverse_txn: % is an incoming transaction. Delete the purchase line instead.', v_type;
    END IF;

    FOR row_rec IN
        SELECT purchase_line_id, qty_units
          FROM public.med_txn_layers
         WHERE txn_id = p_txn_id AND purchase_line_id IS NOT NULL
    LOOP
        UPDATE public.med_purchase_lines
           SET qty_remaining = qty_remaining + row_rec.qty_units
         WHERE id = row_rec.purchase_line_id;
        v_restored := v_restored + row_rec.qty_units;
    END LOOP;

    -- Layer rows cascade with the transaction.
    DELETE FROM public.med_txns WHERE id = p_txn_id;

    RETURN jsonb_build_object('txn_id', p_txn_id, 'restored_units', v_restored);
END
$fn$;

REVOKE ALL ON FUNCTION public.med_reverse_txn(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.med_reverse_txn(uuid) TO authenticated;


-- ---------------------------------------------------------------------
-- 11. med_settle_uncovered - the invoice that shows up late
-- ---------------------------------------------------------------------
-- Two things go wrong when a medication is picked up and used before the app
-- knows about it, and the second is the dangerous one.
--
-- 1. PRICING. No layer and no catalog price means the dose booked at zero.
--    Once a real cost exists, the still-uncovered usage is re-priced to it.
--
-- 2. SEQUENCING, which is worse. Say 3 doses got used on the 12th and the
--    invoice for that bottle is not entered until the 20th, dated the 8th.
--    med_consume already ran and found nothing, so it recorded a shortfall.
--    Now the layer lands FULL. On-hand overstates, and the next count comes
--    up short - and books it as SHRINK. It was not shrink. It was a treatment
--    the ledger had not heard about yet. Left alone, every late invoice
--    quietly inflates the one number this whole module exists to produce.
--
-- So: walk the uncovered usage oldest first and let it draw on any layer that
-- was actually on the shelf when the treatment happened - received ON OR
-- BEFORE the usage date. A bottle bought afterwards cannot have been in the
-- syringe, and is left alone.
--
-- This changes no quantity that is really on the shelf: the shortfall rows
-- point at no layer, so converting them into real draws only spends what was
-- already spent.
CREATE OR REPLACE FUNCTION public.med_settle_uncovered(
    p_medication_id uuid DEFAULT NULL,
    p_location_id   uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_need      numeric;
    v_take      numeric;
    v_covered   numeric;
    v_cost      numeric;
    v_txns      integer := 0;
    v_units     numeric := 0;
    v_repriced  integer := 0;
    txn_rec     record;
    lay_rec     record;
BEGIN
    FOR txn_rec IN
        SELECT t.id, t.medication_id, t.location_id, t.txn_date,
               t.shortfall_units, t.cost_provisional
          FROM public.med_txns t
         WHERE t.shortfall_units > 0
           AND t.direction = -1
           AND (p_medication_id IS NULL OR t.medication_id = p_medication_id)
           AND (p_location_id   IS NULL OR t.location_id   = p_location_id)
         ORDER BY t.txn_date, t.created_at
         FOR UPDATE
    LOOP
        v_need    := txn_rec.shortfall_units;
        v_covered := 0;

        FOR lay_rec IN
            SELECT id, qty_remaining, unit_cost
              FROM public.med_purchase_lines
             WHERE medication_id = txn_rec.medication_id
               AND location_id   = txn_rec.location_id
               AND qty_remaining > 0
               -- A bottle that arrived after the treatment cannot have been in
               -- the syringe. This is the whole guard.
               AND received_date <= txn_rec.txn_date
             ORDER BY received_date, sort_order, created_at, id
             FOR UPDATE
        LOOP
            EXIT WHEN v_need <= 0;

            v_take := LEAST(v_need, lay_rec.qty_remaining);

            UPDATE public.med_purchase_lines
               SET qty_remaining = qty_remaining - v_take
             WHERE id = lay_rec.id;

            INSERT INTO public.med_txn_layers (txn_id, purchase_line_id, qty_units, unit_cost)
            VALUES (txn_rec.id, lay_rec.id, v_take, lay_rec.unit_cost);

            v_need    := v_need - v_take;
            v_covered := v_covered + v_take;
        END LOOP;

        IF v_covered > 0 THEN
            -- Shrink the placeholder row by exactly what is now covered, and
            -- drop it if the whole shortfall was made good.
            IF v_need > 0 THEN
                UPDATE public.med_txn_layers
                   SET qty_units = v_need
                 WHERE txn_id = txn_rec.id AND purchase_line_id IS NULL;
            ELSE
                DELETE FROM public.med_txn_layers
                 WHERE txn_id = txn_rec.id AND purchase_line_id IS NULL;
            END IF;
            v_txns  := v_txns + 1;
            v_units := v_units + v_covered;
        END IF;

        -- Whatever is still uncovered gets the best price we now know, so a
        -- zero booked in ignorance does not stay a zero forever.
        IF v_need > 0 AND txn_rec.cost_provisional THEN
            SELECT unit_cost INTO v_cost
              FROM public.med_purchase_lines
             WHERE medication_id = txn_rec.medication_id
             ORDER BY (location_id = txn_rec.location_id) DESC, received_date DESC, created_at DESC
             LIMIT 1;
            IF v_cost IS NULL THEN
                SELECT cost_per_unit INTO v_cost
                  FROM public.medications WHERE id = txn_rec.medication_id;
            END IF;

            IF v_cost IS NOT NULL THEN
                UPDATE public.med_txn_layers
                   SET unit_cost = v_cost
                 WHERE txn_id = txn_rec.id AND purchase_line_id IS NULL;
                v_repriced := v_repriced + 1;
            END IF;
        END IF;

        UPDATE public.med_txns t
           SET shortfall_units  = v_need,
               cost_provisional = CASE WHEN v_need = 0 THEN false
                                       ELSE t.cost_provisional AND v_cost IS NULL END,
               total_cost = COALESCE((SELECT round(SUM(extended_cost), 4)
                                        FROM public.med_txn_layers WHERE txn_id = t.id), 0)
         WHERE t.id = txn_rec.id;

        v_cost := NULL;
    END LOOP;

    RETURN jsonb_build_object(
        'transactions_settled',  v_txns,
        'units_covered',         v_units,
        'transactions_repriced', v_repriced
    );
END
$fn$;

REVOKE ALL ON FUNCTION public.med_settle_uncovered(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.med_settle_uncovered(uuid,uuid) TO authenticated;


-- ---------------------------------------------------------------------
-- 12. med_post_count - the count becomes shrink
-- ---------------------------------------------------------------------
-- All or nothing: one function is one transaction, so a count either posts
-- whole or does not post at all.
CREATE OR REPLACE FUNCTION public.med_post_count(p_count_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_status    text;
    v_location  uuid;
    v_date      date;
    v_opening   boolean;
    v_kind      text;
    v_pending   integer := 0;
    v_first     date;
    v_last      date;
    v_expected  numeric;
    v_variance  numeric;
    v_cost      numeric;
    v_value     numeric;
    v_consumed  jsonb;
    v_lines     integer := 0;
    v_short     integer := 0;
    v_over      integer := 0;
    v_shrink    numeric := 0;
    v_shrink_value numeric := 0;
    row_rec     record;
BEGIN
    SELECT status, location_id, count_date, is_opening
      INTO v_status, v_location, v_date, v_opening
      FROM public.med_counts WHERE id = p_count_id FOR UPDATE;

    IF v_status IS NULL THEN
        RAISE EXCEPTION 'med_post_count: no such count %', p_count_id;
    END IF;
    IF v_status <> 'draft' THEN
        RAISE EXCEPTION 'med_post_count: count % is already %; a posted count cannot be posted again.', p_count_id, v_status;
    END IF;

    SELECT kind INTO v_kind FROM public.med_stock_locations WHERE id = v_location;

    -- THE APPROVALS GATE.
    --
    -- Count the shelf on the 31st with the 28th's treatments still sitting in
    -- Approvals, and the ledger has not heard about those doses yet - so the
    -- count comes up short and books them as SHRINK. Then the approval posts
    -- them again as usage. Two hundred units recorded where a hundred moved,
    -- and it does NOT wash out next month: the count is locked and the shrink
    -- is already allocated.
    --
    -- So the count waits for the queue. Enter it on the 31st as a draft, clear
    -- Approvals on the 1st, post it dated the 31st.
    --
    -- Ranch only: a buyer's shelf has nothing to do with our doctoring queue.
    IF v_kind = 'ranch' THEN
        SELECT count(*),
               MIN((event_datetime AT TIME ZONE 'America/Chicago')::date),
               MAX((event_datetime AT TIME ZONE 'America/Chicago')::date)
          INTO v_pending, v_first, v_last
          FROM public.pending_field_entries
         WHERE status = 'pending'
           AND entry_type = 'doctoring'
           AND (event_datetime AT TIME ZONE 'America/Chicago')::date <= v_date;

        IF v_pending > 0 THEN
            RAISE EXCEPTION
                'Cannot post: % doctoring entr% dated % to % still awaiting approval. Those doses are not in the ledger yet, so this count would book them as shrink and the approvals would then post them again. Clear the Approvals queue, then post.',
                v_pending, CASE WHEN v_pending = 1 THEN 'y is' ELSE 'ies are' END, v_first, v_last
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- A NULL counted_units means NOT COUNTED. Skipping those here is the whole
    -- reason the column is nullable: a blank line must never post an
    -- adjustment writing the stock to nothing.
    FOR row_rec IN
        SELECT cl.id, cl.medication_id, cl.counted_units, cl.unit_cost, m.name AS med_name
          FROM public.med_count_lines cl
          JOIN public.medications m ON m.id = cl.medication_id
         WHERE cl.count_id = p_count_id
           AND cl.counted_units IS NOT NULL
         ORDER BY m.generic_category, m.name
    LOOP
        SELECT COALESCE(SUM(qty_remaining), 0) INTO v_expected
          FROM public.med_purchase_lines
         WHERE medication_id = row_rec.medication_id
           AND location_id   = v_location;

        v_variance := row_rec.counted_units - v_expected;
        v_lines := v_lines + 1;

        IF v_variance < 0 THEN
            -- Short: consume the difference. This is the shrink, and its VALUE
            -- has to come back out of med_consume rather than being recomputed
            -- here - the units came off real layers at real costs, and a fresh
            -- multiplication by "the" unit cost would quietly disagree with
            -- the ledger whenever a short draw spanned two layers bought at
            -- different prices.
            v_consumed := public.med_consume(
                row_rec.medication_id, v_location, -v_variance,
                'adjustment', 'count', 'med_count', p_count_id, v_date,
                'Count variance', NULL
            );
            v_value        := -1 * COALESCE((v_consumed->>'total_cost')::numeric, 0);
            v_short        := v_short + 1;
            v_shrink       := v_shrink + (-v_variance);
            v_shrink_value := v_shrink_value + COALESCE((v_consumed->>'total_cost')::numeric, 0);

        ELSIF v_variance > 0 THEN
            -- Long: the stock is there, so a layer has to exist for it. Cost
            -- is the line's own figure (the opening count types Redwing's
            -- carrying value), else the last cost we know, else the catalog.
            v_cost := row_rec.unit_cost;
            IF v_cost IS NULL THEN
                SELECT unit_cost INTO v_cost
                  FROM public.med_purchase_lines
                 WHERE medication_id = row_rec.medication_id
                 ORDER BY (location_id = v_location) DESC, received_date DESC, created_at DESC
                 LIMIT 1;
            END IF;
            IF v_cost IS NULL THEN
                SELECT cost_per_unit INTO v_cost FROM public.medications WHERE id = row_rec.medication_id;
            END IF;

            -- Refusing here rather than defaulting to zero is deliberate. A
            -- layer with no cost prices every future draw off it at nothing,
            -- and SUM() over a NULL cost drops the line silently instead of
            -- erroring. Price the medication first.
            IF v_cost IS NULL THEN
                RAISE EXCEPTION
                    'med_post_count: % counted % over, but no unit cost is known for it. Enter a cost on the count line or price the medication first.',
                    row_rec.med_name, v_variance
                    USING ERRCODE = 'check_violation';
            END IF;

            -- bottle_size 1 and qty_bottles = the variance, deliberately.
            -- qty_units is GENERATED as qty_bottles * bottle_size, and
            -- dividing the variance by a real bottle size then storing the
            -- quotient at four decimal places does not multiply back: 250
            -- units of a 3,785 mL jug round-trips to 250.18, and that 0.18
            -- goes straight into the ledger row the trigger writes. Counting
            -- in whole units cannot be wrong. Bottle equivalents on screen
            -- divide by medications.bottle_size anyway.
            INSERT INTO public.med_purchase_lines (
                purchase_id, medication_id, location_id, qty_bottles, bottle_size,
                unit, unit_cost, qty_remaining, received_date, origin, count_id, created_by
            )
            SELECT NULL, row_rec.medication_id, v_location,
                   v_variance, 1,
                   COALESCE(m.bottle_size_unit, 'mL'), v_cost, v_variance, v_date,
                   CASE WHEN v_opening THEN 'opening' ELSE 'adjustment' END,
                   p_count_id, auth.uid()
              FROM public.medications m WHERE m.id = row_rec.medication_id;

            v_value := v_variance * v_cost;
            v_over  := v_over + 1;
        ELSE
            v_value := 0;
        END IF;

        UPDATE public.med_count_lines
           SET expected_units = v_expected,
               variance_units = v_variance,
               variance_value = round(COALESCE(v_value, 0), 4)
         WHERE id = row_rec.id;

        v_cost  := NULL;
        v_value := NULL;
    END LOOP;

    -- Record whether the crew really reported, and how far back this count's
    -- variance reaches. When a real crew count follows estimated months its
    -- variance covers the whole span since they last truly counted - the lock
    -- forbids reopening those months to spread it back - so the span is stored
    -- and the report says so, rather than one month appearing to have lost a
    -- case.
    UPDATE public.med_counts c
       SET status = 'posted',
           posted_at = now(),
           crew_estimated = EXISTS (
               SELECT 1 FROM public.med_count_lines cl
                WHERE cl.count_id = p_count_id AND cl.crew_carried
           ),
           crew_counted_since = (
               SELECT MAX(prev.count_date)
                 FROM public.med_counts prev
                WHERE prev.location_id = c.location_id
                  AND prev.status = 'posted'
                  AND prev.id <> c.id
                  AND NOT prev.crew_estimated
           )
     WHERE c.id = p_count_id;

    RETURN jsonb_build_object(
        'count_id',      p_count_id,
        'lines_counted', v_lines,
        'lines_short',   v_short,
        'lines_over',    v_over,
        'shrink_units',  v_shrink,
        'shrink_value',  round(v_shrink_value, 2)
    );
END
$fn$;

REVOKE ALL ON FUNCTION public.med_post_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.med_post_count(uuid) TO authenticated;


-- ---------------------------------------------------------------------
-- 13. med_unpost_count - the way back out
-- ---------------------------------------------------------------------
-- The period lock only works because there is a door. Without one, a count
-- posted with a typo would close the month permanently and the only remedy
-- would be an adjustment correcting an adjustment.
--
-- Un-posting reverses EXACTLY what the count did and nothing else:
--   - short lines: reverse the adjustment, restoring units to the layers they
--     were taken off, through the same machinery a deleted treatment uses;
--   - long lines: delete the layer the count created - but ONLY if nothing has
--     drawn on it since, because reversing a layer somebody has already used
--     would take stock out of a treatment that really happened.
--
-- Owner-only in practice: it is INVOKER, and DELETE here is owner-only.
CREATE OR REPLACE FUNCTION public.med_unpost_count(p_count_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_status   text;
    v_location uuid;
    v_date     date;
    v_reversed integer := 0;
    v_dropped  integer := 0;
    v_used     numeric;
    row_rec    record;
BEGIN
    SELECT status, location_id, count_date INTO v_status, v_location, v_date
      FROM public.med_counts WHERE id = p_count_id FOR UPDATE;

    IF v_status IS NULL THEN
        RAISE EXCEPTION 'med_unpost_count: no such count %', p_count_id;
    END IF;
    IF v_status <> 'posted' THEN
        RAISE EXCEPTION 'med_unpost_count: count % is %, not posted.', p_count_id, v_status;
    END IF;

    -- A later posted count here would be sitting on top of this one;
    -- unwinding underneath it would leave that later count's variance measured
    -- against a shelf that no longer exists.
    IF EXISTS (
        SELECT 1 FROM public.med_counts
         WHERE location_id = v_location AND status = 'posted'
           AND count_date > v_date AND id <> p_count_id
    ) THEN
        RAISE EXCEPTION
            'med_unpost_count: a later count has been posted at this location. Un-post that one first.'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Long lines: the layers this count created.
    FOR row_rec IN
        SELECT l.id, l.qty_bottles * l.bottle_size AS qty_units, l.qty_remaining, m.name AS med_name
          FROM public.med_purchase_lines l
          JOIN public.medications m ON m.id = l.medication_id
         WHERE l.count_id = p_count_id
    LOOP
        v_used := row_rec.qty_units - row_rec.qty_remaining;
        IF v_used > 0 THEN
            RAISE EXCEPTION
                'med_unpost_count: % units of the % this count found have already been used. Un-posting would take stock back out of treatments that really happened. Correct it with a new count instead.',
                v_used, row_rec.med_name
                USING ERRCODE = 'check_violation';
        END IF;
        -- The layer's own ledger row goes with it, via the delete trigger.
        DELETE FROM public.med_purchase_lines WHERE id = row_rec.id;
        v_dropped := v_dropped + 1;
    END LOOP;

    -- Short lines: reverse the adjustments, putting units back on the exact
    -- layers they came off.
    FOR row_rec IN
        SELECT id FROM public.med_txns
         WHERE ref_kind = 'med_count' AND ref_id = p_count_id AND direction = -1
    LOOP
        PERFORM public.med_reverse_txn(row_rec.id);
        v_reversed := v_reversed + 1;
    END LOOP;

    UPDATE public.med_counts
       SET status = 'draft', posted_at = NULL,
           crew_estimated = false, crew_counted_since = NULL
     WHERE id = p_count_id;

    -- The stored variance figures described a posting that no longer exists.
    UPDATE public.med_count_lines
       SET expected_units = NULL, variance_units = NULL, variance_value = NULL
     WHERE count_id = p_count_id;

    RETURN jsonb_build_object(
        'count_id',             p_count_id,
        'adjustments_reversed', v_reversed,
        'layers_removed',       v_dropped,
        'status',               'draft'
    );
END
$fn$;

REVOKE ALL ON FUNCTION public.med_unpost_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.med_unpost_count(uuid) TO authenticated;


-- ---------------------------------------------------------------------
-- 14. med_purge_location - erase a rehearsal
-- ---------------------------------------------------------------------
-- A dry run is only worth doing if the practice data can be removed afterwards
-- without a trace, and only worth trusting if it went through exactly the same
-- code as the real thing. So: rehearse in a location marked is_test, then
-- erase it here.
--
-- It REFUSES on a location that is not marked as a test. That check is the
-- whole point of the function; without it this is a delete statement pointed
-- at the inventory, and one wrong id erases the real books.
CREATE OR REPLACE FUNCTION public.med_purge_location(
    p_location_id   uuid,
    p_drop_location boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_is_test boolean;
    v_name    text;
    v_txns    integer;
    v_lines   integer;
    v_pur     integer;
    v_counts  integer;
BEGIN
    SELECT is_test, name INTO v_is_test, v_name
      FROM public.med_stock_locations WHERE id = p_location_id;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'med_purge_location: no such location %', p_location_id;
    END IF;
    IF NOT v_is_test THEN
        RAISE EXCEPTION
            'med_purge_location: "%" is not marked as a test location. Refusing to erase real inventory.',
            v_name USING ERRCODE = 'check_violation';
    END IF;

    -- Transactions first: med_txn_layers points at purchase lines with no
    -- cascade, so the lines cannot go until nothing references them.
    DELETE FROM public.med_txns WHERE location_id = p_location_id;
    GET DIAGNOSTICS v_txns = ROW_COUNT;

    DELETE FROM public.med_counts WHERE location_id = p_location_id;
    GET DIAGNOSTICS v_counts = ROW_COUNT;

    DELETE FROM public.med_purchase_lines WHERE location_id = p_location_id;
    GET DIAGNOSTICS v_lines = ROW_COUNT;

    DELETE FROM public.med_purchases WHERE location_id = p_location_id;
    GET DIAGNOSTICS v_pur = ROW_COUNT;

    IF p_drop_location THEN
        DELETE FROM public.med_stock_locations WHERE id = p_location_id;
    END IF;

    RETURN jsonb_build_object(
        'location',          v_name,
        'txns_deleted',      v_txns,
        'counts_deleted',    v_counts,
        'layers_deleted',    v_lines,
        'purchases_deleted', v_pur,
        'location_dropped',  p_drop_location
    );
END
$fn$;

REVOKE ALL ON FUNCTION public.med_purge_location(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.med_purge_location(uuid, boolean) TO authenticated;


-- ---------------------------------------------------------------------
-- 15. Views. Every one WITH (security_invoker = true) - no exceptions.
-- ---------------------------------------------------------------------
-- Rule 3: without it a view runs as its owner and bypasses RLS regardless of
-- base-table policies, and CREATE OR REPLACE VIEW CLEARS reloptions when WITH
-- is omitted - so the clause is repeated on every replace, not assumed.

-- med_on_hand -----------------------------------------------------------
-- Every in-scope medication against every active location, whether or not it
-- has stock: the count sheet has to be able to list something the ledger
-- thinks is zero, because that is precisely where a surprise is.
DROP VIEW IF EXISTS public.med_on_hand;
CREATE VIEW public.med_on_hand
WITH (security_invoker = true) AS
WITH shortfalls AS (
    SELECT medication_id, location_id,
           SUM(shortfall_units) AS uncovered_units,
           -- The subset that booked at zero because nothing knew the price.
           SUM(shortfall_units) FILTER (WHERE cost_provisional) AS unpriced_usage_units
      FROM public.med_txns
     WHERE shortfall_units > 0
     GROUP BY medication_id, location_id
)
SELECT
    loc.id                              AS location_id,
    loc.name                            AS location_name,
    loc.kind                            AS location_kind,
    loc.is_test                         AS location_is_test,
    loc.usage_from                      AS location_usage_from,
    m.id                                AS medication_id,
    m.name                              AS medication_name,
    m.generic_category,
    m.redwing_item_code,
    COALESCE(m.bottle_size_unit, 'mL')  AS unit,
    m.bottle_size,
    COALESCE(SUM(l.qty_remaining), 0)                         AS qty_units,
    CASE WHEN COALESCE(m.bottle_size, 0) > 0
         THEN round(COALESCE(SUM(l.qty_remaining), 0) / m.bottle_size, 3)
    END                                                       AS bottles_equiv,
    round(COALESCE(SUM(l.qty_remaining * l.unit_cost), 0), 2)  AS value_fifo,
    -- Weighted average of what is actually still on the shelf, which is not
    -- the same as the last price paid.
    CASE WHEN COALESCE(SUM(l.qty_remaining), 0) > 0
         THEN round(SUM(l.qty_remaining * l.unit_cost) / SUM(l.qty_remaining), 6)
    END                                                       AS avg_unit_cost,
    MIN(l.received_date)                                      AS oldest_layer_date,
    COUNT(l.id) FILTER (WHERE l.qty_remaining > 0)            AS open_layer_count,
    COUNT(l.id) FILTER (WHERE l.qty_remaining > 0 AND l.expires_on IS NOT NULL
                          AND l.expires_on < public.ranch_today())      AS expired_layer_count,
    COUNT(l.id) FILTER (WHERE l.qty_remaining > 0 AND l.expires_on IS NOT NULL
                          AND l.expires_on >= public.ranch_today()
                          AND l.expires_on < public.ranch_today() + 60) AS expiring_soon_count,
    -- Usage the ledger had no stock behind. NOT subtracted from qty_units: the
    -- shelf holds what the layers say it holds, and a count is what explains
    -- the hole. med_roll_forward carries the same figure as its own column so
    -- the two reports tie.
    COALESCE(sf.uncovered_units, 0)                           AS uncovered_units,
    COALESCE(sf.unpriced_usage_units, 0)                      AS unpriced_usage_units,
    (m.cost_per_unit IS NULL AND m.cost_per_head IS NULL)      AS unpriced_in_catalog,
    -- Cannot be stocked or counted until somebody says what it comes in.
    -- Doctoring is unaffected - dose_cc is already in base units - so these
    -- can still accrue usage; it shows as uncovered until they are set up.
    -- Flagged loudly rather than defaulted to 1, because a 100-dose cartridge
    -- entered as "100 bottles" of 1 makes the sheet ask for full bottles of a
    -- single dose each.
    (COALESCE(m.bottle_size, 0) <= 0)                          AS needs_container_size
FROM public.med_stock_locations loc
CROSS JOIN public.medications m
LEFT JOIN public.med_purchase_lines l
       ON l.medication_id = m.id AND l.location_id = loc.id AND l.qty_remaining > 0
LEFT JOIN shortfalls sf
       ON sf.medication_id = m.id AND sf.location_id = loc.id
WHERE loc.is_active AND m.is_active AND m.track_inventory
GROUP BY loc.id, loc.name, loc.kind, loc.is_test, loc.usage_from,
         m.id, m.name, m.generic_category, m.redwing_item_code,
         m.bottle_size_unit, m.bottle_size, m.cost_per_unit, m.cost_per_head,
         sf.uncovered_units, sf.unpriced_usage_units;


-- med_activity ----------------------------------------------------------
DROP VIEW IF EXISTS public.med_activity;
CREATE VIEW public.med_activity
WITH (security_invoker = true) AS
SELECT
    t.id, t.txn_date, t.txn_type, t.reason, t.direction,
    m.name AS medication_name, m.generic_category,
    loc.name AS location_name,
    cm.name  AS crew_member,
    t.qty_units,
    t.qty_units * t.direction AS signed_units,
    t.total_cost,
    t.total_cost * t.direction AS signed_value,
    t.shortfall_units, t.cost_provisional,
    t.ref_kind, t.ref_id, t.notes, t.fiscal_year, t.created_at
FROM public.med_txns t
JOIN public.medications m           ON m.id  = t.medication_id
JOIN public.med_stock_locations loc ON loc.id = t.location_id
LEFT JOIN public.med_crew_members cm ON cm.id = t.crew_member_id;


-- med_checkout_log ------------------------------------------------------
-- Who has bottles. That is ALL this answers, deliberately.
--
-- An earlier cut of this design compared a man's checkouts against the doses
-- he recorded and called the difference his shrink. That is invalid and no
-- future change makes it valid: two men work together, draw out of ONE man's
-- box, and the OTHER writes the treatment up. His checkouts drain against the
-- other man's records - one looks like he is losing drug, the other like he is
-- conjuring it. Where that is the habitual pairing it is a systematic bias
-- rather than noise, so it does not average out over a longer window either.
--
-- Crew logins do not fix it. They fix WHO TYPED IT, and say nothing about
-- WHOSE BOX IT CAME OUT OF. Only recording whose meds at the moment of
-- treatment would, and that is not worth a field-app change plus an extra tap
-- on every entry that is wrong precisely when two men work together.
--
-- The POOL is unaffected by any of this - it does not care whose hand the
-- bottle was in. Checkouts in, doses out, the count trues the whole thing up.
-- Shrink is a crew number. This view is for finding a bottle, not for blame.
DROP VIEW IF EXISTS public.med_checkout_log;
CREATE VIEW public.med_checkout_log
WITH (security_invoker = true) AS
SELECT
    t.id, t.txn_date,
    cm.name AS crew_member, t.crew_member_id,
    m.name  AS medication_name, m.generic_category, t.medication_id,
    CASE WHEN COALESCE(m.bottle_size, 0) > 0
         THEN round(t.qty_units / m.bottle_size, 2)
    END AS bottles,
    t.qty_units,
    COALESCE(m.bottle_size_unit, 'mL') AS unit,
    CASE WHEN t.qty_units < 0 THEN 'return' ELSE 'out' END AS direction_label,
    t.notes, t.created_at
FROM public.med_txns t
JOIN public.medications m            ON m.id  = t.medication_id
LEFT JOIN public.med_crew_members cm ON cm.id = t.crew_member_id
WHERE t.txn_type = 'checkout';


-- med_roll_forward ------------------------------------------------------
-- beginning + purchases + opening - used + adjustments + uncovered = ending
--
-- Ties by construction: ending is the running sum of the same signed movements
-- the columns are built from, so the statement cannot disagree with itself the
-- way a separately-computed ending balance can.
--
-- WHY `uncovered` IS A COLUMN AND NOT A PLUG
--
-- A dose given against stock the ledger did not have takes its full amount out
-- of `used` but only takes the covered part off real layers - there was nothing
-- else to take. Without the difference stated, this report and med_on_hand
-- disagree by exactly that much, forever, and the first person to notice stops
-- trusting both. So it gets its own column, it is part of the identity above,
-- and it reads as what it is: usage with no stock behind it, waiting for a
-- count to explain it.
DROP VIEW IF EXISTS public.med_roll_forward;
CREATE VIEW public.med_roll_forward
WITH (security_invoker = true) AS
WITH uncovered AS (
    SELECT txn_id,
           SUM(qty_units)     AS uncovered_units,
           SUM(extended_cost) AS uncovered_value
      FROM public.med_txn_layers
     WHERE purchase_line_id IS NULL
     GROUP BY txn_id
),
monthly AS (
    SELECT
        t.location_id, t.medication_id,
        date_trunc('month', t.txn_date)::date AS period_month,
        MAX(t.fiscal_year) AS fiscal_year,

        SUM(t.qty_units) FILTER (WHERE t.txn_type = 'purchase')              AS purchased_units,
        SUM(t.qty_units) FILTER (WHERE t.txn_type = 'opening')               AS opening_units,
        SUM(t.qty_units) FILTER (WHERE t.txn_type = 'usage')                 AS used_units,
        -- GROSS and signed, with the uncovered part left IN. It is taken back
        -- out once, by uncovered_units below, for every txn_type at once.
        -- Netting it out here as well would double-count any adjustment that
        -- carried a shortfall (a waste entry against an empty shelf) and the
        -- stated identity would quietly stop holding for exactly those rows.
        SUM(t.qty_units * t.direction)
            FILTER (WHERE t.txn_type = 'adjustment')                         AS adjustment_units,
        SUM(COALESCE(u.uncovered_units, 0))                                  AS uncovered_units,
        SUM(t.qty_units) FILTER (WHERE t.txn_type = 'adjustment'
                                   AND t.direction = -1 AND t.reason = 'count') AS shrink_units,

        SUM(COALESCE(t.total_cost,0)) FILTER (WHERE t.txn_type = 'purchase')  AS purchased_value,
        SUM(COALESCE(t.total_cost,0)) FILTER (WHERE t.txn_type = 'opening')   AS opening_value,
        SUM(COALESCE(t.total_cost,0)) FILTER (WHERE t.txn_type = 'usage')     AS used_value,
        -- Gross and signed, for the same reason as adjustment_units.
        SUM(COALESCE(t.total_cost,0) * t.direction)
            FILTER (WHERE t.txn_type = 'adjustment')                         AS adjustment_value,
        SUM(COALESCE(u.uncovered_value, 0))                                  AS uncovered_value,
        SUM(COALESCE(t.total_cost,0)) FILTER (WHERE t.txn_type = 'adjustment'
                                   AND t.direction = -1 AND t.reason = 'count') AS shrink_value,

        -- The INVENTORY effect, which is not the same as the dose given: only
        -- the part that came off a real layer moved any stock or any value.
        SUM((t.qty_units - COALESCE(u.uncovered_units,0)) * t.direction)      AS net_units,
        SUM((COALESCE(t.total_cost,0) - COALESCE(u.uncovered_value,0)) * t.direction) AS net_value
      FROM public.med_txns t
      LEFT JOIN uncovered u ON u.txn_id = t.id
     GROUP BY t.location_id, t.medication_id, date_trunc('month', t.txn_date)
)
SELECT
    loc.name AS location_name, mo.location_id,
    m.name   AS medication_name, m.generic_category, mo.medication_id,
    mo.period_month, mo.fiscal_year,

    COALESCE(mo.opening_units, 0)     AS opening_units,
    COALESCE(mo.purchased_units, 0)   AS purchased_units,
    COALESCE(mo.used_units, 0)        AS used_units,
    COALESCE(mo.adjustment_units, 0)  AS adjustment_units,
    COALESCE(mo.uncovered_units, 0)   AS uncovered_units,
    COALESCE(mo.shrink_units, 0)      AS shrink_units,

    round(COALESCE(mo.opening_value, 0), 2)    AS opening_value,
    round(COALESCE(mo.purchased_value, 0), 2)  AS purchased_value,
    round(COALESCE(mo.used_value, 0), 2)       AS used_value,
    round(COALESCE(mo.adjustment_value, 0), 2) AS adjustment_value,
    round(COALESCE(mo.uncovered_value, 0), 2)  AS uncovered_value,
    round(COALESCE(mo.shrink_value, 0), 2)     AS shrink_value,

    SUM(mo.net_units) OVER w - mo.net_units           AS beginning_units,
    SUM(mo.net_units) OVER w                          AS ending_units,
    round(SUM(mo.net_value) OVER w - mo.net_value, 2) AS beginning_value,
    round(SUM(mo.net_value) OVER w, 2)                AS ending_value
FROM monthly mo
JOIN public.medications m           ON m.id   = mo.medication_id
JOIN public.med_stock_locations loc ON loc.id = mo.location_id
WINDOW w AS (PARTITION BY mo.location_id, mo.medication_id ORDER BY mo.period_month
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW);


-- med_efficiency --------------------------------------------------------
-- Doses that reached cattle, against everything that left the shelf.
--
-- Note what "theoretical" already contains: round_up_to models the SYRINGE
-- SETTING including waste, not drug consumed, so a 6.3 cc dose recorded at
-- 7 cc has already counted its own 0.7 cc. This ratio therefore does not
-- measure ordinary dosing waste. It measures the rest - broken bottles,
-- expired product, over-drawn syringes, and treatments given but never
-- written down.
DROP VIEW IF EXISTS public.med_efficiency;
CREATE VIEW public.med_efficiency
WITH (security_invoker = true) AS
WITH per_period AS (
    SELECT
        t.location_id, t.medication_id,
        date_trunc('month', t.txn_date)::date AS period_month,
        MAX(t.fiscal_year) AS fiscal_year,
        SUM(t.qty_units) FILTER (WHERE t.txn_type = 'usage')                AS used_units,
        SUM(COALESCE(t.total_cost,0)) FILTER (WHERE t.txn_type = 'usage')   AS used_value,
        SUM(t.qty_units) FILTER (WHERE t.txn_type = 'adjustment' AND t.direction = -1) AS lost_units,
        SUM(COALESCE(t.total_cost,0)) FILTER (WHERE t.txn_type = 'adjustment' AND t.direction = -1) AS lost_value
      FROM public.med_txns t
     GROUP BY t.location_id, t.medication_id, date_trunc('month', t.txn_date)
)
SELECT
    loc.name AS location_name, p.location_id,
    m.name   AS medication_name, m.generic_category, p.medication_id,
    p.period_month, p.fiscal_year,
    COALESCE(p.used_units, 0) AS used_units,
    COALESCE(p.lost_units, 0) AS lost_units,
    COALESCE(p.used_units, 0) + COALESCE(p.lost_units, 0) AS drawn_units,
    round(COALESCE(p.used_value, 0), 2) AS used_value,
    round(COALESCE(p.lost_value, 0), 2) AS lost_value,
    CASE WHEN COALESCE(p.used_units,0) + COALESCE(p.lost_units,0) > 0
         THEN round(100.0 * COALESCE(p.used_units,0)
                    / (COALESCE(p.used_units,0) + COALESCE(p.lost_units,0)), 1)
    END AS efficiency_pct,
    CASE WHEN COALESCE(m.bottle_size,0) > 0
         THEN round(COALESCE(p.used_units,0) / m.bottle_size, 2)
    END AS bottles_into_cattle,
    CASE WHEN COALESCE(m.bottle_size,0) > 0
         THEN round((COALESCE(p.used_units,0) + COALESCE(p.lost_units,0)) / m.bottle_size, 2)
    END AS bottles_off_the_shelf
FROM per_period p
JOIN public.medications m           ON m.id   = p.medication_id
JOIN public.med_stock_locations loc ON loc.id = p.location_id;


-- med_buyer_reconciliation ----------------------------------------------
-- What a buyer drew against what the cattle he processed should have got.
--
-- Expected is the same arithmetic lot_processing_costs already does - protocol
-- dose per head at the receipt's weight, rounded by round_up_to, times head -
-- so nothing new is invented, only compared against what he picked up.
--
-- In this wave nothing consumes a buyer's stock (processing does not draw from
-- inventory until wave 2), so his balance is COMPUTED here rather than
-- ledgered. Honest for now, and it becomes real consumption later without the
-- report changing shape.
DROP VIEW IF EXISTS public.med_buyer_reconciliation;
CREATE VIEW public.med_buyer_reconciliation
WITH (security_invoker = true) AS
WITH lot_avg_wt AS (
    SELECT lot_id, SUM(total_weight_lb) / NULLIF(SUM(head_count),0)::numeric AS avg_wt
      FROM public.invoices
     WHERE head_count > 0 AND total_weight_lb > 0
     GROUP BY lot_id
),
receipt_wt AS (
    SELECT dr.id AS receipt_id, dr.lot_id, dr.receipt_date, dr.head_count,
           dr.receiving_protocol_id, lo.source AS buyer_source,
           COALESCE(i.total_weight_lb / NULLIF(i.head_count,0)::numeric, law.avg_wt) AS est_wt
      FROM public.delivery_receipts dr
      JOIN public.lots lo         ON lo.id = dr.lot_id
      LEFT JOIN public.invoices i ON i.id = dr.invoice_id
      LEFT JOIN lot_avg_wt law    ON law.lot_id = dr.lot_id
     WHERE dr.receiving_protocol_id IS NOT NULL
       AND dr.head_count > 0
       AND lo.is_test IS NOT TRUE
),
expected AS (
    SELECT
        loc.id AS location_id, pm.medication_id,
        date_trunc('month', rw.receipt_date)::date AS period_month,
        SUM(rw.head_count * CASE COALESCE(NULLIF(pm.override_dose_mode,''), m.dose_mode)
            WHEN 'flat' THEN COALESCE(pm.override_flat_dose, m.flat_dose_amount)
            WHEN 'per_weight' THEN
                CASE WHEN rw.est_wt IS NULL THEN NULL
                     WHEN COALESCE(m.round_up_to,0) > 0
                     THEN ceil(rw.est_wt
                               / COALESCE(pm.override_per_weight_basis, m.per_weight_basis, 100)
                               * COALESCE(pm.override_per_weight_rate, m.per_weight_rate)
                               / m.round_up_to) * m.round_up_to
                     ELSE rw.est_wt
                          / COALESCE(pm.override_per_weight_basis, m.per_weight_basis, 100)
                          * COALESCE(pm.override_per_weight_rate, m.per_weight_rate)
                END
            ELSE NULL END) AS expected_units,
        SUM(rw.head_count) AS head_processed
      FROM receipt_wt rw
      JOIN public.protocol_meds pm ON pm.protocol_id = rw.receiving_protocol_id
      JOIN public.medications m    ON m.id = pm.medication_id
      JOIN public.med_stock_locations loc
        ON loc.kind = 'buyer' AND loc.source_key IS NOT NULL
       AND lower(loc.source_key) = lower(rw.buyer_source)
     GROUP BY loc.id, pm.medication_id, date_trunc('month', rw.receipt_date)
),
drawn AS (
    SELECT l.location_id, l.medication_id,
           date_trunc('month', l.received_date)::date AS period_month,
           SUM(l.qty_units) AS drawn_units,
           SUM(l.qty_units * l.unit_cost) AS drawn_value
      FROM public.med_purchase_lines l
      JOIN public.med_stock_locations loc ON loc.id = l.location_id AND loc.kind = 'buyer'
     GROUP BY l.location_id, l.medication_id, date_trunc('month', l.received_date)
)
SELECT
    loc.name AS buyer_name,
    COALESCE(d.location_id, e.location_id)     AS location_id,
    m.name AS medication_name,
    COALESCE(d.medication_id, e.medication_id) AS medication_id,
    COALESCE(d.period_month, e.period_month)   AS period_month,
    COALESCE(e.head_processed, 0)              AS head_processed,
    round(COALESCE(e.expected_units, 0), 2)    AS expected_units,
    round(COALESCE(d.drawn_units, 0), 2)       AS drawn_units,
    round(COALESCE(d.drawn_units, 0) - COALESCE(e.expected_units, 0), 2) AS variance_units,
    round(COALESCE(d.drawn_value, 0), 2)       AS drawn_value,
    CASE WHEN COALESCE(d.drawn_units, 0) > 0
         THEN round(100.0 * COALESCE(e.expected_units,0) / d.drawn_units, 1)
    END AS efficiency_pct
FROM drawn d
FULL OUTER JOIN expected e
    ON  e.location_id   = d.location_id
    AND e.medication_id = d.medication_id
    AND e.period_month  = d.period_month
JOIN public.medications m
    ON m.id = COALESCE(d.medication_id, e.medication_id)
JOIN public.med_stock_locations loc
    ON loc.id = COALESCE(d.location_id, e.location_id);


-- ---------------------------------------------------------------------
-- 16. RLS. Rule 5: ENABLE *and* policies. ENABLE with no policy is a
--     total lockout; policies with no ENABLE are decoration.
--
--     Written longhand, one policy at a time, 32 of them. A DO loop over
--     a table-name array would be shorter and is how this was first
--     drafted -- it is not used here because nesting a dollar-quoted
--     policy body inside a dollar-quoted DO block is a parser fight
--     waiting to happen, and because a typo in a name array silently
--     skips a table and leaves it with RLS on and no policy, which
--     reads as "no rows" rather than as an error. The shipments
--     migration settled this the same way.
--
--     SELECT goes through can_read_books(), NOT a hardcoded
--     ARRAY['owner','office']. These are dollar tables: a purchase line
--     carries unit_cost, med_txns carry frozen cost, the count sheet
--     carries expected value. can_read_books() is already the 26-policy
--     read set, so the accountant reads this module on day one and the
--     next read-only role is one line in one function instead of
--     another 8-table migration (docs/database.md, 2026-09-01).
--
--     Crew is deliberately NOT in can_read_books(). Crew does the
--     doctoring; crew does not see what a bottle cost. The field app
--     never reads these tables -- usage arrives through med_consume(),
--     which is INVOKER and therefore still subject to these policies,
--     so the office posts it. A denied SELECT returns zero rows and not
--     an error, so any screen built on these tables says so on screen.
--
--     WRITE is a positive allow-list naming owner and office. Nothing
--     here is a negative test ("anyone who isn't crew"), which is the
--     property that makes adding a read-only role safe.
--
--     DELETE is owner-only on all eight. On the ledger tables that is
--     not symmetry for its own sake: med_txns and med_txn_layers are
--     the audit trail of what came off the shelf, and a deleted layer
--     allocation is unrecoverable in a way a wrong one is not -- the
--     reversal RPCs exist so nobody needs a raw delete.
-- ---------------------------------------------------------------------

ALTER TABLE public.med_stock_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.med_crew_members    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.med_purchases       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.med_purchase_lines  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.med_txns            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.med_txn_layers      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.med_counts          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.med_count_lines     ENABLE ROW LEVEL SECURITY;

-- med_stock_locations ---------------------------------------------------
DROP POLICY IF EXISTS med_stock_locations_select ON public.med_stock_locations;
CREATE POLICY med_stock_locations_select ON public.med_stock_locations
    FOR SELECT USING (public.can_read_books());

DROP POLICY IF EXISTS med_stock_locations_insert ON public.med_stock_locations;
CREATE POLICY med_stock_locations_insert ON public.med_stock_locations
    FOR INSERT WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_stock_locations_update ON public.med_stock_locations;
CREATE POLICY med_stock_locations_update ON public.med_stock_locations
    FOR UPDATE USING (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    ) WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_stock_locations_delete ON public.med_stock_locations;
CREATE POLICY med_stock_locations_delete ON public.med_stock_locations
    FOR DELETE USING (public.current_user_role() = 'owner');

-- med_crew_members ------------------------------------------------------
DROP POLICY IF EXISTS med_crew_members_select ON public.med_crew_members;
CREATE POLICY med_crew_members_select ON public.med_crew_members
    FOR SELECT USING (public.can_read_books());

DROP POLICY IF EXISTS med_crew_members_insert ON public.med_crew_members;
CREATE POLICY med_crew_members_insert ON public.med_crew_members
    FOR INSERT WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_crew_members_update ON public.med_crew_members;
CREATE POLICY med_crew_members_update ON public.med_crew_members
    FOR UPDATE USING (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    ) WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_crew_members_delete ON public.med_crew_members;
CREATE POLICY med_crew_members_delete ON public.med_crew_members
    FOR DELETE USING (public.current_user_role() = 'owner');

-- med_purchases ---------------------------------------------------------
DROP POLICY IF EXISTS med_purchases_select ON public.med_purchases;
CREATE POLICY med_purchases_select ON public.med_purchases
    FOR SELECT USING (public.can_read_books());

DROP POLICY IF EXISTS med_purchases_insert ON public.med_purchases;
CREATE POLICY med_purchases_insert ON public.med_purchases
    FOR INSERT WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_purchases_update ON public.med_purchases;
CREATE POLICY med_purchases_update ON public.med_purchases
    FOR UPDATE USING (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    ) WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_purchases_delete ON public.med_purchases;
CREATE POLICY med_purchases_delete ON public.med_purchases
    FOR DELETE USING (public.current_user_role() = 'owner');

-- med_purchase_lines ----------------------------------------------------
DROP POLICY IF EXISTS med_purchase_lines_select ON public.med_purchase_lines;
CREATE POLICY med_purchase_lines_select ON public.med_purchase_lines
    FOR SELECT USING (public.can_read_books());

DROP POLICY IF EXISTS med_purchase_lines_insert ON public.med_purchase_lines;
CREATE POLICY med_purchase_lines_insert ON public.med_purchase_lines
    FOR INSERT WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_purchase_lines_update ON public.med_purchase_lines;
CREATE POLICY med_purchase_lines_update ON public.med_purchase_lines
    FOR UPDATE USING (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    ) WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_purchase_lines_delete ON public.med_purchase_lines;
CREATE POLICY med_purchase_lines_delete ON public.med_purchase_lines
    FOR DELETE USING (public.current_user_role() = 'owner');

-- med_txns --------------------------------------------------------------
DROP POLICY IF EXISTS med_txns_select ON public.med_txns;
CREATE POLICY med_txns_select ON public.med_txns
    FOR SELECT USING (public.can_read_books());

DROP POLICY IF EXISTS med_txns_insert ON public.med_txns;
CREATE POLICY med_txns_insert ON public.med_txns
    FOR INSERT WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_txns_update ON public.med_txns;
CREATE POLICY med_txns_update ON public.med_txns
    FOR UPDATE USING (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    ) WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_txns_delete ON public.med_txns;
CREATE POLICY med_txns_delete ON public.med_txns
    FOR DELETE USING (public.current_user_role() = 'owner');

-- med_txn_layers --------------------------------------------------------
DROP POLICY IF EXISTS med_txn_layers_select ON public.med_txn_layers;
CREATE POLICY med_txn_layers_select ON public.med_txn_layers
    FOR SELECT USING (public.can_read_books());

DROP POLICY IF EXISTS med_txn_layers_insert ON public.med_txn_layers;
CREATE POLICY med_txn_layers_insert ON public.med_txn_layers
    FOR INSERT WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_txn_layers_update ON public.med_txn_layers;
CREATE POLICY med_txn_layers_update ON public.med_txn_layers
    FOR UPDATE USING (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    ) WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_txn_layers_delete ON public.med_txn_layers;
CREATE POLICY med_txn_layers_delete ON public.med_txn_layers
    FOR DELETE USING (public.current_user_role() = 'owner');

-- med_counts ------------------------------------------------------------
DROP POLICY IF EXISTS med_counts_select ON public.med_counts;
CREATE POLICY med_counts_select ON public.med_counts
    FOR SELECT USING (public.can_read_books());

DROP POLICY IF EXISTS med_counts_insert ON public.med_counts;
CREATE POLICY med_counts_insert ON public.med_counts
    FOR INSERT WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_counts_update ON public.med_counts;
CREATE POLICY med_counts_update ON public.med_counts
    FOR UPDATE USING (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    ) WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_counts_delete ON public.med_counts;
CREATE POLICY med_counts_delete ON public.med_counts
    FOR DELETE USING (public.current_user_role() = 'owner');

-- med_count_lines -------------------------------------------------------
DROP POLICY IF EXISTS med_count_lines_select ON public.med_count_lines;
CREATE POLICY med_count_lines_select ON public.med_count_lines
    FOR SELECT USING (public.can_read_books());

DROP POLICY IF EXISTS med_count_lines_insert ON public.med_count_lines;
CREATE POLICY med_count_lines_insert ON public.med_count_lines
    FOR INSERT WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_count_lines_update ON public.med_count_lines;
CREATE POLICY med_count_lines_update ON public.med_count_lines
    FOR UPDATE USING (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    ) WITH CHECK (
        public.current_user_role() = ANY (ARRAY['owner','office'])
    );

DROP POLICY IF EXISTS med_count_lines_delete ON public.med_count_lines;
CREATE POLICY med_count_lines_delete ON public.med_count_lines
    FOR DELETE USING (public.current_user_role() = 'owner');


-- ---------------------------------------------------------------------
-- 17. Grants. Rule 4: never GRANT to anon, and revoke from PUBLIC, not
--     just anon -- anon inherits PUBLIC, and Postgres grants function
--     EXECUTE to PUBLIC by default, so `REVOKE ... FROM anon` on its own
--     silently does nothing. The publishable key is in index.html, so
--     anything anon holds is public to the internet.
--
--     authenticated + RLS is the only path. The table grants below look
--     wide (INSERT/UPDATE/DELETE to every logged-in user) and are not:
--     the policies in section 16 are what decides, and crew holds the
--     grant but matches no policy, so crew writes nothing.
--
--     The two trigger functions get no EXECUTE grant. Postgres checks
--     EXECUTE on a trigger function at CREATE TRIGGER time, not on each
--     fire, so the triggers work with the function revoked from
--     everything -- which is what we want, because nobody should be able
--     to call med_layer_ledger() directly.
-- ---------------------------------------------------------------------

DO $grants$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'med_stock_locations','med_crew_members','med_purchases',
        'med_purchase_lines','med_txns','med_txn_layers',
        'med_counts','med_count_lines'
    ]
    LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', t);
        EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    END LOOP;
    RAISE NOTICE 'table grants: 8 tables, authenticated only';
END
$grants$;

DO $vgrants$
DECLARE
    v text;
BEGIN
    FOREACH v IN ARRAY ARRAY[
        'med_on_hand','med_activity','med_checkout_log',
        'med_roll_forward','med_efficiency','med_buyer_reconciliation'
    ]
    LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', v);
        EXECUTE format('REVOKE ALL ON public.%I FROM anon', v);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', v);
    END LOOP;
    RAISE NOTICE 'view grants: 6 views, SELECT to authenticated only';
END
$vgrants$;

DO $fgrants$
DECLARE
    f text;
BEGIN
    FOREACH f IN ARRAY ARRAY[
        'med_locked_through(uuid)',
        'med_consume(uuid,uuid,numeric,text,text,text,uuid,date,text,uuid)',
        'med_reverse_txn(uuid)',
        'med_settle_uncovered(uuid,uuid)',
        'med_post_count(uuid)',
        'med_unpost_count(uuid)',
        'med_purge_location(uuid,boolean)'
    ]
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC', f);
        EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM anon', f);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
    END LOOP;

    -- The trigger functions: revoked from everything, granted to nobody.
    REVOKE ALL ON FUNCTION public.med_layer_ledger()      FROM PUBLIC;
    REVOKE ALL ON FUNCTION public.med_layer_ledger()      FROM anon;
    REVOKE ALL ON FUNCTION public.med_guard_locked_period() FROM PUBLIC;
    REVOKE ALL ON FUNCTION public.med_guard_locked_period() FROM anon;

    RAISE NOTICE 'function grants: 7 callable RPCs, 2 trigger functions locked';
END
$fgrants$;


-- ---------------------------------------------------------------------
-- 18. Verify. Raises inside the transaction, so a failure here leaves
--     the database exactly as it was. Rules 1-6 of docs/database.md,
--     plus the obligation docs/inventory-flow-design.md decision 2 put
--     on this migration.
--
--     Run supabase/migrations/20260821000300_rls_verify.sql afterwards
--     as well (rule 7). This block is not a substitute for it; it is the
--     part that knows what THIS migration was supposed to build.
-- ---------------------------------------------------------------------

DO $verify$
DECLARE
    tables_arr constant text[] := ARRAY[
        'med_stock_locations','med_crew_members','med_purchases',
        'med_purchase_lines','med_txns','med_txn_layers',
        'med_counts','med_count_lines'
    ];
    views_arr constant text[] := ARRAY[
        'med_on_hand','med_activity','med_checkout_log',
        'med_roll_forward','med_efficiency','med_buyer_reconciliation'
    ];
    funcs_arr constant text[] := ARRAY[
        'med_layer_ledger','med_locked_through','med_guard_locked_period',
        'med_consume','med_reverse_txn','med_settle_uncovered',
        'med_post_count','med_unpost_count','med_purge_location'
    ];
    nm       text;
    bad      integer;
    n        integer;
    opts     text[];
    spine    text;
BEGIN
    -- (a) Rule 5: RLS enabled on all eight, and every one carries
    --     policies. ENABLE with no policy is a lockout that reads as
    --     "no rows"; policies with no ENABLE are decoration.
    FOREACH nm IN ARRAY tables_arr LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_class c
            JOIN pg_namespace ns ON ns.oid = c.relnamespace
            WHERE ns.nspname = 'public' AND c.relname = nm AND c.relrowsecurity
        ) THEN
            RAISE EXCEPTION 'RLS is not enabled on public.%', nm;
        END IF;

        SELECT count(*) INTO n
        FROM pg_policy p
        JOIN pg_class c ON c.oid = p.polrelid
        JOIN pg_namespace ns ON ns.oid = c.relnamespace
        WHERE ns.nspname = 'public' AND c.relname = nm;

        IF n <> 4 THEN
            RAISE EXCEPTION 'public.% has % policies, expected 4 (select/insert/update/delete)', nm, n;
        END IF;
    END LOOP;

    -- (b) Every SELECT policy here reads through can_read_books(), so the
    --     accountant role already reads this module and the next
    --     read-only role is one line in one function.
    SELECT count(*) INTO bad
    FROM pg_policy p
    JOIN pg_class c ON c.oid = p.polrelid
    JOIN pg_namespace ns ON ns.oid = c.relnamespace
    WHERE ns.nspname = 'public' AND c.relname = ANY (tables_arr)
      AND p.polcmd = 'r'
      AND coalesce(pg_get_expr(p.polqual, p.polrelid), '') NOT LIKE '%can_read_books%';
    IF bad > 0 THEN
        RAISE EXCEPTION '% SELECT policy/policies do not go through can_read_books()', bad;
    END IF;

    -- (c) And no WRITE policy mentions a read predicate or the
    --     accountant role. A read-only role must stay read-only; this is
    --     the same assertion the accountant migration makes, repeated
    --     because these eight tables did not exist when it ran.
    SELECT count(*) INTO bad
    FROM pg_policy p
    JOIN pg_class c ON c.oid = p.polrelid
    JOIN pg_namespace ns ON ns.oid = c.relnamespace
    WHERE ns.nspname = 'public' AND c.relname = ANY (tables_arr)
      AND p.polcmd <> 'r'
      AND (coalesce(pg_get_expr(p.polqual,      p.polrelid), '') ~ 'accountant|can_read_'
        OR coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') ~ 'accountant|can_read_');
    IF bad > 0 THEN
        RAISE EXCEPTION 'a read predicate or accountant reached % write policy/policies', bad;
    END IF;

    -- (d) Crew must not be named in any policy on these tables -- not in
    --     a read one (crew sees no dollars) and not in a write one.
    SELECT count(*) INTO bad
    FROM pg_policy p
    JOIN pg_class c ON c.oid = p.polrelid
    JOIN pg_namespace ns ON ns.oid = c.relnamespace
    WHERE ns.nspname = 'public' AND c.relname = ANY (tables_arr)
      AND (coalesce(pg_get_expr(p.polqual,      p.polrelid), '') LIKE '%crew%'
        OR coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') LIKE '%crew%');
    IF bad > 0 THEN
        RAISE EXCEPTION 'crew is named in % policy/policies on the med tables', bad;
    END IF;

    -- (e) Rule 3: security_invoker on every view. Asserted rather than
    --     assumed, because CREATE OR REPLACE VIEW clears reloptions when
    --     WITH is omitted and nothing errors when it does.
    FOREACH nm IN ARRAY views_arr LOOP
        SELECT c.reloptions INTO opts
        FROM pg_class c
        JOIN pg_namespace ns ON ns.oid = c.relnamespace
        WHERE ns.nspname = 'public' AND c.relname = nm AND c.relkind = 'v';

        IF NOT FOUND THEN
            RAISE EXCEPTION 'view public.% was not created', nm;
        END IF;
        IF opts IS NULL OR NOT ('security_invoker=true' = ANY (opts)) THEN
            RAISE EXCEPTION 'view public.% lacks security_invoker=true (reloptions: %)',
                nm, coalesce(opts::text, 'null');
        END IF;
    END LOOP;

    -- (f) Rule 6: default to INVOKER. Nothing in this module has a
    --     reason to bypass RLS -- the usage path is an office action on
    --     office tables, so every function here is INVOKER with a pinned
    --     search_path.
    SELECT count(*) INTO bad
    FROM pg_proc p
    JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public' AND p.proname = ANY (funcs_arr)
      AND (p.prosecdef
        OR p.proconfig IS NULL
        OR NOT (p.proconfig::text LIKE '%search_path=%'));
    IF bad > 0 THEN
        RAISE EXCEPTION '% function(s) are SECURITY DEFINER or lack a pinned search_path', bad;
    END IF;

    SELECT count(DISTINCT p.proname) INTO n
    FROM pg_proc p
    JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public' AND p.proname = ANY (funcs_arr);
    IF n <> array_length(funcs_arr, 1) THEN
        RAISE EXCEPTION 'expected % functions, found %', array_length(funcs_arr, 1), n;
    END IF;

    -- (g) Rule 4: nothing reachable by anon. Checked on tables, views
    --     and functions separately, because they are three different
    --     privilege systems and a PUBLIC grant on any of them shows up
    --     here through anon's inheritance.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        FOREACH nm IN ARRAY tables_arr || views_arr LOOP
            IF has_table_privilege('anon', 'public.' || quote_ident(nm),
                                   'SELECT, INSERT, UPDATE, DELETE') THEN
                RAISE EXCEPTION 'anon holds a privilege on public.%', nm;
            END IF;
        END LOOP;

        SELECT count(*) INTO bad
        FROM pg_proc p
        JOIN pg_namespace ns ON ns.oid = p.pronamespace
        WHERE ns.nspname = 'public' AND p.proname = ANY (funcs_arr)
          AND has_function_privilege('anon', p.oid, 'EXECUTE');
        IF bad > 0 THEN
            RAISE EXCEPTION 'anon can EXECUTE % med function(s)', bad;
        END IF;
    ELSE
        RAISE NOTICE 'role anon does not exist here - anon checks skipped';
    END IF;

    -- (h) The trigger functions are callable by nobody. Checked because
    --     the grant loop above deliberately leaves them out, and "I
    --     forgot them" and "I left them out on purpose" look identical
    --     in a diff.
    SELECT count(*) INTO bad
    FROM pg_proc p
    JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public'
      AND p.proname IN ('med_layer_ledger','med_guard_locked_period')
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE');
    IF bad > 0 THEN
        RAISE EXCEPTION '% trigger function(s) are EXECUTE-able by authenticated', bad;
    END IF;

    -- (i) The ledger triggers and the period-lock triggers all exist. A
    --     missing ledger trigger is the worst failure in the module: the
    --     layers never decrement, on hand reads full forever, and
    --     nothing errors.
    SELECT count(*) INTO n
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace ns ON ns.oid = c.relnamespace
    WHERE ns.nspname = 'public' AND NOT t.tgisinternal
      AND t.tgname IN ('med_purchase_lines_ledger_ins','med_purchase_lines_ledger_del',
                       'med_txns_period_lock','med_purchase_lines_period_lock');
    IF n <> 4 THEN
        RAISE EXCEPTION 'expected 4 med triggers, found %', n;
    END IF;

    -- (j) docs/inventory-flow-design.md decision 2 made this migration
    --     prove two things before building, and this is where that debt
    --     is paid:
    --
    --     "that supply_order_lines and supply_invoices take it with no
    --      schema change, and that the reorder engine's input shape
    --      (decision 6) can be filled from wherever meds hold on-hand."
    --
    --     Nothing in sections 1-17 alters the spine. The assertions
    --     below are the evidence, not a promise.
    SELECT pg_get_constraintdef(oid) INTO spine
    FROM pg_constraint
    WHERE conrelid = 'public.supply_order_lines'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%item_kind%'
    LIMIT 1;
    IF spine IS NULL OR spine NOT LIKE '%med%' THEN
        RAISE EXCEPTION 'supply_order_lines does not accept item_kind = med (%)',
            coalesce(spine, 'no item_kind check found');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'supply_order_lines'
          AND column_name = 'medication_id'
    ) THEN
        RAISE EXCEPTION 'supply_order_lines has no medication_id column';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.supply_order_lines'::regclass
          AND contype = 'f'
          AND confrelid = 'public.medications'::regclass
    ) THEN
        RAISE EXCEPTION 'supply_order_lines.medication_id does not reference medications';
    END IF;

    -- med_purchases.order_line_id is the join that makes a med receipt
    -- close a spine order line. If it is missing, a med order can be
    -- placed and never closed.
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.med_purchases'::regclass
          AND contype = 'f'
          AND confrelid = 'public.supply_order_lines'::regclass
    ) THEN
        RAISE EXCEPTION 'med_purchases.order_line_id does not reference supply_order_lines';
    END IF;

    -- Decision 11's input shape is (item_kind, item_id, on_hand_qty,
    -- unit, daily_burn, lead_time_days, safety_days, floor_qty).
    -- med_on_hand fills the first four for 'med'; daily_burn comes off
    -- med_activity; the three reorder settings are wave 2 and live on
    -- medications, not here. Assert the four this migration owes.
    SELECT count(*) INTO n
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'med_on_hand'
      AND column_name IN ('medication_id','qty_units','unit','location_id');
    IF n <> 4 THEN
        RAISE EXCEPTION 'med_on_hand does not expose the reorder input shape (found % of 4 columns)', n;
    END IF;

    RAISE NOTICE 'VERIFIED: 8 tables (RLS + 32 policies), 6 security_invoker views, 9 INVOKER functions, 4 triggers, spine unchanged';
END
$verify$;

commit;
