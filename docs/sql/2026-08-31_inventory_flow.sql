-- =====================================================================
-- Inventory flow - wave 1: the paperwork spine
-- =====================================================================
-- 2026-08-31. Decisions and reasoning: docs/inventory-flow-design.md
--
-- WHAT THIS BUILDS
--
--   vendors                   a real table, seeded from what is already typed
--   supply_orders             the order document, feed AND meds
--   supply_order_lines        one line per item; one line takes many loads
--   supply_invoices           the bill, matched as a document
--   supply_invoice_receipts   which loads a bill covered, and for how much
--   feed_price_variance       where an invoice difference goes to die
--
--   feed_receipts gains order_line_id, invoice_id, vendor_id, the paperwork
--   columns and a new 'opening_balance' source.
--
--   record_feed_delivery()    one atomic receiving path
--   match_supply_invoice()    tie out, allocate only on a difference
--   delete_supply_invoice()   refuses once variance has been booked
--   close_supply_order_line() "that's all they're bringing"
--
-- THE ONE RULE THIS FILE IS SHAPED BY
--
-- A frozen dollar is frozen. feed_usage_costs is never rewritten by
-- anything here. A load is costed at the ORDERED price when it arrives -
-- so feed stops reading free until the bill turns up - and when the
-- invoice differs, the layer is corrected GOING FORWARD while the
-- already-consumed difference is booked to feed_price_variance.
--
-- The one exception is the receipt that arrived with no price at all
-- (cost_pending). Its usage costs are NULL holes, not frozen numbers, so
-- matching an invoice to it fills them through the existing
-- recost_pending_usage() and writes NO variance row. Filling a hole is
-- not moving a value.
--
-- WHY THE ADJUSTMENT RIDES ON other_cost
--
-- total_cost and unit_cost_per_lb are GENERATED from product_cost +
-- freight_cost + other_cost, and FIFO costing reads unit_cost_per_lb. For
-- an invoice to re-price the remaining pounds, one of those three has to
-- move. product_cost and freight_cost are what was agreed at order time
-- and should keep saying so, which leaves other_cost - and an invoice can
-- come in LOW, so its >= 0 check is relaxed below. The audit trail does
-- not depend on that column: supply_invoice_receipts holds what the bill
-- actually said, and feed_price_variance holds what it cost us.
--
-- Rebuilding the two generated columns to add a dedicated adjustment
-- column was the tidier option and was rejected: it means dropping and
-- recreating feed_on_hand on a live table for a cosmetic gain.
--
-- IDEMPOTENT. Safe to run more than once.
--
-- APPLY: paste into the Supabase SQL editor. If ever applied through the
-- CLI instead, strip the begin;/commit; below - the CLI wraps migrations
-- in its own transaction and the inner commit closes it early.
--
-- AFTER APPLYING: run supabase/migrations/20260821000300_rls_verify.sql.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Preconditions
-- ---------------------------------------------------------------------
DO $pre$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['feed_items','feed_storage_locations','feed_receipts',
                             'feed_usage','feed_usage_costs','medications'] LOOP
        IF to_regclass('public.'||t) IS NULL THEN
            RAISE EXCEPTION 'Expected table public.% is missing. Refusing to proceed.', t;
        END IF;
    END LOOP;

    FOREACH t IN ARRAY ARRAY['feed_premix_shorts','feed_location_count_status',
                             'feed_cost_unallocated','feed_item_on_hand'] LOOP
        IF to_regclass('public.'||t) IS NULL THEN
            RAISE EXCEPTION 'Expected view public.% is missing - the needs-attention list reads it.', t;
        END IF;
    END LOOP;

    FOREACH t IN ARRAY ARRAY['current_user_role','touch_updated_at','ranch_today',
                             'recost_pending_usage'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                       WHERE n.nspname='public' AND p.proname = t) THEN
            RAISE EXCEPTION 'public.%() is missing. This migration depends on it.', t;
        END IF;
    END LOOP;
END
$pre$;


