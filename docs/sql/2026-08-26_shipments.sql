-- =====================================================================
-- Sales revamp, phase 1: the buyer's write-up becomes a first-class record
-- =====================================================================
-- 2026-08-26.
--
-- WHAT THIS IS FOR
--
-- Thigpen (and every other order buyer) settles a shipment on one sheet:
-- one date, one destination, a list of TRUCKLOADS grouped into weight
-- classes, one price per cwt against a single pay weight, and a draft
-- amount after checkoff. The 2026-08-21 sheet is the worked example
-- throughout this file:
--
--   group 1   5 loads   298 hd   251,500 gross   2% shrink   246,470 pay   827 avg
--   group 2   4 loads   251 hd   203,800 gross   2% shrink   199,724 pay   796 avg
--   total     9 loads   549 hd   455,300 gross   9,106 shrink 446,194 pay   813 avg
--
--   446,194 lb x $320.00/cwt = $1,427,820.80
--     less National beef checkoff  549 hd x $1.00 =   $549.00
--     less Texas beef checkoff     549 hd x $1.00 =   $549.00
--   amount of draft                                = $1,426,722.80
--
-- Nothing in the schema could hold any of that. `sales` is one row per lot,
-- entered from that lot's detail page, and it has no idea other lots went
-- on the same trucks under the same price. So a nine-load, multi-lot
-- shipment had to be typed as N disconnected sales with the dollars split
-- by hand, and nothing afterwards could prove the split added back up.
--
-- WHY A WRAPPER AND NOT A REWRITE OF `sales`
--
-- The honest model is "one sale = one check", which would move lot_id off
-- `sales` and onto the lines. That rewrite touches closeout, realized ADG,
-- the lot activity timeline, every delete/reversal path and the test-lot
-- cleanup - against live books, for no gain the wrapper does not also give.
-- So `shipments` sits ABOVE `sales`: the write-up is stored once, the app
-- allocates it down, and each lot still gets an ordinary `sales` row.
-- Everything downstream keeps working without knowing shipments exist.
--
-- WHY WEIGHT GROUPS
--
-- The two groups above are not a formatting quirk, they are two different
-- kinds of cattle - 827 lb and 796 lb - that happened to sell at one price.
-- Allocating one blended 813 lb average across every line would book the
-- heavy cattle light and the light cattle heavy, and it would do it
-- silently, in the numbers closeout grades the lot on. A line therefore
-- carries the group it actually rode in, weight is allocated WITHIN the
-- group, and the groups still sum to the shipment. Exact at both levels.
--
-- WHY THE DRAFT AMOUNT IS THE REVENUE
--
-- `net_amount` is what hits the books (John, 2026-08-26). Checkoff is $2/hd
-- every single time and is not optional, so netting it makes realized $/hd
-- match the deposit. `gross_amount` and the individual deductions are kept
-- so the sheet reconciles line for line.
--
-- WHY FREIGHT IS A TOGGLE
--
-- The 8-21 sheet shows 585 mi x $5.25 x 9 loads = $27,641.25 and does NOT
-- deduct it - that buyer paid it. Another deal will not. The miles, rate
-- and load count are always recorded so the sheet reconciles; whether the
-- money is JFR's is `jfr_pays_freight`, per shipment. At $50/hd on this
-- load, guessing wrong is not a rounding error.
--
-- HEAD MATH IS UNTOUCHED
--
-- No trigger here moves cattle. Head math still happens exactly where it
-- happens today, when the app writes the per-lot `sales` rows and decrements
-- lot_pasture_assignments. This file only adds the paperwork above it.
--
-- Idempotent: safe to run repeatedly.
-- Run supabase/migrations/20260821000300_rls_verify.sql afterwards.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Preconditions. Fail loudly rather than half-applying.
-- ---------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regclass('public.sales') IS NULL
       OR to_regclass('public.sale_sources') IS NULL
       OR to_regclass('public.lots') IS NULL
       OR to_regclass('public.pastures') IS NULL THEN
        RAISE EXCEPTION 'Expected tables sales, sale_sources, lots, pastures are missing. Refusing to proceed.';
    END IF;

    IF NOT EXISTS (
           SELECT 1 FROM pg_proc p
           JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname = 'current_user_role'
       ) THEN
        RAISE EXCEPTION 'public.current_user_role() is missing. Every policy below depends on it.';
    END IF;

    -- to_regclass resolves views and sequences too. Anything we are about to
    -- ALTER TABLE must actually be a table, or the ALTER aborts the whole
    -- migration and silently leaves everything after it unapplied.
    IF (SELECT relkind FROM pg_class WHERE oid = to_regclass('public.sales')) <> 'r' THEN
        RAISE EXCEPTION 'public.sales is not an ordinary table (relkind %). Refusing to ALTER it.',
            (SELECT relkind FROM pg_class WHERE oid = to_regclass('public.sales'));
    END IF;
    IF (SELECT relkind FROM pg_class WHERE oid = to_regclass('public.sale_sources')) <> 'r' THEN
        RAISE EXCEPTION 'public.sale_sources is not an ordinary table (relkind %). Refusing to ALTER it.',
            (SELECT relkind FROM pg_class WHERE oid = to_regclass('public.sale_sources'));
    END IF;
