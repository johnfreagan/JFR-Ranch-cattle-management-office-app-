-- =====================================================================
-- Lot transfers and mergers — schema, RLS, views and RPCs
-- =====================================================================
-- Design record with all fourteen decisions and the rejected alternatives:
--   docs/lot-transfers-design.md
-- Answers OPEN-ITEMS.md #9.
--
-- WHAT THIS IS FOR: 66 head sit on four lots that cannot be closed —
-- 47-26 has 3 of 187, 37X-1 has 10 of 274, 59X has 24 of 241, 60X has 29
-- of 251. Those cattle are physically running with other lots. Also the
-- occasional 10-20 head sorted to a lot that suits them better.
--
-- HEAD MATH IS ALREADY BUILT AND UNUSED. lot_events.event_type already
-- permits transfer_in / transfer_out, lot_status.head_current already adds
-- and subtracts them, and lot_daily_head already places them ON THEIR OWN
-- DATE — so a mid-life arrival eats grass only from the day it lands. This
-- migration writes the first such rows in the app's life.
--
-- WHY NOT A SALE OUT AND A RECEIPT IN, which OPEN-ITEMS #9 proposed as
-- "machinery that already exists":
--   * delivery_receipts carries receiving_protocol_id and processing cost
--     is DERIVED LIVE off receipts x protocol x current prices. An internal
--     receipt re-charges the receiving meds on cattle already processed.
--   * invoices feeds lot_daily_head's GREATEST(invoiced, received), so an
--     internal invoice inflates head_in.
--   * sales lands in realized ADG, the Accounting Report and
--     shipment_reconciliation, and reads as revenue with no cheque behind it.
-- The dollars therefore get their own table.
--
-- THE RPCs DO NOT COMPUTE THE BASIS. Cattle move at the source lot's actual
-- cost per head, which is the Closeout screen's own figure — processing,
-- treatment, feed, cost of gain, labour and interest blended per the
-- assumed_nonfeed_cog_per_day split. That lives in the app. Reimplementing
-- it here would be a SECOND COSTING PATH that drifts from the first, the
-- same mistake the premix design refused. The app computes it, passes it,
-- and this file stores it with its breakdown and guards it for sanity.
--
-- Apply in the Supabase SQL editor. Run
-- supabase/migrations/20260821000300_rls_verify.sql afterwards.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. The transfer itself
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lot_transfers (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transfer_date        DATE    NOT NULL,
    kind                 TEXT    NOT NULL
                             CHECK (kind IN ('fold_in','sort')),
    source_lot_id        UUID    NOT NULL REFERENCES public.lots(id),
    dest_lot_id          UUID    NOT NULL REFERENCES public.lots(id),
    head_count           INTEGER NOT NULL CHECK (head_count > 0),

    -- Decision 5: a weight always travels. Pre-filled from
    -- lot_projected_weight for the source lot, which is a LOT AVERAGE while
    -- a sort deliberately picks non-average cattle — hence the estimate flag.
    weight_per_head_lb   NUMERIC CHECK (weight_per_head_lb IS NULL OR weight_per_head_lb > 0),
    weight_is_estimate   BOOLEAN NOT NULL DEFAULT TRUE,

    -- Decision 2: at cost, frozen. basis_total is the money; basis_per_head
    -- is what it was divided from; basis_breakdown is for the drill-down.
    basis_per_head       NUMERIC NOT NULL CHECK (basis_per_head > 0),
    basis_total          NUMERIC NOT NULL CHECK (basis_total > 0),
    basis_breakdown      JSONB,
    basis_frozen_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    basis_recomputed_at  TIMESTAMPTZ,
    basis_prior_total    NUMERIC,

    -- Decision 4: tags are optional, and "not available" is an explicit
    -- decision recording who made it — the paperwork_done shape, not a note
    -- someone has to remember to write.
    tags_not_available   BOOLEAN NOT NULL DEFAULT FALSE,
    tags_marked_by       UUID,
    tags_marked_at       TIMESTAMPTZ,

    -- Decision 10: captured at transfer, because lots.fiscal_year could be
    -- corrected later and this record must keep saying which years the money
    -- actually moved between.
    source_fiscal_year   INTEGER,
    dest_fiscal_year     INTEGER,

    closed_source_lot    BOOLEAN NOT NULL DEFAULT FALSE,
    notes                TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           UUID,

    CONSTRAINT lot_transfers_distinct_lots CHECK (source_lot_id <> dest_lot_id)
);

COMMENT ON TABLE public.lot_transfers IS
    'Cattle moved between lots at the source lot''s actual cost per head, frozen. See docs/lot-transfers-design.md.';
COMMENT ON COLUMN public.lot_transfers.basis_total IS
    'The money. Frozen at transfer; only recompute_transfer_basis may move it, and it records the prior value.';
COMMENT ON COLUMN public.lot_transfers.tags_not_available IS
    'Explicit "stop asking" — John, 2026-09-01: tags generally will not be available except for a couple of head.';

