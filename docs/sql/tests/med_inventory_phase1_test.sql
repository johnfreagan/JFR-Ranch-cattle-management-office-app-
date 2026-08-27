-- =====================================================================
-- Medicine inventory phase 1 - self-checking test
-- =====================================================================
-- Run against a THROWAWAY postgres, never the live project. It creates a
-- stub of the live schema (just enough of medications, lots, receipts and
-- doctoring for the migration and its views to compile), applies nothing
-- itself, and asserts on behaviour.
--
--   initdb -U postgres -A trust -D /tmp/pgtest
--   pg_ctl -D /tmp/pgtest -o '-p 5439 -k /tmp' start
--   psql -h /tmp -p 5439 -U postgres -f docs/sql/tests/med_inventory_phase1_test.sql
--   psql -h /tmp -p 5439 -U postgres -f docs/sql/2026-08-27_med_inventory_phase1.sql
--   psql -h /tmp -p 5439 -U postgres -f docs/sql/tests/med_inventory_phase1_assert.sql
--
-- This file is part 1 (fixture). The assertions are in _assert.sql so the
-- migration can be applied in between exactly as it will be in the SQL
-- editor.
-- =====================================================================

CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE SCHEMA IF NOT EXISTS auth;

CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE
AS $$ SELECT '00000000-0000-0000-0000-0000000000aa'::uuid $$;

CREATE OR REPLACE FUNCTION public.ranch_today() RETURNS date LANGUAGE sql STABLE
AS $$ SELECT (now() AT TIME ZONE 'America/Chicago')::date $$;

CREATE OR REPLACE FUNCTION public.current_user_role() RETURNS text LANGUAGE sql STABLE
AS $$ SELECT 'owner'::text $$;

CREATE TABLE public.medications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, generic_category text NOT NULL,
  dose_mode text DEFAULT 'flat', flat_dose_amount numeric, per_weight_rate numeric,
  per_weight_basis numeric DEFAULT 100, per_weight_unit text, round_up_to numeric DEFAULT 1,
  bottle_size numeric, bottle_size_unit text, bottle_cost numeric, cost_per_unit numeric,
  cost_per_head numeric, is_active boolean NOT NULL DEFAULT true);

CREATE TABLE public.lots (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lot_number text, source text, is_test boolean DEFAULT false);
CREATE TABLE public.invoices (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lot_id uuid, head_count int, total_weight_lb numeric);
CREATE TABLE public.protocols (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text);
CREATE TABLE public.protocol_meds (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  protocol_id uuid, medication_id uuid, override_dose_mode text, override_flat_dose numeric,
  override_per_weight_rate numeric, override_per_weight_basis numeric);
CREATE TABLE public.delivery_receipts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lot_id uuid NOT NULL, receipt_date date NOT NULL, head_count int NOT NULL,
  receiving_protocol_id uuid, invoice_id uuid);
CREATE TABLE public.doctoring_events (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_datetime timestamptz DEFAULT now(), recorded_by_user_id uuid);
CREATE TABLE public.doctoring_event_meds (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  doctoring_event_id uuid, position smallint DEFAULT 1, medication_id uuid,
  dose_cc numeric, cost numeric);

INSERT INTO public.medications (id, name, generic_category, dose_mode, per_weight_rate, bottle_size, bottle_size_unit, cost_per_unit)
VALUES ('11111111-0000-0000-0000-000000000001','Draxxin','Antibiotic','per_weight',1.1,500,'mL',0.99262),
       ('11111111-0000-0000-0000-000000000002','Valcor','Anthelmintic (Dewormer)','per_weight',2.0,500,'mL',0.30142);
INSERT INTO public.medications (id, name, generic_category, dose_mode, flat_dose_amount, bottle_size, bottle_size_unit, cost_per_unit)
VALUES ('11111111-0000-0000-0000-000000000003','Ultrachoice 8','Clostridial Vaccine','flat',1,250,'doses',0.75948);
-- Deliberately unpriced: proves the count refuses to invent a cost basis.
INSERT INTO public.medications (id, name, generic_category, dose_mode, flat_dose_amount)
VALUES ('11111111-0000-0000-0000-000000000004','Protivity','Mycoplasma Vaccine','flat',1);
