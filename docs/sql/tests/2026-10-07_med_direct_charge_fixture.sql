-- Fixture for 2026-10-07_med_direct_charge.sql. Runs AFTER
-- 2026-10-01_med_inventory_fixture.sql and 2026-10-01_med_inventory.sql,
-- whose med_consume / med_reverse_txn / med_locked_through bodies match the
-- live ones (md5(prosrc) checked 2026-10-07). Adds what the direct-charge
-- migration reads that the base fixture does not stub, with column names and
-- types copied from the live information_schema, and the two views exactly
-- as they stand live before the migration (pg_get_viewdef, 2026-10-07).

ALTER TABLE public.lots ADD COLUMN IF NOT EXISTS closed_at timestamptz;

CREATE TABLE IF NOT EXISTS public.field_actions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    category text
);
ALTER TABLE public.doctoring_events ADD COLUMN IF NOT EXISTS field_action_id uuid REFERENCES public.field_actions(id);

CREATE TABLE IF NOT EXISTS public.cost_centers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    redwing_account text,
    redwing_production_center text,
    profit_center text,
    notes text,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.field_actions, public.cost_centers TO authenticated;

-- Live definitions before the migration.
CREATE OR REPLACE VIEW public.lot_med_costs_by_category WITH (security_invoker = true) AS
 SELECT de.lot_id,
    COALESCE(fa.category, 'treatment'::text) AS category,
    sum(dem.cost) AS total_cost,
    count(DISTINCT de.id) AS event_count,
    count(dem.id) AS med_row_count,
    count(dem.id) FILTER (WHERE dem.cost IS NULL) AS unpriced_row_count
   FROM doctoring_event_meds dem
     JOIN doctoring_events de ON de.id = dem.doctoring_event_id
     LEFT JOIN field_actions fa ON fa.id = de.field_action_id
  GROUP BY de.lot_id, (COALESCE(fa.category, 'treatment'::text));

CREATE OR REPLACE VIEW public.med_usage_by_lot WITH (security_invoker = true) AS
 SELECT t.id AS txn_id,
    t.txn_date,
    t.fiscal_year,
    COALESCE(dr.lot_id, de.lot_id) AS lot_id,
    l.lot_number,
    t.ref_kind,
        CASE t.ref_kind
            WHEN 'delivery_receipt'::text THEN 'processing'::text
            WHEN 'doctoring_event'::text THEN 'treatment'::text
            ELSE COALESCE(t.reason, 'other'::text)
        END AS category,
    t.medication_id,
    m.name AS medication_name,
    m.generic_category,
    m.redwing_item_code,
    COALESCE(m.bottle_size_unit, 'mL'::text) AS unit,
    m.bottle_size,
    t.qty_units,
    t.total_cost,
    t.shortfall_units,
    t.cost_provisional,
    t.location_id,
    loc.name AS location_name
   FROM med_txns t
     JOIN medications m ON m.id = t.medication_id
     LEFT JOIN med_stock_locations loc ON loc.id = t.location_id
     LEFT JOIN delivery_receipts dr ON t.ref_kind = 'delivery_receipt'::text AND dr.id = t.ref_id
     LEFT JOIN doctoring_events de ON t.ref_kind = 'doctoring_event'::text AND de.id = t.ref_id
     LEFT JOIN lots l ON l.id = COALESCE(dr.lot_id, de.lot_id)
  WHERE t.direction = '-1'::integer AND t.txn_type = 'usage'::text;

ALTER TABLE public.medications ADD COLUMN IF NOT EXISTS redwing_item_code text;

REVOKE ALL ON public.lot_med_costs_by_category, public.med_usage_by_lot FROM anon;
GRANT SELECT ON public.lot_med_costs_by_category, public.med_usage_by_lot TO authenticated;

-- ---- Seed: two lots with doctoring history, one closed lot, a cost centre,
-- ---- an inactive one, a shelf that is live and stocked.
INSERT INTO public.lots (id, lot_number, closed_at) VALUES
  ('a0000000-0000-0000-0000-000000000001', '60X', NULL),
  ('a0000000-0000-0000-0000-000000000002', '61X', NULL),
  ('a0000000-0000-0000-0000-000000000003', '50X', '2026-09-01');

INSERT INTO public.field_actions (id, name, category) VALUES
  ('f0000000-0000-0000-0000-000000000001', 'Pull and treat', 'treatment'),
  ('f0000000-0000-0000-0000-000000000002', 'Reprocess', 'processing');