END
$pre$;

-- ---------------------------------------------------------------------
-- 1. shipments - one buyer write-up
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.shipments (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- The sheet's own identity, so a paper sheet can be found from the app
    -- and vice versa.
    sale_date               date        NOT NULL,
    buyer                   text,
    contract_number         text,       -- Thigpen: "Contract No. 8-21-26"
    account_number          text,       -- Thigpen: "#08-0068-26"
    origin                  text,       -- "Brought from: Marlin"
    destination             text,       -- "Destination: Cimarron"
    po_number               text,       -- "PO 3776"
    sex_class               text,       -- "strs"
    sale_invoice_number     text,

    -- Weights. gross -> shrink -> pay weight, the way the buyer writes it.
    -- pay_weight_lb is the one that is actually paid on and is required;
    -- gross and shrink are the provenance and may be absent on a sheet
    -- that only quotes a pay weight.
    head_count              integer     NOT NULL CHECK (head_count > 0),
    gross_weight_lb         numeric     CHECK (gross_weight_lb > 0),
    shrink_pct              numeric     CHECK (shrink_pct >= 0 AND shrink_pct < 100),
    pay_weight_lb           numeric     NOT NULL CHECK (pay_weight_lb > 0),

    -- Money.
    price_per_cwt           numeric     CHECK (price_per_cwt > 0),
    gross_amount            numeric     NOT NULL CHECK (gross_amount >= 0),
    deduction_total         numeric     NOT NULL DEFAULT 0 CHECK (deduction_total >= 0),
    net_amount              numeric     NOT NULL CHECK (net_amount >= 0),

    -- Freight. Recorded always; charged to the books only when the toggle
    -- says the freight was ours.
    freight_miles           numeric     CHECK (freight_miles >= 0),
    freight_rate_per_mile   numeric     CHECK (freight_rate_per_mile >= 0),
    freight_loads           integer     CHECK (freight_loads >= 0),
    freight_total           numeric     CHECK (freight_total >= 0),
    jfr_pays_freight        boolean     NOT NULL DEFAULT false,

    notes                   text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid        REFERENCES auth.users(id),

    -- The draft has to be the gross less the deductions. A cent of tolerance
    -- for numeric rounding; anything larger is a typo worth stopping on.
    CONSTRAINT shipments_draft_ties
        CHECK (abs(net_amount - (gross_amount - deduction_total)) < 0.01)
);

COMMENT ON TABLE public.shipments IS
    'One buyer settlement sheet. Allocated down to per-lot rows in public.sales. net_amount (amount of draft, after checkoff) is the revenue that hits the books.';
COMMENT ON COLUMN public.shipments.net_amount IS
    'Amount of draft - gross_amount less deduction_total. THIS is sale revenue, not gross_amount.';
COMMENT ON COLUMN public.shipments.jfr_pays_freight IS
    'False = the buyer paid the freight and it never touches our books; the miles/rate/loads are kept only so the sheet reconciles.';