-- ---------------------------------------------------------------------
-- 2. Pasture lines
-- ---------------------------------------------------------------------
-- 47-26's 3 head sit across 2 open assignments, so even the smallest
-- fold-in needs more than one line.
--
-- source_assignment_closed / dest_assignment_created record WHAT THE SAVE
-- ACTUALLY DID. delete_move_event has to infer the equivalent by comparing
-- head counts and dates, which is fragile; the reversal here reads what
-- happened instead of guessing.
CREATE TABLE IF NOT EXISTS public.lot_transfer_lines (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transfer_id              UUID    NOT NULL REFERENCES public.lot_transfers(id) ON DELETE CASCADE,
    from_pasture_id          UUID    NOT NULL REFERENCES public.pastures(id),
    to_pasture_id            UUID    NOT NULL REFERENCES public.pastures(id),
    head_count               INTEGER NOT NULL CHECK (head_count > 0),
    source_assignment_closed BOOLEAN NOT NULL DEFAULT FALSE,
    dest_assignment_created  BOOLEAN NOT NULL DEFAULT FALSE
);

-- ---------------------------------------------------------------------
-- 3. Tags, when they are known
-- ---------------------------------------------------------------------
-- prior_lot_id is what lot_tags said before, so a reversal puts it back.
-- had_tag_row distinguishes "repointed an existing row" from "created one",
-- because lot_tags is a PARTIAL registry: 37X carries 72 tag rows for 361
-- head in, so a named tag may have no row at all.
CREATE TABLE IF NOT EXISTS public.lot_transfer_tags (
    id           UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    transfer_id  UUID    NOT NULL REFERENCES public.lot_transfers(id) ON DELETE CASCADE,
    tag_number   INTEGER NOT NULL,
    prior_lot_id UUID,
    had_tag_row  BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE (transfer_id, tag_number)
);

CREATE INDEX IF NOT EXISTS lot_transfers_source_idx ON public.lot_transfers (source_lot_id);
CREATE INDEX IF NOT EXISTS lot_transfers_dest_idx   ON public.lot_transfers (dest_lot_id);
CREATE INDEX IF NOT EXISTS lot_transfers_date_idx   ON public.lot_transfers (transfer_date);
CREATE INDEX IF NOT EXISTS lot_transfer_lines_tx_idx ON public.lot_transfer_lines (transfer_id);
CREATE INDEX IF NOT EXISTS lot_transfer_tags_tx_idx  ON public.lot_transfer_tags (transfer_id);
CREATE INDEX IF NOT EXISTS lot_transfer_tags_num_idx ON public.lot_transfer_tags (tag_number);

-- ---------------------------------------------------------------------
-- 4. RLS — decision 8: office and owner write, owner deletes, books read
-- ---------------------------------------------------------------------
ALTER TABLE public.lot_transfers      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lot_transfer_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lot_transfer_tags  ENABLE ROW LEVEL SECURITY;

DO $pol$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['lot_transfers','lot_transfer_lines','lot_transfer_tags'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_select', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_insert', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_update', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_delete', t);

        -- can_read_books, not can_read_operational: a transfer carries a
        -- dollar basis, and crew cannot see dollars.
        EXECUTE format(
            'CREATE POLICY %I ON public.%I FOR SELECT USING (public.can_read_books())',
            t || '_select', t);
        EXECUTE format(
            'CREATE POLICY %I ON public.%I FOR INSERT WITH CHECK (public.current_user_role() = ANY (ARRAY[''owner'',''office'']))',
            t || '_insert', t);
        EXECUTE format(
            'CREATE POLICY %I ON public.%I FOR UPDATE USING (public.current_user_role() = ANY (ARRAY[''owner'',''office''])) WITH CHECK (public.current_user_role() = ANY (ARRAY[''owner'',''office'']))',
            t || '_update', t);
        EXECUTE format(
            'CREATE POLICY %I ON public.%I FOR DELETE USING (public.current_user_role() = ''owner'')',
            t || '_delete', t);

        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', t);
        EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    END LOOP;
END
$pol$;

-- ---------------------------------------------------------------------
-- 5. lot_transfer_costs — what Closeout adds
-- ---------------------------------------------------------------------
-- Decision 3: ONE LINE EACH SIDE, beside cattle cost. Decomposing the
-- basis back into cattle / processing / treatment / feed would corrupt two
-- denominators the app is careful about — processing $/hd is per head IN
-- and treatment $/hd is per LIVE head — by making the destination's rates
-- describe cattle that were never on that protocol.
--
-- Derived decision 1: lot_status.total_cost_in is NOT touched. It keeps
-- meaning "cattle purchase cost from invoices". Changing it would silently
-- move every consumer — breakeven, cost per head, avg_cost_per_head — and
-- several of those are read in places not yet audited.
DROP VIEW IF EXISTS public.lot_transfer_costs;
CREATE VIEW public.lot_transfer_costs
WITH (security_invoker = true) AS
SELECT
    s.lot_id,
    sum(s.in_head)::integer  AS transferred_in_head,
    sum(s.in_usd)            AS transferred_in_usd,
    sum(s.out_head)::integer AS transferred_out_head,
    sum(s.out_usd)           AS transferred_out_usd,
    sum(s.in_usd) - sum(s.out_usd) AS net_transfer_usd,
    max(s.last_transfer_date)      AS last_transfer_date
FROM (
    SELECT dest_lot_id AS lot_id, head_count AS in_head, basis_total AS in_usd,
           0 AS out_head, 0::numeric AS out_usd, transfer_date AS last_transfer_date
      FROM public.lot_transfers
    UNION ALL
    SELECT source_lot_id, 0, 0::numeric,
           head_count, basis_total, transfer_date
      FROM public.lot_transfers
) s
GROUP BY s.lot_id;

COMMENT ON VIEW public.lot_transfer_costs IS
    'Per lot, head and dollars transferred in and out. Closeout adds these as their own lines; lot_status.total_cost_in is deliberately unchanged.';