INSERT INTO public.medications (id, name, generic_category, withdrawal_days, bottle_size, bottle_size_unit, bottle_cost, redwing_item_code) VALUES
  ('b0000000-0000-0000-0000-000000000001', 'Cydectin Pour-On', 'dewormer', 49, 5000, 'mL', 500, 'RW-CYD'),
  ('b0000000-0000-0000-0000-000000000002', 'Draxxin',          'antibiotic', 18, 500, 'mL', 1000, 'RW-DRX'),
  ('b0000000-0000-0000-0000-000000000003', 'Mystery Drench',   'dewormer', 0, NULL, 'mL', NULL, NULL);

INSERT INTO public.doctoring_events (id, lot_id, event_date, field_action_id) VALUES
  ('d0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', '2026-09-10', 'f0000000-0000-0000-0000-000000000001'),
  ('d0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', '2026-09-11', 'f0000000-0000-0000-0000-000000000002'),
  ('d0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002', '2026-09-12', NULL);
INSERT INTO public.doctoring_event_meds (doctoring_event_id, position, medication_id, dose_cc, cost) VALUES
  ('d0000000-0000-0000-0000-000000000001', 1, 'b0000000-0000-0000-0000-000000000002', 10, 20.00),
  ('d0000000-0000-0000-0000-000000000001', 2, 'b0000000-0000-0000-0000-000000000002', 5, NULL),
  ('d0000000-0000-0000-0000-000000000002', 1, 'b0000000-0000-0000-0000-000000000002', 7, 14.00),
  ('d0000000-0000-0000-0000-000000000003', 1, 'b0000000-0000-0000-0000-000000000002', 3, 6.00);

INSERT INTO public.cost_centers (id, name, profit_center, redwing_production_center, is_active) VALUES
  ('c0000000-0000-0000-0000-000000000001', 'Cow/Calf Wip', NULL, NULL, true),
  ('c0000000-0000-0000-0000-000000000002', 'Bulls', 'PC-20', 'BULLS', true),
  ('c0000000-0000-0000-0000-000000000003', 'Old Horses', NULL, NULL, false);

-- A shelf that is live and stocked. Two Cydectin layers at different costs
-- so a charge across both proves FIFO; Draxxin enough to run short.
INSERT INTO public.med_stock_locations (id, name, kind, is_test, usage_from) VALUES
  ('e0000000-0000-0000-0000-000000000001', 'Charge Barn', 'ranch', false, '2026-10-01'),
  ('e0000000-0000-0000-0000-000000000002', 'Not Live',    'ranch', false, NULL);
INSERT INTO public.med_purchase_lines
  (id, medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
VALUES
  ('90000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001', 1, 5000, 'mL', 0.10, 5000, '2026-10-01'),
  ('90000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001', 1, 5000, 'mL', 0.12, 5000, '2026-10-02'),
  ('90000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 1, 500,  'mL', 2.00, 500,  '2026-10-01');

-- Usage that already exists before the migration, on its own shelf so the
-- charge tests' layer arithmetic is untouched: a doctoring dose and a
-- reference-less usage row (category falls back to its reason).
INSERT INTO public.med_stock_locations (id, name, kind, is_test, usage_from) VALUES
  ('e0000000-0000-0000-0000-000000000003', 'Old Usage Barn', 'ranch', false, '2026-10-01');
INSERT INTO public.med_purchase_lines
  (id, medication_id, location_id, qty_bottles, bottle_size, unit, unit_cost, qty_remaining, received_date)
VALUES
  ('90000000-0000-0000-0000-000000000004', 'b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000003', 1, 500, 'mL', 2.00, 500, '2026-10-01');
SELECT public.med_consume('b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000003', 10,
       'usage', 'treatment', 'doctoring_event', 'd0000000-0000-0000-0000-000000000001', '2026-10-02');
SELECT public.med_consume('b0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000003', 4,
       'usage', 'spilled', NULL, NULL, '2026-10-02');

-- What the lot cost view says BEFORE the migration, to prove afterwards
-- that a lot with no charge reads exactly as it did.
CREATE SCHEMA IF NOT EXISTS test;
GRANT USAGE ON SCHEMA test TO authenticated;
CREATE TABLE test.lot_med_before AS SELECT * FROM public.lot_med_costs_by_category;
CREATE TABLE test.usage_before AS SELECT * FROM public.med_usage_by_lot;
GRANT SELECT ON ALL TABLES IN SCHEMA test TO authenticated;