-- ---------------------------------------------------------------------
-- 2. shipment_weight_groups - the buyer's weight classes
-- ---------------------------------------------------------------------
-- A shipment always has at least one. A sheet quoting a single blended
-- weight is just the one-group case, so the allocator never needs a
-- special path for it.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.shipment_weight_groups (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_id         uuid        NOT NULL REFERENCES public.shipments(id) ON DELETE CASCADE,
    group_label         text        NOT NULL,
    sort_order          integer     NOT NULL DEFAULT 0,

    head_count          integer     NOT NULL CHECK (head_count > 0),
    gross_weight_lb     numeric     CHECK (gross_weight_lb > 0),
    shrink_pct          numeric     CHECK (shrink_pct >= 0 AND shrink_pct < 100),
    pay_weight_lb       numeric     NOT NULL CHECK (pay_weight_lb > 0),

    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT shipment_weight_groups_label_uq UNIQUE (shipment_id, group_label)
);

CREATE INDEX IF NOT EXISTS shipment_weight_groups_shipment_idx
    ON public.shipment_weight_groups (shipment_id, sort_order);

COMMENT ON TABLE public.shipment_weight_groups IS
    'A weight class within one settlement sheet, e.g. 298 hd at 827 lb avg. Line weights are allocated within the group, never across the whole shipment.';

-- ---------------------------------------------------------------------
-- 3. shipment_loads - the individual truckloads
-- ---------------------------------------------------------------------
-- Pure provenance: the app sums these and checks them against the group,
-- which is the difference between catching a transposed weight at entry
-- and finding it in closeout six months later. Optional - a group may be
-- typed as a single head/gross total with no loads behind it.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.shipment_loads (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_id         uuid        NOT NULL REFERENCES public.shipments(id) ON DELETE CASCADE,
    weight_group_id     uuid        REFERENCES public.shipment_weight_groups(id) ON DELETE CASCADE,
    load_seq            integer     NOT NULL,
    head_count          integer     NOT NULL CHECK (head_count > 0),
    gross_weight_lb     numeric     NOT NULL CHECK (gross_weight_lb > 0),
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT shipment_loads_seq_uq UNIQUE (shipment_id, load_seq)
);

CREATE INDEX IF NOT EXISTS shipment_loads_group_idx
    ON public.shipment_loads (weight_group_id);

COMMENT ON TABLE public.shipment_loads IS
    'One truckload off the buyer sheet. Reconciliation only - no money and no head math depend on these rows.';

