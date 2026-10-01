-- Throwaway fixture: the smallest stub of the live schema that the med
-- inventory migration touches. Column names/types copied from the live
-- information_schema on 2026-10-01.

DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='office_user') THEN CREATE ROLE office_user LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='crew_user') THEN CREATE ROLE crew_user LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='acct_user') THEN CREATE ROLE acct_user LOGIN; END IF;
END $$;
GRANT authenticated TO office_user, crew_user, acct_user;
GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- Supabase ships these, and they are NOT a detail: a function created in
-- `public` arrives EXECUTE-able by anon and by every logged-in user before a
-- migration has said anything about it. Without them here a throwaway
-- Postgres passes grant assertions that the live database fails -- which is
-- exactly what happened on 2026-10-01 with the two med trigger functions.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON FUNCTIONS TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON TABLES TO anon, authenticated;

-- Supabase's auth schema. The RPCs stamp created_by = auth.uid(); without
-- this stub they parse at CREATE time and fail on the first call.
CREATE SCHEMA IF NOT EXISTS auth;
GRANT USAGE ON SCHEMA auth TO anon, authenticated;
CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $fn$
    SELECT nullif(current_setting('test.uid', true), '')::uuid;
$fn$;

-- Role gate stub: reads a session GUC instead of auth.uid(), so the test
-- can switch roles. Same contract: NULL for unknown, and every policy
-- written so NULL denies.
CREATE FUNCTION public.current_user_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
    SELECT nullif(current_setting('test.role', true), '');
$fn$;

CREATE FUNCTION public.can_read_operational() RETURNS boolean
LANGUAGE sql STABLE SET search_path = public AS $fn$
    SELECT coalesce(public.current_user_role() = any (array['owner','office','crew','accountant']), false);
$fn$;

CREATE FUNCTION public.can_read_books() RETURNS boolean
LANGUAGE sql STABLE SET search_path = public AS $fn$
    SELECT coalesce(public.current_user_role() = any (array['owner','office','accountant']), false);
$fn$;

-- The ranch is UTC-6/-5; the DB runs UTC. Overridable so a test can pin
-- "today" instead of racing the clock.
CREATE FUNCTION public.ranch_today() RETURNS date
LANGUAGE sql STABLE SET search_path = public AS $fn$
    SELECT coalesce(
        nullif(current_setting('test.today', true), '')::date,
        (now() AT TIME ZONE 'America/Chicago')::date
    );
$fn$;

REVOKE ALL ON FUNCTION public.current_user_role() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_read_operational() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_read_books() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ranch_today() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_read_operational() TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_read_books() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ranch_today() TO authenticated;

CREATE TABLE public.lots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lot_number text NOT NULL,
    arrival_date date NOT NULL DEFAULT '2026-07-01',
    fiscal_year integer NOT NULL DEFAULT 2027,
    source text,
    notes text,
    is_test boolean NOT NULL DEFAULT false,
    receiving_protocol_id uuid
);

CREATE TABLE public.medications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    generic_category text NOT NULL,
    withdrawal_days integer NOT NULL DEFAULT 0,
    cost_per_head numeric,
    is_active boolean NOT NULL DEFAULT true,
    notes text,
    dose_mode text DEFAULT 'flat',
    flat_dose_amount numeric,
    per_weight_rate numeric,
    per_weight_basis numeric DEFAULT 100,
    per_weight_unit text,
    round_up_to numeric DEFAULT 1,
    bottle_size numeric,
    bottle_size_unit text,
    bottle_cost numeric,
    cost_per_unit numeric
);

CREATE TABLE public.protocols (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL
);

CREATE TABLE public.protocol_meds (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    protocol_id uuid NOT NULL REFERENCES public.protocols(id),
    medication_id uuid NOT NULL REFERENCES public.medications(id),
    sort_order integer NOT NULL DEFAULT 0,
    override_dose_mode text,
    override_flat_dose numeric,
    override_per_weight_rate numeric,
    override_per_weight_basis numeric
);

CREATE TABLE public.invoices (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lot_id uuid NOT NULL REFERENCES public.lots(id),
    invoice_date date NOT NULL DEFAULT '2026-07-01',
    head_count integer NOT NULL,
    total_weight_lb numeric NOT NULL,
    total_cost numeric NOT NULL DEFAULT 0
);

CREATE TABLE public.delivery_receipts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lot_id uuid NOT NULL REFERENCES public.lots(id),
    receipt_date date NOT NULL,
    head_count integer NOT NULL,
    receiving_protocol_id uuid REFERENCES public.protocols(id),
    invoice_id uuid REFERENCES public.invoices(id),
    notes text
);

CREATE TABLE public.doctoring_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lot_id uuid NOT NULL REFERENCES public.lots(id),
    event_date date NOT NULL
);

CREATE TABLE public.doctoring_event_meds (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    doctoring_event_id uuid NOT NULL REFERENCES public.doctoring_events(id),
    position smallint NOT NULL,
    medication_id uuid REFERENCES public.medications(id),
    medication_name_freetext text,
    dose_cc numeric,
    cost numeric
);

CREATE TABLE public.pending_field_entries (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_type text NOT NULL,
    client_id text NOT NULL,
    raw jsonb NOT NULL DEFAULT '{}'::jsonb,
    lot_id uuid,
    event_datetime timestamptz,
    head_count integer,
    resolved_meds jsonb NOT NULL DEFAULT '[]'::jsonb,
    status text NOT NULL DEFAULT 'pending',
    submitted_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.feed_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL
);

CREATE TABLE public.supply_orders (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_date date NOT NULL DEFAULT public.ranch_today(),
    status text NOT NULL DEFAULT 'open'
);

-- The spine, as 2026-08-31_inventory_flow.sql built it.
CREATE TABLE public.supply_order_lines (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL REFERENCES public.supply_orders(id) ON DELETE CASCADE,
    item_kind text NOT NULL CHECK (item_kind IN ('feed','med')),
    feed_item_id uuid REFERENCES public.feed_items(id) ON DELETE RESTRICT,
    medication_id uuid REFERENCES public.medications(id) ON DELETE RESTRICT,
    destination_location_id uuid,
    qty_purchase_units numeric,
    purchase_unit text,
    price_per_purchase_unit numeric,
    price_unknown boolean NOT NULL DEFAULT false,
    closed_at timestamptz,
    close_reason text,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT supply_order_lines_one_item_ck CHECK (
        (item_kind = 'feed' AND feed_item_id IS NOT NULL AND medication_id IS NULL)
     OR (item_kind = 'med'  AND medication_id IS NOT NULL AND feed_item_id IS NULL)
    ),
    -- The live table carries this one too, and it matters here: it mentions
    -- item_kind without mentioning 'med', so an assertion that takes the
    -- FIRST item_kind CHECK it finds can draw this and wrongly conclude the
    -- spine rejects meds. Keeping it in the fixture is what makes that
    -- mistake reproducible outside production.
    CONSTRAINT supply_order_lines_dest_ck CHECK (
        item_kind = 'feed' OR destination_location_id IS NULL
    )
);

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