-- ---------------------------------------------------------------------
-- 6. lot_transfer_provenance — the drill-down
-- ---------------------------------------------------------------------
-- Clicking "Transferred in — 3 hd" has to answer "what ARE these cattle".
-- The protocol line matters most: those head got the SOURCE lot's receiving
-- meds, not the destination's, and a withdrawal clock travels with the
-- animal.
DROP VIEW IF EXISTS public.lot_transfer_provenance;
CREATE VIEW public.lot_transfer_provenance
WITH (security_invoker = true) AS
SELECT
    t.id AS transfer_id,
    t.transfer_date,
    t.kind,
    t.head_count,
    t.weight_per_head_lb,
    t.weight_is_estimate,
    t.basis_per_head,
    t.basis_total,
    t.basis_breakdown,
    t.basis_frozen_at,
    t.basis_recomputed_at,
    t.basis_prior_total,
    t.tags_not_available,
    t.closed_source_lot,
    t.notes,
    t.source_lot_id,
    sl.lot_number AS source_lot_number,
    t.source_fiscal_year,
    t.dest_lot_id,
    dl.lot_number AS dest_lot_number,
    t.dest_fiscal_year,
    (t.source_fiscal_year IS DISTINCT FROM t.dest_fiscal_year) AS crosses_fiscal_year,
    sl.receiving_protocol_id AS source_receiving_protocol_id,
    pr.name          AS source_protocol_name,
    pr.version_label AS source_protocol_version,
    sa.first_arrival AS source_lot_first_arrival,
    (t.transfer_date - sa.first_arrival) AS days_on_source_lot,
    (SELECT count(*) FROM public.lot_transfer_tags g WHERE g.transfer_id = t.id)::integer AS tags_named,
    -- Decision 4: outstanding means neither named nor explicitly waived.
    (NOT t.tags_not_available
     AND NOT EXISTS (SELECT 1 FROM public.lot_transfer_tags g WHERE g.transfer_id = t.id)) AS tags_outstanding,
    -- Decision 9: the basis was frozen from the source lot's live books, and
    -- feed goes in every Monday. This is true once feed COVERING the transfer
    -- date was posted AFTER the basis was frozen - the one bounded window in
    -- which an at-cost number can be light. It clears by recomputing, and in
    -- practice within a week.
    EXISTS (
        SELECT 1 FROM public.feed_usage fu
         WHERE fu.lot_id = t.source_lot_id
           AND fu.destination_type = 'lot'
           AND t.transfer_date BETWEEN COALESCE(fu.period_start, fu.usage_date)
                                   AND COALESCE(fu.period_end,   fu.usage_date)
           AND fu.created_at > COALESCE(t.basis_recomputed_at, t.basis_frozen_at)
    ) AS basis_stale
FROM public.lot_transfers t
JOIN public.lots sl ON sl.id = t.source_lot_id
JOIN public.lots dl ON dl.id = t.dest_lot_id
LEFT JOIN public.protocols pr ON pr.id = sl.receiving_protocol_id
LEFT JOIN LATERAL (
    SELECT LEAST(
        COALESCE((SELECT min(r.receipt_date) FROM public.delivery_receipts r WHERE r.lot_id = sl.id), DATE '9999-12-31'),
        COALESCE((SELECT min(i.invoice_date) FROM public.invoices        i WHERE i.lot_id = sl.id), DATE '9999-12-31')
    ) AS first_arrival
) sa ON TRUE;

COMMENT ON VIEW public.lot_transfer_provenance IS
    'One row per transfer with both lots, the source receiving protocol, days on the source lot and tag status. Backs the Closeout drill-down.';

REVOKE ALL ON public.lot_transfer_costs      FROM PUBLIC;
REVOKE ALL ON public.lot_transfer_costs      FROM anon;
REVOKE ALL ON public.lot_transfer_provenance FROM PUBLIC;
REVOKE ALL ON public.lot_transfer_provenance FROM anon;
GRANT SELECT ON public.lot_transfer_costs      TO authenticated;
GRANT SELECT ON public.lot_transfer_provenance TO authenticated;