-- ---------------------------------------------------------------------
-- 4. shipment_deductions - checkoff and anything else off the draft
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.shipment_deductions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_id     uuid        NOT NULL REFERENCES public.shipments(id) ON DELETE CASCADE,
    label           text        NOT NULL,     -- 'National beef checkoff'
    basis           text        NOT NULL CHECK (basis IN ('per_head', 'flat')),
    rate            numeric     CHECK (rate >= 0),   -- 1.00 when basis = per_head
    amount          numeric     NOT NULL CHECK (amount >= 0),
    sort_order      integer     NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),

    -- A per_head deduction without a rate cannot be re-derived or checked.
    CONSTRAINT shipment_deductions_rate_present
        CHECK (basis <> 'per_head' OR rate IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS shipment_deductions_shipment_idx
    ON public.shipment_deductions (shipment_id, sort_order);

COMMENT ON TABLE public.shipment_deductions IS
    'Deductions between the gross amount and the draft. Beef checkoff is per_head at $1.00 national + $1.00 Texas.';

-- ---------------------------------------------------------------------
-- 5. Link sales and sale_sources up to the shipment
-- ---------------------------------------------------------------------
-- Both columns are NULLABLE on purpose: every sale recorded before today
-- was entered one lot at a time and has no shipment, and the single-lot
-- entry path stays exactly as it is.
--
-- ON DELETE RESTRICT on sales.shipment_id: deleting a shipment must not
-- quietly orphan posted sales, because deleting a sale does NOT restore
-- cattle to pastures. Unwind the sales deliberately, then the shipment.
-- ---------------------------------------------------------------------
ALTER TABLE public.sales
    ADD COLUMN IF NOT EXISTS shipment_id uuid REFERENCES public.shipments(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS sales_shipment_idx ON public.sales (shipment_id);

-- ---------------------------------------------------------------------
-- 5a. book_proceeds - what the books get, as opposed to what the draft says
-- ---------------------------------------------------------------------
-- net_amount is the draft, and it has to stay the draft or the sheet stops
-- reconciling to the paper. But when the freight was ours it is a real cost
-- of selling these exact cattle, in the same way checkoff is, and the buyer
-- simply never wrote it on his sheet.
--
-- So the two questions get two columns. net_amount answers "does this match
-- the paper". book_proceeds answers "what did we actually clear", and it is
-- book_proceeds that gets allocated down to the lots. On the 8-21 sheet the
-- toggle is off and they are the same number; flip it on and they differ by
-- $27,641.25, which is $50/hd of realized margin.
-- ---------------------------------------------------------------------
ALTER TABLE public.shipments
    ADD COLUMN IF NOT EXISTS book_proceeds numeric
    GENERATED ALWAYS AS (
        net_amount - CASE WHEN jfr_pays_freight THEN COALESCE(freight_total, 0) ELSE 0 END
    ) STORED;

COMMENT ON COLUMN public.shipments.book_proceeds IS
    'net_amount less freight when jfr_pays_freight. This - not net_amount - is what is allocated to lots and what closeout should read.';



-- The allocated share of the sheet, written down per (lot, pasture) line so
-- the arithmetic is auditable after the fact rather than re-derived.
ALTER TABLE public.sale_sources
    ADD COLUMN IF NOT EXISTS weight_group_id uuid REFERENCES public.shipment_weight_groups(id) ON DELETE SET NULL;
ALTER TABLE public.sale_sources
    ADD COLUMN IF NOT EXISTS pay_weight_lb numeric;
ALTER TABLE public.sale_sources
    ADD COLUMN IF NOT EXISTS gross_amount numeric;
ALTER TABLE public.sale_sources
    ADD COLUMN IF NOT EXISTS net_amount numeric;

CREATE INDEX IF NOT EXISTS sale_sources_weight_group_idx
    ON public.sale_sources (weight_group_id);

COMMENT ON COLUMN public.sale_sources.pay_weight_lb IS
    'This line''s allocated share of its weight group''s pay weight. Sums exactly to the group, and the groups sum exactly to the shipment.';
COMMENT ON COLUMN public.sale_sources.net_amount IS
    'This line''s allocated share of the draft. Allocated on pay weight; the per-head deductions are allocated on head.';

-- ---------------------------------------------------------------------
-- 6. updated_at trigger for shipments
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.shipments_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $fn$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS shipments_touch_updated_at ON public.shipments;
CREATE TRIGGER shipments_touch_updated_at
    BEFORE UPDATE ON public.shipments
    FOR EACH ROW EXECUTE FUNCTION public.shipments_touch_updated_at();

-- ---------------------------------------------------------------------
-- 7. RLS
-- ---------------------------------------------------------------------
-- Money-bearing paperwork: office + owner only, on SELECT as well as write.
-- DELETE is owner-only, matching the rule that the destructive privilege is
-- the narrow one - a shipment's child sales have already moved cattle.
--
-- ENABLE without policies is a lockout and policies without ENABLE are
-- decoration, so both happen here for every table.
-- ---------------------------------------------------------------------
ALTER TABLE public.shipments              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shipment_weight_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shipment_loads         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shipment_deductions    ENABLE ROW LEVEL SECURITY;

-- shipments
DROP POLICY IF EXISTS shipments_select ON public.shipments;
DROP POLICY IF EXISTS shipments_insert ON public.shipments;
DROP POLICY IF EXISTS shipments_update ON public.shipments;
DROP POLICY IF EXISTS shipments_delete ON public.shipments;

CREATE POLICY shipments_select ON public.shipments
    FOR SELECT TO authenticated
    USING (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipments_insert ON public.shipments
    FOR INSERT TO authenticated
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipments_update ON public.shipments
    FOR UPDATE TO authenticated
    USING (public.current_user_role() = ANY (ARRAY['owner','office']))
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipments_delete ON public.shipments
    FOR DELETE TO authenticated
    USING (public.current_user_role() = 'owner');

-- shipment_weight_groups
DROP POLICY IF EXISTS shipment_weight_groups_select ON public.shipment_weight_groups;
DROP POLICY IF EXISTS shipment_weight_groups_insert ON public.shipment_weight_groups;
DROP POLICY IF EXISTS shipment_weight_groups_update ON public.shipment_weight_groups;
DROP POLICY IF EXISTS shipment_weight_groups_delete ON public.shipment_weight_groups;

CREATE POLICY shipment_weight_groups_select ON public.shipment_weight_groups
    FOR SELECT TO authenticated
    USING (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipment_weight_groups_insert ON public.shipment_weight_groups
    FOR INSERT TO authenticated
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipment_weight_groups_update ON public.shipment_weight_groups
    FOR UPDATE TO authenticated
    USING (public.current_user_role() = ANY (ARRAY['owner','office']))
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipment_weight_groups_delete ON public.shipment_weight_groups
    FOR DELETE TO authenticated
    USING (public.current_user_role() = 'owner');

-- shipment_loads
DROP POLICY IF EXISTS shipment_loads_select ON public.shipment_loads;
DROP POLICY IF EXISTS shipment_loads_insert ON public.shipment_loads;
DROP POLICY IF EXISTS shipment_loads_update ON public.shipment_loads;
DROP POLICY IF EXISTS shipment_loads_delete ON public.shipment_loads;

CREATE POLICY shipment_loads_select ON public.shipment_loads
    FOR SELECT TO authenticated
    USING (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipment_loads_insert ON public.shipment_loads
    FOR INSERT TO authenticated
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipment_loads_update ON public.shipment_loads
    FOR UPDATE TO authenticated
    USING (public.current_user_role() = ANY (ARRAY['owner','office']))
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipment_loads_delete ON public.shipment_loads
    FOR DELETE TO authenticated
    USING (public.current_user_role() = 'owner');

-- shipment_deductions
DROP POLICY IF EXISTS shipment_deductions_select ON public.shipment_deductions;
DROP POLICY IF EXISTS shipment_deductions_insert ON public.shipment_deductions;
DROP POLICY IF EXISTS shipment_deductions_update ON public.shipment_deductions;
DROP POLICY IF EXISTS shipment_deductions_delete ON public.shipment_deductions;

CREATE POLICY shipment_deductions_select ON public.shipment_deductions
    FOR SELECT TO authenticated
    USING (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipment_deductions_insert ON public.shipment_deductions
    FOR INSERT TO authenticated
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipment_deductions_update ON public.shipment_deductions
    FOR UPDATE TO authenticated
    USING (public.current_user_role() = ANY (ARRAY['owner','office']))
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office']));

CREATE POLICY shipment_deductions_delete ON public.shipment_deductions
    FOR DELETE TO authenticated
    USING (public.current_user_role() = 'owner');

-- Grants: authenticated only, never anon. Revoke from PUBLIC rather than
-- from anon alone - anon inherits PUBLIC, so revoking anon by itself does
-- nothing whatsoever.

REVOKE ALL ON public.shipments FROM PUBLIC;
REVOKE ALL ON public.shipments FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shipments TO authenticated;

REVOKE ALL ON public.shipment_weight_groups FROM PUBLIC;
REVOKE ALL ON public.shipment_weight_groups FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shipment_weight_groups TO authenticated;

REVOKE ALL ON public.shipment_loads FROM PUBLIC;
REVOKE ALL ON public.shipment_loads FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shipment_loads TO authenticated;

REVOKE ALL ON public.shipment_deductions FROM PUBLIC;
REVOKE ALL ON public.shipment_deductions FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shipment_deductions TO authenticated;

-- ---------------------------------------------------------------------
-- 8. shipment_reconciliation - does the allocation still add up?
-- ---------------------------------------------------------------------
-- The allocator gets this right at save time. This view answers the
-- different question: is it STILL right, after however many later edits to
-- a sale or a source row. Anything with a non-zero variance here means the
-- sheet and the books have drifted apart.
--
-- security_invoker: without it the view runs as its owner and bypasses RLS
-- entirely, regardless of the policies above.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.shipment_reconciliation
WITH (security_invoker = true) AS
SELECT
    s.id                                        AS shipment_id,
    s.sale_date,
    s.buyer,
    s.head_count                                AS sheet_head,
    s.pay_weight_lb                             AS sheet_pay_weight_lb,
    s.net_amount                                AS sheet_net_amount,
    s.book_proceeds                             AS sheet_book_proceeds,
    COALESCE(alloc.head_count, 0)               AS allocated_head,
    COALESCE(alloc.pay_weight_lb, 0)            AS allocated_pay_weight_lb,
    COALESCE(alloc.net_amount, 0)               AS allocated_net_amount,
    s.head_count    - COALESCE(alloc.head_count, 0)     AS head_variance,
    s.pay_weight_lb - COALESCE(alloc.pay_weight_lb, 0)  AS pay_weight_variance,
    s.book_proceeds - COALESCE(alloc.net_amount, 0)     AS net_amount_variance,
    COALESCE(alloc.line_count, 0)               AS line_count,
    COALESCE(alloc.lot_count, 0)                AS lot_count
FROM public.shipments s
LEFT JOIN (
    SELECT
        sa.shipment_id,
        SUM(ss.head_count)          AS head_count,
        SUM(ss.pay_weight_lb)       AS pay_weight_lb,
        SUM(ss.net_amount)          AS net_amount,
        COUNT(*)                    AS line_count,
        COUNT(DISTINCT sa.lot_id)   AS lot_count
    FROM public.sale_sources ss
    JOIN public.sales sa ON sa.id = ss.sale_id
    WHERE sa.shipment_id IS NOT NULL
    GROUP BY sa.shipment_id
) alloc ON alloc.shipment_id = s.id;

COMMENT ON VIEW public.shipment_reconciliation IS
    'Buyer sheet totals vs the sum of what was allocated to lots. Any non-zero variance means the sheet and the books have drifted.';

REVOKE ALL ON public.shipment_reconciliation FROM PUBLIC;
REVOKE ALL ON public.shipment_reconciliation FROM anon;
GRANT SELECT ON public.shipment_reconciliation TO authenticated;

-- ---------------------------------------------------------------------
-- 9. Verify
-- ---------------------------------------------------------------------
DO $verify$
DECLARE
    tbl_name  text;
    pol_count integer;
BEGIN
    FOREACH tbl_name IN ARRAY ARRAY[
        'shipments', 'shipment_weight_groups', 'shipment_loads', 'shipment_deductions'
    ]
    LOOP
        IF to_regclass('public.' || tbl_name) IS NULL THEN
            RAISE EXCEPTION 'Table public.% was not created.', tbl_name;
        END IF;

        IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.' || tbl_name)) THEN
            RAISE EXCEPTION 'RLS is not enabled on public.% - policies without ENABLE are decoration.', tbl_name;
        END IF;

        SELECT count(*) INTO pol_count
        FROM pg_policies
        WHERE schemaname = 'public' AND tablename = tbl_name;

        IF pol_count <> 4 THEN
            RAISE EXCEPTION 'public.% has % policies, expected 4.', tbl_name, pol_count;
        END IF;

        -- information_schema lies about grants on hosted Supabase; ask the
        -- privilege functions directly.
        IF has_table_privilege('anon', 'public.' || tbl_name, 'SELECT') THEN
            RAISE EXCEPTION 'anon can SELECT public.% - the publishable key makes that fully public.', tbl_name;
        END IF;
    END LOOP;

    IF to_regclass('public.shipment_reconciliation') IS NULL THEN
        RAISE EXCEPTION 'View public.shipment_reconciliation was not created.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_class c
        WHERE c.oid = to_regclass('public.shipment_reconciliation')
          AND c.reloptions @> ARRAY['security_invoker=true']
    ) THEN
        RAISE EXCEPTION 'shipment_reconciliation lacks security_invoker - it would run as owner and bypass RLS.';
    END IF;

    IF has_table_privilege('anon', 'public.shipment_reconciliation', 'SELECT') THEN
        RAISE EXCEPTION 'anon can SELECT shipment_reconciliation.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'sales' AND column_name = 'shipment_id'
    ) THEN
        RAISE EXCEPTION 'sales.shipment_id was not added.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'shipments' AND column_name = 'book_proceeds'
    ) THEN
        RAISE EXCEPTION 'shipments.book_proceeds was not added.';
    END IF;

    IF (SELECT count(*) FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'sale_sources'
          AND column_name IN ('weight_group_id', 'pay_weight_lb', 'gross_amount', 'net_amount')) <> 4 THEN
        RAISE EXCEPTION 'sale_sources is missing one or more allocation columns.';
    END IF;

    RAISE NOTICE 'shipments migration applied: 4 tables, 16 policies, 1 view, 6 new columns.';
END
$verify$;

COMMIT;