-- ---------------------------------------------------------------------
-- 1. vendors
-- ---------------------------------------------------------------------
-- Free text cannot carry "call Producers Cooperative" on an alert, and it
-- cannot filter unmatched receipts on the invoice screen, because it is
-- never the same string twice.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.vendors (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    phone       text,
    email       text,
    -- Default lead time for anything bought from them. An item-level
    -- lead time (wave 2) overrides it.
    lead_time_days integer CHECK (lead_time_days IS NULL OR lead_time_days >= 0),
    is_active   boolean NOT NULL DEFAULT true,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS vendors_name_uniq ON public.vendors (lower(name));

-- Seeded from what is already in the books, so there is nothing to type.
--
-- Three bookkeeping markers are excluded - they are not people you can
-- ring up. '(opening balance)' and '(count adjustment)' are written by
-- the app; 'Beginning Inventory' was typed by hand and exists in three
-- different capitalisations.
--
-- DISTINCT ON (lower(...)), not DISTINCT: the unique index is on
-- lower(name), so a plain DISTINCT keeps 'Beginning Inventory' and
-- 'beginning inventory' as two rows and the INSERT collides with itself.
-- ON CONFLICT DO NOTHING covers a re-run and any marker missed here.
INSERT INTO public.vendors (name)
SELECT DISTINCT ON (lower(btrim(r.vendor))) btrim(r.vendor)
FROM public.feed_receipts r
WHERE r.vendor IS NOT NULL
  AND btrim(r.vendor) <> ''
  AND lower(btrim(r.vendor)) <> ALL (ARRAY['(opening balance)',
                                           '(count adjustment)',
                                           'beginning inventory'])
ORDER BY lower(btrim(r.vendor)), btrim(r.vendor)
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------
-- 2. supply_orders / supply_order_lines
-- ---------------------------------------------------------------------
-- ONE spine for feed and meds. A line points at exactly one of the two
-- catalogs. Meds are not built yet; the column and the CHECK are, so that
-- the med rollout is a receiving handler and not a schema change.
--
-- A line with qty_lb NULL is a REMINDER-ONLY line: "Mark ordered" was
-- tapped and nothing else was typed. That is the whole med workflow John
-- described, and it closes itself when a receipt for the item lands.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.supply_orders (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    vendor_id   uuid REFERENCES public.vendors(id) ON DELETE RESTRICT,
    order_date  date NOT NULL DEFAULT public.ranch_today(),
    reference   text,                 -- their order/confirmation number
    status      text NOT NULL DEFAULT 'open'
                  CHECK (status IN ('open','closed','cancelled')),
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS supply_orders_date_idx   ON public.supply_orders (order_date DESC);
CREATE INDEX IF NOT EXISTS supply_orders_vendor_idx ON public.supply_orders (vendor_id);
CREATE INDEX IF NOT EXISTS supply_orders_open_idx   ON public.supply_orders (status) WHERE status = 'open';

CREATE TABLE IF NOT EXISTS public.supply_order_lines (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id      uuid NOT NULL REFERENCES public.supply_orders(id) ON DELETE CASCADE,

    item_kind     text NOT NULL CHECK (item_kind IN ('feed','med')),
    feed_item_id  uuid REFERENCES public.feed_items(id)  ON DELETE RESTRICT,
    medication_id uuid REFERENCES public.medications(id) ON DELETE RESTRICT,

    -- Where it is going. Feed only, and only a default - the ticket wins.
    destination_location_id uuid REFERENCES public.feed_storage_locations(id) ON DELETE SET NULL,

    -- Ordered quantity. NULL on a reminder-only line.
    -- The unit and its conversion are SNAPSHOT here rather than read from
    -- feed_items at delivery: editing an item's lb_per_purchase_unit must
    -- not silently re-price an order already placed.
    purchase_unit           text,
    lb_per_purchase_unit    numeric CHECK (lb_per_purchase_unit IS NULL OR lb_per_purchase_unit > 0),
    qty_purchase_units      numeric CHECK (qty_purchase_units IS NULL OR qty_purchase_units > 0),
    qty_lb                  numeric CHECK (qty_lb IS NULL OR qty_lb > 0),

    -- The agreed price. This is what the delivered load is costed at.
    price_per_purchase_unit numeric CHECK (price_per_purchase_unit IS NULL OR price_per_purchase_unit >= 0),
    -- A blank price must never be an accident. Same shape, and the same
    -- reason, as feed_receipts.cost_pending.
    price_unknown           boolean NOT NULL DEFAULT false,

    price_per_lb  numeric GENERATED ALWAYS AS (
                      CASE WHEN price_unknown THEN NULL
                           ELSE price_per_purchase_unit / NULLIF(lb_per_purchase_unit,0)
                      END) STORED,

    expected_delivery_date date,

    closed_at     timestamptz,
    close_reason  text,

    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL,

    -- Exactly one catalog, and it must agree with item_kind.
    CONSTRAINT supply_order_lines_one_item_ck CHECK (
        (item_kind = 'feed' AND feed_item_id IS NOT NULL AND medication_id IS NULL)
     OR (item_kind = 'med'  AND medication_id IS NOT NULL AND feed_item_id IS NULL)
    ),
    -- A quantified line needs a price or an explicit admission there isn't
    -- one. A reminder-only line (qty_lb NULL) needs neither.
    CONSTRAINT supply_order_lines_price_ck CHECK (
        qty_lb IS NULL OR price_unknown OR price_per_purchase_unit IS NOT NULL
    ),
    -- A feed line delivers into a bay; a med line does not.
    CONSTRAINT supply_order_lines_dest_ck CHECK (
        item_kind = 'feed' OR destination_location_id IS NULL
    )
);
CREATE INDEX IF NOT EXISTS supply_order_lines_order_idx ON public.supply_order_lines (order_id);
CREATE INDEX IF NOT EXISTS supply_order_lines_feed_idx  ON public.supply_order_lines (feed_item_id)  WHERE feed_item_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supply_order_lines_med_idx   ON public.supply_order_lines (medication_id) WHERE medication_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS supply_order_lines_open_idx  ON public.supply_order_lines (closed_at) WHERE closed_at IS NULL;


-- ---------------------------------------------------------------------
-- 3. supply_invoices / supply_invoice_receipts
-- ---------------------------------------------------------------------
-- The bill is a DOCUMENT, not a text field on four receipts. Without a
-- header nothing ever compares the paper to the books, and a line on the
-- bill with no receipt to tick - a delivery that happened and was never
-- recorded - is invisible.
--
-- Named supply_, not feed_: one bill can cover both once meds are in.
-- This is NOT accounts payable. Redwing owns the payable. No due date, no
-- payment status, no check number.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.supply_invoices (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    vendor_id      uuid NOT NULL REFERENCES public.vendors(id) ON DELETE RESTRICT,
    invoice_number text NOT NULL,
    invoice_date   date NOT NULL,
    total_amount   numeric NOT NULL CHECK (total_amount >= 0),
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS supply_invoices_vendor_number_uniq
    ON public.supply_invoices (vendor_id, lower(invoice_number));
CREATE INDEX IF NOT EXISTS supply_invoices_date_idx ON public.supply_invoices (invoice_date DESC);

-- What the bill said each load cost. Kept separately from the receipt's
-- own cost columns so the paper and the books can be compared later
-- without unpicking an adjustment.
CREATE TABLE IF NOT EXISTS public.supply_invoice_receipts (
    invoice_id       uuid NOT NULL REFERENCES public.supply_invoices(id) ON DELETE CASCADE,
    receipt_id       uuid NOT NULL REFERENCES public.feed_receipts(id) ON DELETE CASCADE,
    invoiced_amount  numeric NOT NULL CHECK (invoiced_amount >= 0),
    expected_amount  numeric,   -- what the ordered price said, frozen at match time
    created_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (invoice_id, receipt_id)
);
-- A load belongs to one bill. Two bills for one delivery is a data error,
-- not a business case.
CREATE UNIQUE INDEX IF NOT EXISTS supply_invoice_receipts_one_invoice
    ON public.supply_invoice_receipts (receipt_id);


-- ---------------------------------------------------------------------
-- 4. feed_price_variance - the two-sided account
-- ---------------------------------------------------------------------
-- Its BALANCE is the useful number: how well agreed prices predict actual
-- bills. A consistent drift is a freight assumption to fix or a vendor
-- conversation to have.
--
-- Only ever written for pounds ALREADY CONSUMED at the old price. The
-- pounds still in the bay are re-priced on the layer instead.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.feed_price_variance (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_id       uuid NOT NULL REFERENCES public.feed_receipts(id) ON DELETE RESTRICT,
    invoice_id       uuid REFERENCES public.supply_invoices(id) ON DELETE RESTRICT,
    booked_on        date NOT NULL DEFAULT public.ranch_today(),
    consumed_lb      numeric NOT NULL CHECK (consumed_lb > 0),
    old_cost_per_lb  numeric NOT NULL,
    new_cost_per_lb  numeric NOT NULL,
    -- Positive = the bill came in above the ordered price on feed already
    -- eaten, i.e. cost we under-booked.
    variance_usd     numeric NOT NULL,
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS feed_price_variance_receipt_idx ON public.feed_price_variance (receipt_id);
CREATE INDEX IF NOT EXISTS feed_price_variance_invoice_idx ON public.feed_price_variance (invoice_id);
CREATE INDEX IF NOT EXISTS feed_price_variance_date_idx    ON public.feed_price_variance (booked_on DESC);


-- ---------------------------------------------------------------------
-- 5. feed_receipts - the new columns
-- ---------------------------------------------------------------------
ALTER TABLE public.feed_receipts
    ADD COLUMN IF NOT EXISTS order_line_id uuid REFERENCES public.supply_order_lines(id) ON DELETE RESTRICT,
    ADD COLUMN IF NOT EXISTS invoice_id    uuid REFERENCES public.supply_invoices(id)    ON DELETE RESTRICT,
    ADD COLUMN IF NOT EXISTS vendor_id     uuid REFERENCES public.vendors(id)            ON DELETE RESTRICT,
    -- Where the dollars on this layer came from. 'ordered' is the normal
    -- path now; 'pending' is the exception it used to be.
    ADD COLUMN IF NOT EXISTS price_source  text NOT NULL DEFAULT 'manual',
    -- Decision 13: the reminder is the EMPTY FIELD, and this is the one
    -- deliberate way to say "stop asking". Not a note somebody has to
    -- remember to write - the load where that is forgotten is the load
    -- that goes missing.
    ADD COLUMN IF NOT EXISTS paperwork_done      boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS paperwork_done_at   timestamptz,
    ADD COLUMN IF NOT EXISTS paperwork_done_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS paperwork_note      text;

DO $rcols$
BEGIN
    -- price_source values
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid='public.feed_receipts'::regclass
                     AND conname='feed_receipts_price_source_ck') THEN
        ALTER TABLE public.feed_receipts
            ADD CONSTRAINT feed_receipts_price_source_ck
            CHECK (price_source IN ('ordered','invoice','manual','pending','opening'));
    END IF;

    -- 'opening_balance' joins the source list. Without it the opening
    -- layers look like purchases and raise "awaiting weight ticket" and
    -- "awaiting invoice" forever - sixteen permanent false alarms on a
    -- brand new list, which is how a list gets ignored in week one.
    -- Two spellings: the 11 PB reseed rows carry '(opening balance)',
    -- and 5 hand-entered Redmond/Purina/silage/bagged rows carry
    -- 'Beginning Inventory' in three capitalisations. Their notes say
    -- plainly what they are - "Enter and price beginning inventory from
    -- RW", "moved in from Redwing inventory".
    IF EXISTS (SELECT 1 FROM pg_constraint
               WHERE conrelid='public.feed_receipts'::regclass
                 AND conname='feed_receipts_source_check') THEN
        ALTER TABLE public.feed_receipts DROP CONSTRAINT feed_receipts_source_check;
    END IF;
    ALTER TABLE public.feed_receipts
        ADD CONSTRAINT feed_receipts_source_check
        CHECK (source IN ('purchase','count_adjustment','transfer_in','batch_out','opening_balance'));

    -- other_cost carries the invoice true-up, and an invoice can come in
    -- LOW. See the header for why the adjustment rides here rather than
    -- on a dedicated column.
    IF EXISTS (SELECT 1 FROM pg_constraint
               WHERE conrelid='public.feed_receipts'::regclass
                 AND conname='feed_receipts_other_cost_check') THEN
        ALTER TABLE public.feed_receipts DROP CONSTRAINT feed_receipts_other_cost_check;
    END IF;
    -- Deliberately no >= 0 - an invoice can come in below the ordered
    -- price. The bound is only a fat-finger guard; total_cost itself is
    -- checked in match_supply_invoice().
    ALTER TABLE public.feed_receipts
        ADD CONSTRAINT feed_receipts_other_cost_check
        CHECK (other_cost IS NULL OR other_cost >= -1000000);
END
$rcols$;

CREATE INDEX IF NOT EXISTS feed_receipts_order_line_idx ON public.feed_receipts (order_line_id) WHERE order_line_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS feed_receipts_invoice_idx    ON public.feed_receipts (invoice_id);
CREATE INDEX IF NOT EXISTS feed_receipts_vendor_id_idx  ON public.feed_receipts (vendor_id);
-- The "waiting on paperwork" read.
CREATE INDEX IF NOT EXISTS feed_receipts_paperwork_idx
    ON public.feed_receipts (receipt_date)
    WHERE paperwork_done = false AND source = 'purchase';


-- ---------------------------------------------------------------------
-- 6. Backfill: vendor_id, and the 8/30 opening balance
-- ---------------------------------------------------------------------
UPDATE public.feed_receipts r
SET vendor_id = v.id
FROM public.vendors v
WHERE r.vendor_id IS NULL
  AND r.vendor IS NOT NULL
  AND lower(btrim(r.vendor)) = lower(v.name);

DO $opening$
DECLARE n integer;
BEGIN
    UPDATE public.feed_receipts
    SET source       = 'opening_balance',
        price_source = 'opening',
        notes        = coalesce(notes,'')
                       || E'\n2026-08-31: source changed purchase -> opening_balance so the '
                       || 'inventory needs-attention list does not chase a weight ticket and an '
                       || 'invoice that never existed. Quantities and dollars unchanged. '
                       || 'See docs/inventory-flow-design.md decision 21.'
    WHERE source = 'purchase'
      AND lower(btrim(coalesce(vendor,''))) = ANY (ARRAY['(opening balance)',
                                                         'beginning inventory']);
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'Opening-balance receipts repointed: % (expected 16 on first run)', n;
END
$opening$;


-- ---------------------------------------------------------------------
-- 7. updated_at triggers
-- ---------------------------------------------------------------------
DO $touch$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['vendors','supply_orders','supply_order_lines','supply_invoices'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_trigger
                       WHERE tgrelid = ('public.'||t)::regclass
                         AND tgname  = t||'_touch') THEN
            EXECUTE format(
                'CREATE TRIGGER %I BEFORE UPDATE ON public.%I
                 FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at()', t||'_touch', t);
        END IF;
    END LOOP;
END
$touch$;


-- ---------------------------------------------------------------------
-- 8. Grants, RLS and policies - office + owner. Crew sees none of it.
-- ---------------------------------------------------------------------
-- Never GRANT to anon: the publishable key is public, so anything anon
-- holds is public. Revoke from PUBLIC as well as anon - Postgres grants
-- to PUBLIC by default and revoking from anon alone silently does
-- nothing.
--
-- DELETE is owner-only. An order line deleted with a receipt hanging off
-- it is an unrecoverable break in the chain; an accidental insert is not.
-- ---------------------------------------------------------------------
DO $grants$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['vendors','supply_orders','supply_order_lines',
                             'supply_invoices','supply_invoice_receipts',
                             'feed_price_variance'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', t);
        EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);

        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t||'_select', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t||'_insert', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t||'_update', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t||'_delete', t);

        EXECUTE format($f$
            CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
            USING (public.current_user_role() = ANY (ARRAY['owner','office']))$f$,
            t||'_select', t);
        EXECUTE format($f$
            CREATE POLICY %I ON public.%I FOR INSERT TO authenticated
            WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']))$f$,
            t||'_insert', t);
        EXECUTE format($f$
            CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated
            USING (public.current_user_role() = ANY (ARRAY['owner','office']))
            WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']))$f$,
            t||'_update', t);
        EXECUTE format($f$
            CREATE POLICY %I ON public.%I FOR DELETE TO authenticated
            USING (public.current_user_role() = 'owner')$f$,
            t||'_delete', t);
    END LOOP;
END
$grants$;


-- ---------------------------------------------------------------------
-- 9. Views
-- ---------------------------------------------------------------------
-- EVERY view is security_invoker. Without it a view runs as its owner and
-- bypasses RLS entirely, regardless of the policies above.
--
-- Dropped in REVERSE dependency order. inventory_needs_attention reads the
-- other two, so dropping them first fails on the second run of this file.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS public.inventory_needs_attention;
DROP VIEW IF EXISTS public.supply_invoice_reconciliation;
DROP VIEW IF EXISTS public.supply_order_line_status;

-- What is still coming, and how late it is.
CREATE VIEW public.supply_order_line_status
WITH (security_invoker = true) AS
SELECT
    l.id                        AS order_line_id,
    o.id                        AS order_id,
    o.order_date,
    o.status                    AS order_status,
    o.reference,
    v.id                        AS vendor_id,
    v.name                      AS vendor_name,
    l.item_kind,
    l.feed_item_id,
    l.medication_id,
    coalesce(fi.name, m.name)   AS item_name,
    l.destination_location_id,
    sl.name                     AS destination_name,
    l.purchase_unit,
    l.lb_per_purchase_unit,
    l.qty_purchase_units,
    l.qty_lb                    AS ordered_lb,
    l.price_per_purchase_unit,
    l.price_unknown,
    l.price_per_lb,
    l.expected_delivery_date,
    l.closed_at,
    l.close_reason,
    -- A reminder-only line carries no quantity at all.
    (l.qty_lb IS NULL)          AS is_reminder_only,
    coalesce(rc.received_lb, 0) AS received_lb,
    CASE WHEN l.qty_lb IS NULL THEN NULL
         ELSE greatest(l.qty_lb - coalesce(rc.received_lb,0), 0) END AS remaining_lb,
    -- Over-delivery is allowed, flagged, never blocked. Refusing to
    -- record it does not un-deliver the corn.
    (l.qty_lb IS NOT NULL AND coalesce(rc.received_lb,0) > l.qty_lb)  AS is_over,
    coalesce(rc.load_count, 0)  AS load_count,
    (l.closed_at IS NULL AND o.status = 'open')                       AS is_open,
    CASE WHEN l.closed_at IS NULL AND o.status = 'open'
              AND l.expected_delivery_date IS NOT NULL
              AND l.expected_delivery_date < public.ranch_today()
              AND coalesce(rc.received_lb,0) = 0
         THEN public.ranch_today() - l.expected_delivery_date END     AS days_overdue
FROM public.supply_order_lines l
JOIN public.supply_orders o        ON o.id = l.order_id
LEFT JOIN public.vendors v         ON v.id = o.vendor_id
LEFT JOIN public.feed_items fi     ON fi.id = l.feed_item_id
LEFT JOIN public.medications m     ON m.id = l.medication_id
LEFT JOIN public.feed_storage_locations sl ON sl.id = l.destination_location_id
LEFT JOIN LATERAL (
    SELECT sum(r.qty_lb) AS received_lb, count(*) AS load_count
    FROM public.feed_receipts r
    WHERE r.order_line_id = l.id
) rc ON true;

-- Does the bill STILL tie? A different question from the save-time check
-- - this one catches a later edit to a matched receipt.
CREATE VIEW public.supply_invoice_reconciliation
WITH (security_invoker = true) AS
SELECT
    i.id                                  AS invoice_id,
    i.invoice_number,
    i.invoice_date,
    v.name                                AS vendor_name,
    i.total_amount,
    coalesce(sum(sir.invoiced_amount), 0) AS allocated_amount,
    i.total_amount - coalesce(sum(sir.invoiced_amount), 0) AS variance_usd,
    count(sir.receipt_id)                 AS matched_loads
FROM public.supply_invoices i
LEFT JOIN public.vendors v                ON v.id = i.vendor_id
LEFT JOIN public.supply_invoice_receipts sir ON sir.invoice_id = i.id
GROUP BY i.id, i.invoice_number, i.invoice_date, v.name, i.total_amount;

-- THE ONE LIST. Rendered three ways - a sub-tab, a dashboard badge and
-- the 7am email - from one definition, so they cannot drift.
-- Wave 1 carries the paperwork rows; wave 2 adds the reorder rows.
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
FROM public.feed_cost_unallocated ua;

DO $vgrants$
DECLARE v text;
BEGIN
    FOREACH v IN ARRAY ARRAY['supply_order_line_status','supply_invoice_reconciliation',
                             'inventory_needs_attention'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', v);
        EXECUTE format('REVOKE ALL ON public.%I FROM anon', v);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', v);
    END LOOP;
END
$vgrants$;


-- ---------------------------------------------------------------------
-- 10. record_feed_delivery - the one receiving path
-- ---------------------------------------------------------------------
-- SECURITY INVOKER, like every other ledger and head-math RPC. It must
-- run under the caller's RLS.
--
-- An RPC rather than three browser statements because the receipt insert,
-- the order-line close and the reminder-line close have to happen
-- together or not at all - and because the field app, if it ever gets
-- receiving, should be a CALLER and not a second implementation.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_feed_delivery(
    p_item_id            uuid,
    p_location_id        uuid,
    p_qty_lb             numeric,
    p_receipt_date       date    DEFAULT NULL,
    p_order_line_id      uuid    DEFAULT NULL,
    p_ticket_number      text    DEFAULT NULL,
    p_qty_purchase_units numeric DEFAULT NULL,
    p_vendor_id          uuid    DEFAULT NULL,
    p_product_cost       numeric DEFAULT NULL,
    p_freight_cost       numeric DEFAULT NULL,
    p_other_cost         numeric DEFAULT NULL,
    p_cost_pending       boolean DEFAULT false,
    p_gross_qty_lb       numeric DEFAULT NULL,
    p_shrink_allowance_pct numeric DEFAULT NULL,
    p_notes              text    DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $rfd$
DECLARE
    v_line        public.supply_order_lines%ROWTYPE;
    v_date        date := coalesce(p_receipt_date, public.ranch_today());
    v_item        uuid := p_item_id;
    v_location    uuid := p_location_id;
    v_vendor      uuid := p_vendor_id;
    v_product     numeric := p_product_cost;
    v_pending     boolean := coalesce(p_cost_pending, false);
    v_source      text := 'ordered';
    v_receipt_id  uuid;
    v_received    numeric;
BEGIN
    IF p_qty_lb IS NULL OR p_qty_lb <= 0 THEN
        RAISE EXCEPTION 'A delivery needs a weight greater than zero.';
    END IF;

    IF p_order_line_id IS NOT NULL THEN
        SELECT * INTO v_line FROM public.supply_order_lines WHERE id = p_order_line_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Order line % not found.', p_order_line_id;
        END IF;
        IF v_line.item_kind <> 'feed' THEN
            RAISE EXCEPTION 'Order line % is a % line, not feed.', p_order_line_id, v_line.item_kind;
        END IF;
        IF v_line.closed_at IS NOT NULL THEN
            RAISE EXCEPTION 'Order line % is closed. Reopen it or receive without an order.', p_order_line_id;
        END IF;

        v_item := coalesce(v_item, v_line.feed_item_id);
        IF v_item <> v_line.feed_item_id THEN
            RAISE EXCEPTION 'This ticket is for a different item than order line %.', p_order_line_id;
        END IF;
        v_location := coalesce(v_location, v_line.destination_location_id);

        SELECT o.vendor_id INTO v_vendor
        FROM public.supply_orders o WHERE o.id = v_line.order_id;
        v_vendor := coalesce(p_vendor_id, v_vendor);

        -- The load is costed at the ORDERED price, so the feed stops
        -- reading free until the bill turns up. An explicit cost passed
        -- in wins - the ticket occasionally disagrees with the order.
        IF v_product IS NULL AND NOT v_pending AND v_line.price_per_lb IS NOT NULL THEN
            v_product := round(p_qty_lb * v_line.price_per_lb, 2);
            v_source  := 'ordered';
        ELSIF v_product IS NOT NULL THEN
            v_source := 'manual';
        END IF;
    ELSE
        v_source := 'manual';
    END IF;

    IF v_location IS NULL THEN
        RAISE EXCEPTION 'A delivery needs a storage location.';
    END IF;

    -- A blank price must never be an accident. This is the same rule as
    -- the unpriced medication that SUM() silently ignores.
    IF NOT v_pending AND v_product IS NULL THEN
        RAISE EXCEPTION 'This load has no price. Enter one, or mark it cost-pending explicitly.';
    END IF;
    IF v_pending THEN
        v_source := 'pending';
    END IF;

    INSERT INTO public.feed_receipts (
        receipt_date, item_id, location_id, vendor_id, vendor,
        ticket_number, qty_purchase_units, qty_lb, qty_lb_remaining,
        product_cost, freight_cost, other_cost, cost_pending,
        gross_qty_lb, shrink_allowance_pct,
        order_line_id, price_source, source, notes, created_by
    )
    VALUES (
        v_date, v_item, v_location, v_vendor,
        (SELECT name FROM public.vendors WHERE id = v_vendor),
        nullif(btrim(coalesce(p_ticket_number,'')),''),
        p_qty_purchase_units, p_qty_lb, p_qty_lb,
        v_product, p_freight_cost, p_other_cost, v_pending,
        p_gross_qty_lb, p_shrink_allowance_pct,
        p_order_line_id, v_source, 'purchase', p_notes, auth.uid()
    )
    RETURNING id INTO v_receipt_id;

    -- Close the line once it is satisfied. Over-delivery closes it too -
    -- flagged on supply_order_line_status, never blocked.
    IF p_order_line_id IS NOT NULL AND v_line.qty_lb IS NOT NULL THEN
        SELECT coalesce(sum(qty_lb),0) INTO v_received
        FROM public.feed_receipts WHERE order_line_id = p_order_line_id;
        IF v_received >= v_line.qty_lb THEN
            UPDATE public.supply_order_lines
            SET closed_at = now(), close_reason = 'received in full'
            WHERE id = p_order_line_id AND closed_at IS NULL;
        END IF;
    END IF;

    -- Any receipt closes that item's REMINDER-ONLY lines. A "Mark
    -- ordered" tap in September closes itself when the load arrives in
    -- October. Nothing to tidy, which is the point.
    UPDATE public.supply_order_lines l
    SET closed_at = now(), close_reason = 'closed by delivery'
    WHERE l.closed_at IS NULL
      AND l.qty_lb IS NULL
      AND l.item_kind = 'feed'
      AND l.feed_item_id = v_item
      AND l.id IS DISTINCT FROM p_order_line_id;

    RETURN v_receipt_id;
END
$rfd$;


-- ---------------------------------------------------------------------
-- 11. match_supply_invoice - tie out first, allocate only on a difference
-- ---------------------------------------------------------------------
-- p_allocations: [{"receipt_id":"...","invoiced_amount":1234.56}, ...]
-- The app does the pro-rata-by-pounds split (or the office types actuals)
-- and passes the result; this function books it.
--
-- Per receipt:
--   was cost_pending  -> the usage costs are NULL HOLES. Fill them via the
--                        existing recost_pending_usage(). NO variance row -
--                        there is no frozen number to differ from.
--   was priced        -> correct the layer going forward, and book the
--                        already-consumed difference to feed_price_variance.
--                        feed_usage_costs is never touched.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_supply_invoice(
    p_invoice_id  uuid,
    p_allocations jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $msi$
DECLARE
    v_invoice   public.supply_invoices%ROWTYPE;
    v_alloc_sum numeric := 0;
    rec_rec     record;
    v_r         public.feed_receipts%ROWTYPE;
    v_old_unit  numeric;
    v_new_unit  numeric;
    v_old_total numeric;
    v_delta     numeric;
    v_consumed  numeric;
    v_was_pending boolean;
    v_n         integer := 0;
BEGIN
    SELECT * INTO v_invoice FROM public.supply_invoices WHERE id = p_invoice_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invoice % not found.', p_invoice_id;
    END IF;

    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array'
       OR jsonb_array_length(p_allocations) = 0 THEN
        RAISE EXCEPTION 'No loads were ticked for invoice %.', v_invoice.invoice_number;
    END IF;

    SELECT coalesce(sum((a->>'invoiced_amount')::numeric), 0)
    INTO v_alloc_sum
    FROM jsonb_array_elements(p_allocations) a;

    -- The whole point of a bill being a document is that it has to add up.
    IF abs(v_alloc_sum - v_invoice.total_amount) >= 0.01 THEN
        RAISE EXCEPTION 'Allocation does not tie: loads add to %, invoice says %.',
              round(v_alloc_sum,2), round(v_invoice.total_amount,2);
    END IF;

    FOR rec_rec IN
        SELECT (a->>'receipt_id')::uuid       AS receipt_id,
               (a->>'invoiced_amount')::numeric AS invoiced_amount
        FROM jsonb_array_elements(p_allocations) a
    LOOP
        SELECT * INTO v_r FROM public.feed_receipts WHERE id = rec_rec.receipt_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Receipt % not found.', rec_rec.receipt_id;
        END IF;
        IF v_r.invoice_id IS NOT NULL AND v_r.invoice_id <> p_invoice_id THEN
            RAISE EXCEPTION 'Receipt % is already on another invoice.', rec_rec.receipt_id;
        END IF;
        IF rec_rec.invoiced_amount < 0 THEN
            RAISE EXCEPTION 'A load cannot be billed a negative amount.';
        END IF;

        v_was_pending := v_r.cost_pending;
        v_old_total   := coalesce(v_r.total_cost, 0);
        v_old_unit    := coalesce(v_r.unit_cost_per_lb, 0);
        v_consumed    := v_r.qty_lb - v_r.qty_lb_remaining;
        v_delta       := rec_rec.invoiced_amount - v_old_total;

        IF v_old_total + v_delta < 0 THEN
            RAISE EXCEPTION 'Invoicing receipt % at % would make its total cost negative.',
                  rec_rec.receipt_id, round(rec_rec.invoiced_amount,2);
        END IF;

        -- The adjustment rides on other_cost so the generated cost columns
        -- pick it up; product_cost and freight_cost keep saying what was
        -- agreed at order time. See the file header.
        UPDATE public.feed_receipts
        SET other_cost   = coalesce(other_cost, 0) + v_delta,
            cost_pending = false,
            invoice_id   = p_invoice_id,
            invoice_number = v_invoice.invoice_number,
            price_source = 'invoice',
            updated_at   = now()
        WHERE id = rec_rec.receipt_id;

        SELECT unit_cost_per_lb INTO v_new_unit
        FROM public.feed_receipts WHERE id = rec_rec.receipt_id;

        INSERT INTO public.supply_invoice_receipts
              (invoice_id, receipt_id, invoiced_amount, expected_amount)
        VALUES (p_invoice_id, rec_rec.receipt_id, rec_rec.invoiced_amount,
                CASE WHEN v_was_pending THEN NULL ELSE v_old_total END)
        ON CONFLICT (invoice_id, receipt_id) DO UPDATE
        SET invoiced_amount = EXCLUDED.invoiced_amount,
            expected_amount = EXCLUDED.expected_amount;

        IF v_was_pending THEN
            -- Holes, not frozen numbers. Fill them the sanctioned way.
            PERFORM public.recost_pending_usage(rec_rec.receipt_id);
        ELSIF v_consumed > 0 AND abs(coalesce(v_new_unit,0) - v_old_unit) > 0 THEN
            INSERT INTO public.feed_price_variance
                  (receipt_id, invoice_id, consumed_lb,
                   old_cost_per_lb, new_cost_per_lb, variance_usd, notes, created_by)
            VALUES (rec_rec.receipt_id, p_invoice_id, v_consumed,
                    v_old_unit, coalesce(v_new_unit,0),
                    round(v_consumed * (coalesce(v_new_unit,0) - v_old_unit), 2),
                    'Invoice ' || v_invoice.invoice_number
                      || ' re-priced this load after ' || round(v_consumed)::text
                      || ' lb had already been fed. Frozen usage costs left alone.',
                    auth.uid());
        END IF;

        v_n := v_n + 1;
    END LOOP;

    RAISE NOTICE 'Invoice % matched to % load(s).', v_invoice.invoice_number, v_n;
END
$msi$;


-- ---------------------------------------------------------------------
-- 12. delete_supply_invoice - refuses once variance has been booked
-- ---------------------------------------------------------------------
-- Same posture as delete_feed_receipt refusing once pounds are consumed.
-- Unwinding a variance would leave the frozen usage costs sitting at the
-- invoice price while the layer went back to the ordered one - the books
-- would disagree with themselves. Correct it by matching again instead.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_supply_invoice(p_invoice_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $dsi$
DECLARE
    v_invoice public.supply_invoices%ROWTYPE;
    r         record;
BEGIN
    SELECT * INTO v_invoice FROM public.supply_invoices WHERE id = p_invoice_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invoice % not found.', p_invoice_id;
    END IF;

    IF EXISTS (SELECT 1 FROM public.feed_price_variance WHERE invoice_id = p_invoice_id) THEN
        RAISE EXCEPTION
          'Invoice % has already booked price variance on feed that was fed. It cannot be deleted - match it again with the right figures instead.',
          v_invoice.invoice_number;
    END IF;

    -- Reverse the adjustment this match applied. With no variance rows,
    -- nothing has been consumed at the new price, so this is clean.
    FOR r IN SELECT sir.receipt_id, sir.invoiced_amount, sir.expected_amount
             FROM public.supply_invoice_receipts sir
             WHERE sir.invoice_id = p_invoice_id
    LOOP
        UPDATE public.feed_receipts
        SET other_cost     = coalesce(other_cost, 0)
                             - (r.invoiced_amount - coalesce(r.expected_amount, 0)),
            cost_pending   = (r.expected_amount IS NULL),
            invoice_id     = NULL,
            invoice_number = NULL,
            price_source   = CASE WHEN r.expected_amount IS NULL THEN 'pending'
                                  WHEN order_line_id IS NOT NULL THEN 'ordered'
                                  ELSE 'manual' END,
            updated_at     = now()
        WHERE id = r.receipt_id;
    END LOOP;

    DELETE FROM public.supply_invoice_receipts WHERE invoice_id = p_invoice_id;
    DELETE FROM public.supply_invoices         WHERE id = p_invoice_id;
END
$dsi$;


-- ---------------------------------------------------------------------
-- 13. close_supply_order_line - "that's all they're bringing"
-- ---------------------------------------------------------------------
-- Matters more than it sounds. A line that never closes sits in "waiting
-- on delivery" forever and teaches everyone to ignore the list.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.close_supply_order_line(
    p_order_line_id uuid,
    p_reason        text DEFAULT 'closed short'
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $csl$
DECLARE n integer;
BEGIN
    UPDATE public.supply_order_lines
    SET closed_at = now(), close_reason = coalesce(nullif(btrim(p_reason),''), 'closed short')
    WHERE id = p_order_line_id AND closed_at IS NULL;
    GET DIAGNOSTICS n = ROW_COUNT;

    -- An RLS refusal returns zero rows and no error. Say so rather than
    -- reporting a save that changed nothing.
    IF n = 0 THEN
        RAISE EXCEPTION 'Order line % was not closed - it is already closed, or you do not have permission.',
              p_order_line_id;
    END IF;

    -- Close the order once nothing is outstanding on it.
    UPDATE public.supply_orders o
    SET status = 'closed'
    WHERE o.id = (SELECT order_id FROM public.supply_order_lines WHERE id = p_order_line_id)
      AND o.status = 'open'
      AND NOT EXISTS (SELECT 1 FROM public.supply_order_lines l
                      WHERE l.order_id = o.id AND l.closed_at IS NULL);
END
$csl$;

DO $fgrants$
DECLARE f text;
BEGIN
    FOREACH f IN ARRAY ARRAY[
        'record_feed_delivery(uuid,uuid,numeric,date,uuid,text,numeric,uuid,numeric,numeric,numeric,boolean,numeric,numeric,text)',
        'match_supply_invoice(uuid,jsonb)',
        'delete_supply_invoice(uuid)',
        'close_supply_order_line(uuid,text)'
    ] LOOP
        -- Postgres grants EXECUTE to PUBLIC by default, so revoking from
        -- anon alone silently does nothing.
        EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC', f);
        EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM anon', f);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
    END LOOP;
END
$fgrants$;


-- ---------------------------------------------------------------------
-- 14. Verify
-- ---------------------------------------------------------------------
DO $verify$
DECLARE
    t text; v text; n integer;
BEGIN
    FOREACH t IN ARRAY ARRAY['vendors','supply_orders','supply_order_lines',
                             'supply_invoices','supply_invoice_receipts',
                             'feed_price_variance'] LOOP
        -- ENABLE without policies is a total lockout; policies without
        -- ENABLE are decoration. Both halves, every table.
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

    FOREACH v IN ARRAY ARRAY['supply_order_line_status','supply_invoice_reconciliation',
                             'inventory_needs_attention'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace ns ON ns.oid=c.relnamespace
                       WHERE ns.nspname='public' AND c.relname=v
                         AND c.reloptions @> ARRAY['security_invoker=true']) THEN
            RAISE EXCEPTION 'public.% lacks security_invoker - it would bypass RLS.', v;
        END IF;
        IF has_table_privilege('anon', 'public.'||v, 'SELECT') THEN
            RAISE EXCEPTION 'anon can SELECT public.% view.', v;
        END IF;
    END LOOP;

    -- Every RPC here must be INVOKER. A SECURITY DEFINER one would run
    -- past the caller's RLS, and none of these has a reason to.
    FOR t IN SELECT p.proname FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
             WHERE ns.nspname='public'
               AND p.proname IN ('record_feed_delivery','match_supply_invoice',
                                 'delete_supply_invoice','close_supply_order_line')
               AND p.prosecdef
    LOOP
        RAISE EXCEPTION 'public.%() is SECURITY DEFINER and must not be.', t;
    END LOOP;

    SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
    WHERE ns.nspname='public' AND p.proname='record_feed_delivery';
    IF n <> 1 THEN
        RAISE EXCEPTION 'Expected exactly one record_feed_delivery, found %. PostgREST resolves an RPC by argument names and overloads make that ambiguous.', n;
    END IF;

    -- Still no price on the item. If this ever fails, someone added one
    -- and a year of closeouts is about to become editable.
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='feed_items'
                 AND column_name IN ('cost_per_lb','price','cost_per_ton','unit_cost')) THEN
        RAISE EXCEPTION 'feed_items has a price column. Price belongs on the receipt layer.';
    END IF;

    -- The opening balance must not be chased for paperwork it never had.
    SELECT count(*) INTO n FROM public.feed_receipts
    WHERE lower(btrim(coalesce(vendor,''))) = ANY (ARRAY['(opening balance)','beginning inventory'])
      AND source <> 'opening_balance';
    IF n > 0 THEN
        RAISE EXCEPTION '% opening-balance receipts are still source=purchase.', n;
    END IF;

    -- No bookkeeping marker may have become a vendor.
    SELECT count(*) INTO n FROM public.vendors
    WHERE lower(btrim(name)) = ANY (ARRAY['(opening balance)','(count adjustment)','beginning inventory']);
    IF n > 0 THEN
        RAISE EXCEPTION '% bookkeeping marker(s) were seeded into vendors.', n;
    END IF;

    SELECT count(*) INTO n FROM public.inventory_needs_attention;
    RAISE NOTICE 'Inventory flow wave 1: 6 tables, 3 views, 4 functions. RLS and grants verified.';
    RAISE NOTICE 'Needs-attention list currently has % row(s).', n;
END
$verify$;

commit;

-- =====================================================================
-- AFTER APPLYING
--
--   1. Run supabase/migrations/20260821000300_rls_verify.sql.
--   2. Sanity read:
--        select kind, severity, title, detail, age_days
--        from public.inventory_needs_attention order by sort_rank, age_days desc;
--      Expect FIVE rows, all of them correct:
--        Legacy Commodities DDG   8/17 - awaiting_invoice, unordered_load
--        Double T SoyHull Pellets 8/20 - awaiting_ticket, awaiting_invoice,
--                                        unordered_load
--      Those are two real purchases with real paperwork outstanding, which
--      is the whole point. A count_overdue or feed_unallocated row may also
--      appear off existing data. What must NOT appear is any of the 16
--      opening-balance layers.
--   3. select name from public.vendors order by name;  -- seeded list
-- =====================================================================