-- ---------------------------------------------------------------------
-- 7. record_lot_transfer — the only way a transfer is created
-- ---------------------------------------------------------------------
-- INVOKER, like every other head-math RPC (record_death_with_pasture,
-- record_move_with_pasture, the delete reversals). It must NOT bypass RLS.
--
-- p_lines is [{from_pasture_id, to_pasture_id, head_count}, ...]. Head is
-- DERIVED from the lines rather than passed alongside them, so the shipment
-- trap — lines that do not sum to the stated head, money allocating anyway —
-- cannot happen here.
--
-- Source and destination assignments are updated on a PER-PASTURE AGGREGATE,
-- not per line. Two lines drawing the same source pasture would otherwise
-- have the first close it and the second find nothing open. Same aggregation
-- rule delete_shipment_with_reversal needed for the same reason.
CREATE OR REPLACE FUNCTION public.record_lot_transfer(
    p_source_lot_id      UUID,
    p_dest_lot_id        UUID,
    p_transfer_date      DATE,
    p_kind               TEXT,
    p_lines              JSONB,
    p_basis_per_head     NUMERIC,
    p_basis_total        NUMERIC,
    p_basis_breakdown    JSONB   DEFAULT NULL,
    p_weight_per_head_lb NUMERIC DEFAULT NULL,
    p_weight_is_estimate BOOLEAN DEFAULT TRUE,
    p_tags               INTEGER[] DEFAULT NULL,
    p_tags_not_available BOOLEAN DEFAULT FALSE,
    p_close_source_lot   BOOLEAN DEFAULT FALSE,
    p_notes              TEXT    DEFAULT NULL,
    p_recorded_by        UUID    DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    v_id            UUID;
    v_head          INTEGER;
    v_src_closed    TIMESTAMPTZ;
    v_dst_closed    TIMESTAMPTZ;
    v_src_fy        INTEGER;
    v_dst_fy        INTEGER;
    v_dst_first     DATE;
    v_tolerance     NUMERIC;
    v_assign        UUID;
    v_assign_head   INTEGER;
    v_line_id       UUID;
    v_head_current  INTEGER;
    v_tag           INTEGER;
    v_tag_row       UUID;
    v_clash         UUID;
    rec             RECORD;
BEGIN
    ---------------------------------------------------------------- lots
    IF p_source_lot_id IS NULL OR p_dest_lot_id IS NULL THEN
        RAISE EXCEPTION 'Both a source and a destination lot are required.';
    END IF;
    IF p_source_lot_id = p_dest_lot_id THEN
        RAISE EXCEPTION 'Source and destination lot are the same.';
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('fold_in','sort') THEN
        RAISE EXCEPTION 'Transfer kind must be fold_in or sort (got %).', p_kind;
    END IF;

    SELECT closed_at, fiscal_year INTO v_src_closed, v_src_fy
      FROM public.lots WHERE id = p_source_lot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source lot % not found.', p_source_lot_id;
    END IF;
    SELECT closed_at, fiscal_year INTO v_dst_closed, v_dst_fy
      FROM public.lots WHERE id = p_dest_lot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Destination lot % not found.', p_dest_lot_id;
    END IF;

    -- Derived decision 4: a closed lot cannot take cattle in. A closed
    -- SOURCE is equally wrong — it has no head to give.
    IF v_dst_closed IS NOT NULL THEN
        RAISE EXCEPTION 'Destination lot is closed. Reopen it before transferring cattle in.';
    END IF;
    IF v_src_closed IS NOT NULL THEN
        RAISE EXCEPTION 'Source lot is closed.';
    END IF;

    ---------------------------------------------------------------- date
    -- Decision 11. This floor is NOT a nicety. lot_daily_head clamps events
    -- into [first arrival, today]: a transfer_in dated before the
    -- destination's first receipt does not error, it is silently moved up to
    -- that lot's first day and the lot collects head-days for cattle that
    -- were not there. Feed, cost of gain and labour all charge against
    -- head-days, so the money follows the error.
    IF p_transfer_date IS NULL THEN
        RAISE EXCEPTION 'A transfer date is required.';
    END IF;
    IF p_transfer_date > public.ranch_today() THEN
        RAISE EXCEPTION 'Transfer date % is in the future (ranch today is %).',
            p_transfer_date, public.ranch_today();
    END IF;

    SELECT LEAST(
        COALESCE((SELECT min(r.receipt_date) FROM public.delivery_receipts r WHERE r.lot_id = p_dest_lot_id), DATE '9999-12-31'),
        COALESCE((SELECT min(i.invoice_date) FROM public.invoices        i WHERE i.lot_id = p_dest_lot_id), DATE '9999-12-31')
    ) INTO v_dst_first;

    IF v_dst_first = DATE '9999-12-31' THEN
        RAISE EXCEPTION 'Destination lot has no receipts or invoices, so it has no arrival date to measure against.';
    END IF;
    IF p_transfer_date < v_dst_first THEN
        RAISE EXCEPTION 'Transfer date % is before the destination lot existed (first arrival %). Head-days would be silently backdated to its first day.',
            p_transfer_date, v_dst_first;
    END IF;

    --------------------------------------------------------------- lines
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'At least one pasture line is required.';
    END IF;

    SELECT sum((e->>'head_count')::integer) INTO v_head
      FROM jsonb_array_elements(p_lines) e;
    IF v_head IS NULL OR v_head <= 0 THEN
        RAISE EXCEPTION 'Transfer head must be positive (got %).', v_head;
    END IF;

    -- Check every line individually. A line missing its head count would
    -- otherwise disappear into sum()'s NULL handling and the transfer would
    -- save for fewer head than were typed; a missing pasture would surface
    -- much further down as a NOT NULL violation nobody can read.
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_lines) e
         WHERE (e->>'head_count') IS NULL
            OR (e->>'head_count')::integer <= 0
            OR (e->>'from_pasture_id') IS NULL
            OR (e->>'to_pasture_id') IS NULL
    ) THEN
        RAISE EXCEPTION 'Every line needs a source pasture, a destination pasture and a positive head count.';
    END IF;

    --------------------------------------------------------------- basis
    -- Decision 2. The RPC stores the basis, it does not compute it: that is
    -- the Closeout screen's actual cost per head and reimplementing it here
    -- would be a second costing path. These are sanity guards only.
    IF p_basis_per_head IS NULL OR p_basis_per_head <= 0 THEN
        RAISE EXCEPTION 'A positive cost basis per head is required.';
    END IF;
    IF p_basis_per_head > 25000 THEN
        RAISE EXCEPTION 'Cost basis of %/head is implausible — check for a typo.', p_basis_per_head;
    END IF;
    v_tolerance := GREATEST(0.05, v_head * 0.01);
    IF abs(p_basis_total - (p_basis_per_head * v_head)) > v_tolerance THEN
        RAISE EXCEPTION 'Basis total % does not agree with % head at %/head.',
            p_basis_total, v_head, p_basis_per_head;
    END IF;

    ------------------------------------------------------------ availability
    -- Aggregate per source pasture BEFORE checking, so two lines drawing the
    -- same pasture are tested against their sum and not one at a time.
    FOR rec IN
        SELECT (e->>'from_pasture_id')::uuid AS fp, sum((e->>'head_count')::integer) AS hd
          FROM jsonb_array_elements(p_lines) e
         GROUP BY 1
    LOOP
        IF rec.fp IS NULL THEN
            RAISE EXCEPTION 'Every line needs a source pasture.';
        END IF;
        SELECT head_count INTO v_assign_head
          FROM public.lot_pasture_assignments
         WHERE lot_id = p_source_lot_id AND pasture_id = rec.fp AND moved_out IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'The source lot has no open assignment in one of the pastures named.';
        END IF;
        IF rec.hd > v_assign_head THEN
            RAISE EXCEPTION 'Cannot transfer % head out of a pasture holding %.', rec.hd, v_assign_head;
        END IF;
    END LOOP;

    ---------------------------------------------------------------- header
    INSERT INTO public.lot_transfers (
        transfer_date, kind, source_lot_id, dest_lot_id, head_count,
        weight_per_head_lb, weight_is_estimate,
        basis_per_head, basis_total, basis_breakdown,
        tags_not_available, tags_marked_by, tags_marked_at,
        source_fiscal_year, dest_fiscal_year,
        notes, created_by
    ) VALUES (
        p_transfer_date, p_kind, p_source_lot_id, p_dest_lot_id, v_head,
        p_weight_per_head_lb, COALESCE(p_weight_is_estimate, TRUE),
        p_basis_per_head, p_basis_total, p_basis_breakdown,
        COALESCE(p_tags_not_available, FALSE),
        CASE WHEN p_tags_not_available THEN p_recorded_by END,
        CASE WHEN p_tags_not_available THEN now() END,
        v_src_fy, v_dst_fy,
        p_notes, p_recorded_by
    ) RETURNING id INTO v_id;

    -- Collapse duplicate (from, to) pairs so the stored lines are canonical.
    INSERT INTO public.lot_transfer_lines (transfer_id, from_pasture_id, to_pasture_id, head_count)
    SELECT v_id, (e->>'from_pasture_id')::uuid, (e->>'to_pasture_id')::uuid,
           sum((e->>'head_count')::integer)
      FROM jsonb_array_elements(p_lines) e
     GROUP BY 2, 3;

    ------------------------------------------------------- source pastures
    FOR rec IN
        SELECT from_pasture_id AS fp, sum(head_count) AS hd
          FROM public.lot_transfer_lines WHERE transfer_id = v_id GROUP BY 1
    LOOP
        SELECT id, head_count INTO v_assign, v_assign_head
          FROM public.lot_pasture_assignments
         WHERE lot_id = p_source_lot_id AND pasture_id = rec.fp AND moved_out IS NULL;

        IF v_assign_head - rec.hd = 0 THEN
            -- Close it, leaving head_count intact. Setting it to zero would
            -- make the reversal restore nothing — the trap the shipment save
            -- fell into.
            UPDATE public.lot_pasture_assignments
               SET moved_out = p_transfer_date WHERE id = v_assign;

            SELECT id INTO v_line_id FROM public.lot_transfer_lines
             WHERE transfer_id = v_id AND from_pasture_id = rec.fp ORDER BY id LIMIT 1;
            UPDATE public.lot_transfer_lines SET source_assignment_closed = TRUE WHERE id = v_line_id;
        ELSE
            UPDATE public.lot_pasture_assignments
               SET head_count = v_assign_head - rec.hd WHERE id = v_assign;
        END IF;
    END LOOP;

    -------------------------------------------------------- dest pastures
    FOR rec IN
        SELECT to_pasture_id AS tp, sum(head_count) AS hd
          FROM public.lot_transfer_lines WHERE transfer_id = v_id GROUP BY 1
    LOOP
        SELECT id INTO v_assign
          FROM public.lot_pasture_assignments
         WHERE lot_id = p_dest_lot_id AND pasture_id = rec.tp AND moved_out IS NULL;

        IF v_assign IS NULL THEN
            INSERT INTO public.lot_pasture_assignments (
                lot_id, pasture_id, head_count, moved_in, notes, recorded_by
            ) VALUES (
                p_dest_lot_id, rec.tp, rec.hd, p_transfer_date,
                'Opened by lot transfer ' || v_id::text, p_recorded_by
            );
            SELECT id INTO v_line_id FROM public.lot_transfer_lines
             WHERE transfer_id = v_id AND to_pasture_id = rec.tp ORDER BY id LIMIT 1;
            UPDATE public.lot_transfer_lines SET dest_assignment_created = TRUE WHERE id = v_line_id;
        ELSE
            UPDATE public.lot_pasture_assignments
               SET head_count = head_count + rec.hd WHERE id = v_assign;
        END IF;
    END LOOP;

    ----------------------------------------------------------- head math
    -- These two rows are the whole head-math contribution. lot_status and
    -- lot_daily_head already know how to read them.
    INSERT INTO public.lot_events (lot_id, event_date, event_type, head_count, notes, source_record_id, created_by)
    VALUES (p_source_lot_id, p_transfer_date, 'transfer_out', v_head,
            'Transferred to lot ' || (SELECT lot_number FROM public.lots WHERE id = p_dest_lot_id),
            v_id, p_recorded_by);

    INSERT INTO public.lot_events (lot_id, event_date, event_type, head_count, notes, source_record_id, created_by)
    VALUES (p_dest_lot_id, p_transfer_date, 'transfer_in', v_head,
            'Transferred from lot ' || (SELECT lot_number FROM public.lots WHERE id = p_source_lot_id),
            v_id, p_recorded_by);

    ---------------------------------------------------------------- tags
    -- Decision 4. The tag row's fiscal_year is NOT changed when it is
    -- repointed: it records which year's tag run the ear tag physically
    -- belongs to, and tags RECYCLE across fiscal years. Moving it to the
    -- destination's year could collide with a live tag of the same number
    -- under uniq_lot_tags_active_tag_per_fiscal_year, or worse, succeed and
    -- point a FY2027 lookup at a FY2026 animal.
    IF p_tags IS NOT NULL THEN
        FOREACH v_tag IN ARRAY p_tags LOOP
            SELECT id INTO v_tag_row FROM public.lot_tags
             WHERE tag_number = v_tag AND lot_id = p_source_lot_id
             ORDER BY (status = 'active') DESC, registered_at DESC NULLS LAST LIMIT 1;

            IF v_tag_row IS NOT NULL THEN
                INSERT INTO public.lot_transfer_tags (transfer_id, tag_number, prior_lot_id, had_tag_row)
                VALUES (v_id, v_tag, p_source_lot_id, TRUE);
                UPDATE public.lot_tags SET lot_id = p_dest_lot_id, updated_at = now()
                 WHERE id = v_tag_row;
            ELSE
                -- lot_tags is a partial registry (37X carries 72 rows for 361
                -- head in), so a named tag may have no row. Create one under
                -- the SOURCE lot's fiscal year, which is the year the tag
                -- belongs to.
                SELECT id INTO v_clash FROM public.lot_tags
                 WHERE tag_number = v_tag AND fiscal_year = v_src_fy AND status = 'active';
                IF v_clash IS NOT NULL THEN
                    RAISE EXCEPTION 'Tag % is already active in FY% on another lot. Resolve that before transferring it.',
                        v_tag, v_src_fy;
                END IF;

                INSERT INTO public.lot_transfer_tags (transfer_id, tag_number, prior_lot_id, had_tag_row)
                VALUES (v_id, v_tag, NULL, FALSE);
                INSERT INTO public.lot_tags (tag_number, lot_id, fiscal_year, status, registered_by, notes)
                VALUES (v_tag, p_dest_lot_id, v_src_fy, 'active', p_recorded_by,
                        'Created by lot transfer ' || v_id::text);
            END IF;
        END LOOP;
    END IF;

    ------------------------------------------------------ close the source
    IF COALESCE(p_close_source_lot, FALSE) THEN
        -- lot_status is keyed on lot_id, not id. In SQL that throws honestly;
        -- in the app it returns undefined and does nothing.
        SELECT head_current INTO v_head_current
          FROM public.lot_status WHERE lot_id = p_source_lot_id;

        IF v_head_current IS NULL THEN
            RAISE EXCEPTION 'Could not read head_current for the source lot.';
        END IF;
        IF v_head_current <> 0 THEN
            RAISE EXCEPTION 'Source lot still holds % head; it cannot be closed.', v_head_current;
        END IF;

        UPDATE public.lots
           SET closed_at = p_transfer_date::timestamptz, updated_at = now()
         WHERE id = p_source_lot_id;
        UPDATE public.lot_transfers SET closed_source_lot = TRUE WHERE id = v_id;
    END IF;

    RETURN v_id;
END;
$fn$;

COMMENT ON FUNCTION public.record_lot_transfer IS
    'Move head and their frozen at-cost basis between lots, atomically. INVOKER. Head is derived from the pasture lines; assignments are updated per-pasture aggregate.';

-- ---------------------------------------------------------------------
-- 8. delete_lot_transfer — and it really does put the cattle back
-- ---------------------------------------------------------------------
-- THE delete_death_event TRAP, in transfer form: a transfer either
-- DECREMENTED a source assignment or CLOSED it, and those reverse
-- differently. Reopening (moved_out = NULL) already restores the count,
-- because closing leaves head_count intact; adding head on top of that
-- double-counts the herd. 3 head, a death of all 3, a reversal, and the lot
-- came back with 6 — that was live in August.
--
-- Both sides are aggregated per pasture before anything is touched, or a
-- pasture appearing on two lines reopens on the first and gains head on the
-- second.
CREATE OR REPLACE FUNCTION public.delete_lot_transfer(p_transfer_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    t             public.lot_transfers%ROWTYPE;
    v_assign      UUID;
    v_assign_head INTEGER;
    rec           RECORD;
    g             RECORD;
BEGIN
    SELECT * INTO t FROM public.lot_transfers WHERE id = p_transfer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transfer % not found.', p_transfer_id;
    END IF;

    -- Reopen the source lot first, so later steps are not fighting a closure.
    -- Closure is only closed_at, so this is complete.
    IF t.closed_source_lot THEN
        UPDATE public.lots SET closed_at = NULL, updated_at = now()
         WHERE id = t.source_lot_id;
    END IF;

    ------------------------------------------------- take head off the dest
    FOR rec IN
        SELECT to_pasture_id AS tp,
               sum(head_count) AS hd,
               bool_or(dest_assignment_created) AS created
          FROM public.lot_transfer_lines WHERE transfer_id = p_transfer_id GROUP BY 1
    LOOP
        SELECT id, head_count INTO v_assign, v_assign_head
          FROM public.lot_pasture_assignments
         WHERE lot_id = t.dest_lot_id AND pasture_id = rec.tp AND moved_out IS NULL;

        IF v_assign IS NULL THEN
            RAISE EXCEPTION 'Cannot reverse transfer %: no open assignment at a destination pasture.', p_transfer_id;
        END IF;
        IF v_assign_head < rec.hd THEN
            RAISE EXCEPTION 'Cannot reverse transfer %: a destination pasture holds % head, fewer than the % transferred in.',
                p_transfer_id, v_assign_head, rec.hd;
        END IF;

        -- Only remove the row when this transfer opened it AND nothing has
        -- been added since. Otherwise decrement, or later head is destroyed.
        IF rec.created AND v_assign_head = rec.hd THEN
            DELETE FROM public.lot_pasture_assignments WHERE id = v_assign;
        ELSE
            UPDATE public.lot_pasture_assignments
               SET head_count = v_assign_head - rec.hd WHERE id = v_assign;
        END IF;
    END LOOP;

    ---------------------------------------------- put head back at the source
    FOR rec IN
        SELECT from_pasture_id AS fp,
               sum(head_count) AS hd,
               bool_or(source_assignment_closed) AS closed
          FROM public.lot_transfer_lines WHERE transfer_id = p_transfer_id GROUP BY 1
    LOOP
        SELECT id, head_count INTO v_assign, v_assign_head
          FROM public.lot_pasture_assignments
         WHERE lot_id = t.source_lot_id AND pasture_id = rec.fp AND moved_out IS NULL;

        IF v_assign IS NOT NULL THEN
            -- Something reopened it in the meantime; just add the head.
            UPDATE public.lot_pasture_assignments
               SET head_count = v_assign_head + rec.hd WHERE id = v_assign;
        ELSIF rec.closed THEN
            SELECT id INTO v_assign
              FROM public.lot_pasture_assignments
             WHERE lot_id = t.source_lot_id AND pasture_id = rec.fp
               AND moved_out >= t.transfer_date
             ORDER BY moved_out ASC LIMIT 1;

            IF v_assign IS NULL THEN
                RAISE EXCEPTION 'Cannot reverse transfer %: the closed source assignment is gone.', p_transfer_id;
            END IF;

            -- Reopen with EXACTLY the head coming back, not the stored value
            -- plus it. head_count was left in place when the row was closed,
            -- so it is stale the moment moved_out is set.
            UPDATE public.lot_pasture_assignments
               SET moved_out = NULL, head_count = rec.hd WHERE id = v_assign;
        ELSE
            INSERT INTO public.lot_pasture_assignments (
                lot_id, pasture_id, head_count, moved_in, notes, recorded_by
            ) VALUES (
                t.source_lot_id, rec.fp, rec.hd, t.transfer_date,
                'Auto-created on transfer reversal', t.created_by
            );
        END IF;
    END LOOP;

    ---------------------------------------------------------------- tags
    FOR g IN SELECT * FROM public.lot_transfer_tags WHERE transfer_id = p_transfer_id LOOP
        IF g.had_tag_row THEN
            UPDATE public.lot_tags SET lot_id = g.prior_lot_id, updated_at = now()
             WHERE tag_number = g.tag_number AND lot_id = t.dest_lot_id;
        ELSE
            -- Remove only the row this transfer created.
            DELETE FROM public.lot_tags
             WHERE tag_number = g.tag_number AND lot_id = t.dest_lot_id
               AND notes = 'Created by lot transfer ' || p_transfer_id::text;
        END IF;
    END LOOP;

    ---------------------------------------------------------- head math off
    DELETE FROM public.lot_events
     WHERE source_record_id = p_transfer_id
       AND event_type IN ('transfer_in','transfer_out');

    DELETE FROM public.lot_transfers WHERE id = p_transfer_id;
    RETURN TRUE;
END;
$fn$;

COMMENT ON FUNCTION public.delete_lot_transfer IS
    'Reverse a lot transfer completely: cattle back, tags back, head events removed, source lot reopened. INVOKER; owner-only via the DELETE policy.';

-- ---------------------------------------------------------------------
-- 9. recompute_transfer_basis — decision 9
-- ---------------------------------------------------------------------
-- Feed is entered every Monday, so a basis frozen before the covering week
-- was posted is light for at most a week. This re-freezes at the ORIGINAL
-- transfer date from today's books and keeps the prior value.
--
-- NOT automatic. Recomputing on every source-lot cost change would be the
-- processing-cost failure with a longer fuse: two lots' books silently
-- rewritten with no audit trail.
--
-- Owner-only, checked here rather than by policy — the UPDATE policy admits
-- office, deliberately, because office edits tags and weight.
CREATE OR REPLACE FUNCTION public.recompute_transfer_basis(
    p_transfer_id     UUID,
    p_basis_per_head  NUMERIC,
    p_basis_total     NUMERIC,
    p_basis_breakdown JSONB DEFAULT NULL
) RETURNS NUMERIC
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    t           public.lot_transfers%ROWTYPE;
    v_tolerance NUMERIC;
BEGIN
    IF public.current_user_role() IS DISTINCT FROM 'owner' THEN
        RAISE EXCEPTION 'Only an owner may recompute a transfer cost basis.';
    END IF;

    SELECT * INTO t FROM public.lot_transfers WHERE id = p_transfer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transfer % not found.', p_transfer_id;
    END IF;

    IF p_basis_per_head IS NULL OR p_basis_per_head <= 0 OR p_basis_per_head > 25000 THEN
        RAISE EXCEPTION 'Cost basis of %/head is not plausible.', p_basis_per_head;
    END IF;
    v_tolerance := GREATEST(0.05, t.head_count * 0.01);
    IF abs(p_basis_total - (p_basis_per_head * t.head_count)) > v_tolerance THEN
        RAISE EXCEPTION 'Basis total % does not agree with % head at %/head.',
            p_basis_total, t.head_count, p_basis_per_head;
    END IF;

    UPDATE public.lot_transfers
       SET basis_prior_total   = COALESCE(basis_prior_total, basis_total),
           basis_per_head      = p_basis_per_head,
           basis_total         = p_basis_total,
           basis_breakdown     = COALESCE(p_basis_breakdown, basis_breakdown),
           basis_recomputed_at = now(),
           notes = COALESCE(notes || E'\n', '')
                   || 'Basis recomputed ' || to_char(now(), 'YYYY-MM-DD')
                   || ': was ' || t.basis_total::text || ', now ' || p_basis_total::text || '.'
     WHERE id = p_transfer_id;

    RETURN p_basis_total - t.basis_total;
END;
$fn$;

COMMENT ON FUNCTION public.recompute_transfer_basis IS
    'Owner-only. Re-freeze a transfer basis at its original date from today''s books, keeping the prior value. Returns the change.';

REVOKE ALL ON FUNCTION public.record_lot_transfer(UUID,UUID,DATE,TEXT,JSONB,NUMERIC,NUMERIC,JSONB,NUMERIC,BOOLEAN,INTEGER[],BOOLEAN,BOOLEAN,TEXT,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_lot_transfer(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.recompute_transfer_basis(UUID,NUMERIC,NUMERIC,JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_lot_transfer(UUID,UUID,DATE,TEXT,JSONB,NUMERIC,NUMERIC,JSONB,NUMERIC,BOOLEAN,INTEGER[],BOOLEAN,BOOLEAN,TEXT,UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_lot_transfer(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.recompute_transfer_basis(UUID,NUMERIC,NUMERIC,JSONB) TO authenticated;

-- ---------------------------------------------------------------------
-- 10. Verify
-- ---------------------------------------------------------------------
DO $verify$
DECLARE
    t TEXT;
    n INTEGER;
BEGIN
    -- Precondition: the head-math plumbing this whole module rides on.
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'public.lot_events'::regclass
           AND contype = 'c'
           AND pg_get_constraintdef(oid) LIKE '%transfer_in%'
           AND pg_get_constraintdef(oid) LIKE '%transfer_out%'
    ) THEN
        RAISE EXCEPTION 'lot_events does not permit transfer_in / transfer_out. Nothing here will work.';
    END IF;

    FOREACH t IN ARRAY ARRAY['lot_transfers','lot_transfer_lines','lot_transfer_tags'] LOOP
        IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.'||t)::regclass) THEN
            RAISE EXCEPTION 'RLS is not enabled on %.', t;
        END IF;
        SELECT count(*) INTO n FROM pg_policy WHERE polrelid = ('public.'||t)::regclass;
        IF n <> 4 THEN
            RAISE EXCEPTION '% should carry 4 policies, found %.', t, n;
        END IF;
        IF has_table_privilege('anon', 'public.'||t, 'SELECT') THEN
            RAISE EXCEPTION 'anon can read %. Revoke it.', t;
        END IF;
    END LOOP;

    -- Rule 3: a view without security_invoker runs as its owner and ignores RLS.
    FOREACH t IN ARRAY ARRAY['lot_transfer_costs','lot_transfer_provenance'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = t AND relkind = 'v'
                         AND reloptions @> ARRAY['security_invoker=true']) THEN
            RAISE EXCEPTION '% is missing security_invoker = true.', t;
        END IF;
    END LOOP;

    -- Rule 6: head-math RPCs are INVOKER and must stay that way.
    SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'public'
       AND p.proname IN ('record_lot_transfer','delete_lot_transfer','recompute_transfer_basis')
       AND p.prosecdef;
    IF n <> 0 THEN
        RAISE EXCEPTION '% of the transfer RPCs are SECURITY DEFINER. They must be INVOKER.', n;
    END IF;

    -- PostgREST resolves an RPC by argument names; two overloads make that
    -- ambiguous. post_feed_usage had to be DROPped and recreated over this.
    FOREACH t IN ARRAY ARRAY['record_lot_transfer','delete_lot_transfer','recompute_transfer_basis'] LOOP
        SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
         WHERE ns.nspname = 'public' AND p.proname = t;
        IF n <> 1 THEN
            RAISE EXCEPTION 'Expected exactly one %, found %.', t, n;
        END IF;
    END LOOP;

    RAISE NOTICE 'Lot transfers installed. lot_transfers / _lines / _tags, two views, three INVOKER RPCs. No transfers recorded yet.';
END
$verify$;

commit;
