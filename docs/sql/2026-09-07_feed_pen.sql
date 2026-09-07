-- =====================================================================
-- The feed pen — cripples and chronics, moved out at $0, salvaged
-- =====================================================================
-- Design record with every decision and the rejected alternatives:
--   docs/feed-pen-design.md
--
-- WHAT THIS IS FOR: cattle with little value left — cripples, chronics —
-- leave their lot at a ZERO basis, leaving every dollar of cost behind on
-- the lot that took them in. They then accrue feed and a little medicine
-- in the pen and nothing else, and leave it sold, butchered, dead or
-- simply gone. The pen keeps its own books; what each SOURCE LOT's pen
-- cattle cost is frozen at removal and TRACKED, never posted back to a
-- lot that is very likely already closed by then (John, 2026-09-07).
--
-- THE ONE CHANGE THAT REACHES EXISTING BOOKS is section 2 —
-- lot_daily_head gains a third start-date term. It is a no-op for every
-- lot on the place, and section 2 PROVES that before applying it rather
-- than assuming it.
--
-- Idempotent. Paste into the SQL editor without the begin/commit lines
-- (the editor swallows them and reports success without applying).
-- Run supabase/migrations/20260821000300_rls_verify.sql afterwards.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. The pen is a lot
-- ---------------------------------------------------------------------
-- Decision 1. Everything the pen needs — head on hand, head-days, feed
-- spread over those head-days, doctoring with its cost frozen, which pen
-- they stand in — is already implemented once, keyed on lot_id. A cost
-- centre is deliberately the ABSENCE of a lot (lot_feed_daily and
-- feed_cost_unallocated read destination_type = 'lot' only), so it can
-- hold no head, no deaths and no sales. A bespoke animal table would be
-- a second head-math and a second costing path, and this app has been
-- bitten by exactly that shape twice.
ALTER TABLE public.lots
    ADD COLUMN IF NOT EXISTS is_feed_pen BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.lots.is_feed_pen IS
    'Feed pen: cripples and chronics transferred in at a $0 basis. Accrues feed and medicine only — no cost of gain, labor, interest, death loss or budget. See docs/feed-pen-design.md.';

-- Decision 3: one pen per fiscal year, John's call. A perpetual pen never
-- closes, so its net never lands anywhere, and lots.fiscal_year is NOT
-- NULL and derived from arrival — a perpetual pen would carry one year's
-- label while spending four years' money.
CREATE UNIQUE INDEX IF NOT EXISTS lots_one_feed_pen_per_fy
    ON public.lots (fiscal_year) WHERE is_feed_pen;

-- ---------------------------------------------------------------------
-- 2. lot_daily_head learns a third start date
-- ---------------------------------------------------------------------
-- Decision 11, and the only change here that touches live books.
--
-- lot_daily_head bounds each lot by LEAST(first receipt, first invoice).
-- A pen lot has NEITHER — it only ever receives transfers — so its
-- start_date comes back 9999-12-31, it is dropped from the `live` CTE,
-- and it therefore has NO ROWS AT ALL. No head-days means lot_feed_daily
-- can spread nothing to it and every pound of pen feed lands in
-- feed_cost_unallocated instead.
--
-- The bound gains the lot's first transfer_in. For an ordinary lot that
-- term can never win: record_lot_transfer already REFUSES a transfer
-- dated before the destination's first arrival (transfer design decision
-- 11, written for this exact clamping behaviour). Prove it rather than
-- assume it — if this raises, the view change is NOT a no-op and some
-- lot's head-days, and every feed / cost-of-gain / labor dollar charged
-- against them, would move.
DO $chk$
DECLARE
    v_bad INTEGER;
    v_lot TEXT;
BEGIN
    SELECT count(*), min(l.lot_number)
      INTO v_bad, v_lot
      FROM public.lots l
      CROSS JOIN LATERAL (
          SELECT min(e.event_date) AS first_xfer_in
            FROM public.lot_events e
           WHERE e.lot_id = l.id AND e.event_type = 'transfer_in'
      ) x
      CROSS JOIN LATERAL (
          SELECT LEAST(
              COALESCE((SELECT min(r.receipt_date) FROM public.delivery_receipts r WHERE r.lot_id = l.id), DATE '9999-12-31'),
              COALESCE((SELECT min(i.invoice_date)  FROM public.invoices        i WHERE i.lot_id = l.id), DATE '9999-12-31')
          ) AS first_arrival
      ) a
     WHERE x.first_xfer_in IS NOT NULL
       AND x.first_xfer_in < a.first_arrival;

    IF v_bad > 0 THEN
        RAISE EXCEPTION 'Refusing to widen lot_daily_head: % lot(s), first %, already carry a transfer_in dated before their first arrival. Widening the bound would MOVE their head-days and every dollar charged against them. Investigate those lots first.',
            v_bad, v_lot;
    END IF;
    RAISE NOTICE 'lot_daily_head widening verified as a no-op for existing lots.';
END
$chk$;

-- CREATE OR REPLACE, deliberately, NOT drop-and-create. The column list
-- and types are unchanged, so replace works — and a DROP ... CASCADE here
-- would take lot_feed_daily, lot_feed_costs, feed_cost_unallocated,
-- lot_head_days_by_month, pasture_feed_allocation and the feed truck
-- tie-outs with it, to be rebuilt by hand from memory. Replace also
-- preserves the security_invoker reloption, which a rebuild could drop
-- silently (rule 3 of the access-control section).
CREATE OR REPLACE VIEW public.lot_daily_head AS
WITH bounds AS (
    SELECT l.id AS lot_id,
        LEAST(
            COALESCE((SELECT min(r.receipt_date) FROM delivery_receipts r WHERE r.lot_id = l.id), '9999-12-31'::date),
            COALESCE((SELECT min(i.invoice_date)  FROM invoices        i WHERE i.lot_id = l.id), '9999-12-31'::date),
            -- The feed pen's only arrival. Provably a no-op above for
            -- every lot that arrives the ordinary way.
            COALESCE((SELECT min(e.event_date) FROM lot_events e
                       WHERE e.lot_id = l.id AND e.event_type = 'transfer_in'), '9999-12-31'::date)
        ) AS start_date,
        LEAST(COALESCE(l.closed_at::date, ranch_today()), ranch_today()) AS end_date
      FROM lots l
), live AS (
    SELECT bounds.lot_id, bounds.start_date, bounds.end_date
      FROM bounds
     WHERE bounds.start_date < '9999-12-31'::date AND bounds.end_date >= bounds.start_date
), raw_events AS (
    SELECT i.lot_id, i.invoice_date AS d, i.head_count AS inv_in, 0 AS rcpt_in, 0 AS delta
      FROM invoices i
    UNION ALL
    SELECT r.lot_id, r.receipt_date, 0, r.head_count, 0
      FROM delivery_receipts r
    UNION ALL
    SELECT e.lot_id, e.event_date, 0, 0,
        CASE e.event_type
            WHEN 'death'::text        THEN -abs(e.head_count)
            WHEN 'sold'::text         THEN -abs(e.head_count)
            WHEN 'transfer_out'::text THEN -abs(e.head_count)
            WHEN 'transfer_in'::text  THEN  abs(e.head_count)
            WHEN 'adjustment'::text   THEN  e.head_count
            ELSE 0
        END AS "case"
      FROM lot_events e
    UNION ALL
    SELECT s.lot_id, s.sale_date, 0, 0, -s.head_count
      FROM sales s
), clamped AS (
    SELECT v.lot_id,
        LEAST(GREATEST(re.d, v.start_date), v.end_date) AS d,
        sum(re.inv_in) AS inv_in,
        sum(re.rcpt_in) AS rcpt_in,
        sum(re.delta) AS delta
      FROM raw_events re
      JOIN live v ON v.lot_id = re.lot_id
     WHERE re.d IS NOT NULL
     GROUP BY v.lot_id, (LEAST(GREATEST(re.d, v.start_date), v.end_date))
), days AS (
    SELECT v.lot_id, gs.gs::date AS as_of_date
      FROM live v
      CROSS JOIN LATERAL generate_series(v.start_date::timestamp without time zone,
                                         v.end_date::timestamp without time zone,
                                         '1 day'::interval) gs(gs)
)
SELECT d.lot_id,
    d.as_of_date,
    GREATEST(0::numeric,
        GREATEST(sum(COALESCE(c.inv_in, 0::bigint)) OVER w,
                 sum(COALESCE(c.rcpt_in, 0::bigint)) OVER w)
        + sum(COALESCE(c.delta, 0::bigint)) OVER w)::integer AS head_on_hand
  FROM days d
  LEFT JOIN clamped c ON c.lot_id = d.lot_id AND c.d = d.as_of_date
 WINDOW w AS (PARTITION BY d.lot_id ORDER BY d.as_of_date ROWS UNBOUNDED PRECEDING);

COMMENT ON VIEW public.lot_daily_head IS
    'Head on hand per lot per day. Bounded by first receipt, first invoice OR first transfer_in — the third term is how a feed pen, which has no receipts, gets head-days at all. Use this, not lot_head_days(), for anything involving cost.';

-- ---------------------------------------------------------------------
-- 3. A transfer may now carry a zero basis
-- ---------------------------------------------------------------------
-- Decision 2. The existing checks were written when at-cost was the only
-- basis and a zero was genuinely a bug. It is now the feed pen's whole
-- point: the source lot keeps every dollar.
ALTER TABLE public.lot_transfers DROP CONSTRAINT IF EXISTS lot_transfers_basis_per_head_check;
ALTER TABLE public.lot_transfers DROP CONSTRAINT IF EXISTS lot_transfers_basis_total_check;
ALTER TABLE public.lot_transfers
    ADD CONSTRAINT lot_transfers_basis_per_head_check CHECK (basis_per_head >= 0);
ALTER TABLE public.lot_transfers
    ADD CONSTRAINT lot_transfers_basis_total_check    CHECK (basis_total    >= 0);

-- 'feed_pen'    — a lot sends cripples to the pen, at $0.
-- 'fy_rollover' — June 30: last year's pen sends what is still standing
--                 to this year's pen, also at $0 (decision 8).
ALTER TABLE public.lot_transfers DROP CONSTRAINT IF EXISTS lot_transfers_kind_check;
ALTER TABLE public.lot_transfers
    ADD CONSTRAINT lot_transfers_kind_check
    CHECK (kind IN ('fold_in','sort','feed_pen','fy_rollover'));


-- ---------------------------------------------------------------------
-- 4. record_lot_transfer takes the two new kinds
-- ---------------------------------------------------------------------
-- Reproduced in full from docs/sql/2026-09-02_lot_transfers.sql — a
-- CREATE OR REPLACE has to carry the whole body — with four changes, all
-- of them commented in place:
--
--   * 'feed_pen' and 'fy_rollover' join the kind list;
--   * the kind and the two lots must AGREE, so a pen move typed as a
--     'sort' cannot quietly carry the source lot's whole basis in;
--   * a feed pen destination has no receipt or invoice, so its date floor
--     is lots.arrival_date;
--   * a zero basis is accepted for the two pen kinds and still refused
--     for the two ordinary ones.
--
-- Everything else — the date floor, the per-pasture availability
-- aggregate, the assignment close-vs-decrement, the two head-math events,
-- the tag repointing and its fiscal-year reasoning — is untouched.
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
    v_dst_is_pen    BOOLEAN;
    v_src_is_pen    BOOLEAN;
    v_dst_arrival   DATE;
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
    -- 'feed_pen' and 'fy_rollover' arrived 2026-09-07. Both move cattle
    -- at a ZERO basis into a feed pen; see docs/feed-pen-design.md.
    IF p_kind IS NULL OR p_kind NOT IN ('fold_in','sort','feed_pen','fy_rollover') THEN
        RAISE EXCEPTION 'Transfer kind must be fold_in, sort, feed_pen or fy_rollover (got %).', p_kind;
    END IF;

    SELECT closed_at, fiscal_year, is_feed_pen INTO v_src_closed, v_src_fy, v_src_is_pen
      FROM public.lots WHERE id = p_source_lot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source lot % not found.', p_source_lot_id;
    END IF;
    SELECT closed_at, fiscal_year, is_feed_pen, arrival_date
      INTO v_dst_closed, v_dst_fy, v_dst_is_pen, v_dst_arrival
      FROM public.lots WHERE id = p_dest_lot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Destination lot % not found.', p_dest_lot_id;
    END IF;

    -- The kind and the two lots have to agree. A feed pen move recorded
    -- as a 'sort' would move the source lot's whole at-cost basis into the
    -- pen — the exact outcome the feed pen exists to avoid — and it would
    -- do it silently, because both are valid transfers. Refuse the
    -- mismatch rather than trust the caller's dropdown.
    IF p_kind IN ('feed_pen','fy_rollover') AND NOT COALESCE(v_dst_is_pen, FALSE) THEN
        RAISE EXCEPTION 'Kind % requires a feed pen destination; % is an ordinary lot.',
            p_kind, (SELECT lot_number FROM public.lots WHERE id = p_dest_lot_id);
    END IF;
    IF p_kind = 'fy_rollover' AND NOT COALESCE(v_src_is_pen, FALSE) THEN
        RAISE EXCEPTION 'A fiscal-year rollover moves last year''s pen into this year''s; % is not a feed pen.',
            (SELECT lot_number FROM public.lots WHERE id = p_source_lot_id);
    END IF;
    IF p_kind IN ('fold_in','sort') AND COALESCE(v_dst_is_pen, FALSE) THEN
        RAISE EXCEPTION 'Cattle enter a feed pen at a zero basis. Use the feed pen command, not a % transfer.', p_kind;
    END IF;
    IF p_kind IN ('fold_in','sort') AND COALESCE(v_src_is_pen, FALSE) THEN
        RAISE EXCEPTION 'Cattle leave a feed pen by being sold, butchered, dying or going missing — not by transfer.';
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

    -- A feed pen never takes a delivery: cattle only ever transfer in, so
    -- it has no receipt and no invoice to measure against. Its arrival_date
    -- is the floor instead, and it is a real floor for the same reason —
    -- lot_daily_head clamps an event dated before a lot's start UP to that
    -- start, silently, and the pen would collect head-days for cattle that
    -- were not in it.
    IF v_dst_first = DATE '9999-12-31' AND COALESCE(v_dst_is_pen, FALSE) THEN
        v_dst_first := v_dst_arrival;
    END IF;
    IF v_dst_first = DATE '9999-12-31' OR v_dst_first IS NULL THEN
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
    -- Decision 2 of the feed pen design: cattle enter the pen at ZERO and
    -- the source lot keeps every dollar. Zero stays a bug for an ordinary
    -- transfer, where it would mean a lot gave cattle away for nothing.
    IF p_basis_per_head IS NULL OR p_basis_per_head < 0 THEN
        RAISE EXCEPTION 'A cost basis per head is required and cannot be negative.';
    END IF;
    IF p_basis_per_head = 0 AND p_kind NOT IN ('feed_pen','fy_rollover') THEN
        RAISE EXCEPTION 'A % transfer moves cattle at cost; a zero basis would hand them over for nothing.', p_kind;
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
    'Move head and their frozen basis between lots, atomically. INVOKER. Head is derived from the pasture lines. Kinds fold_in/sort move cattle AT COST; feed_pen/fy_rollover move them at ZERO into a feed pen and the source lot keeps every dollar.';

-- ---------------------------------------------------------------------
-- 5. The ledger: which lot each head in the pen came off
-- ---------------------------------------------------------------------
-- The pen holds head from several lots at once, and this is the book that
-- says whose they are. It does NOT drive head math — lot_events, sales and
-- lot_status do that, exactly as they do for any other lot — and section 8
-- reconciles the two.
--
-- WHY IT IS A TABLE AND NOT A VIEW OVER lot_transfers: a fiscal-year
-- rollover moves last year's pen into this year's, so the transfer's
-- source_lot_id is the OLD PEN and the original lot is lost. Deriving the
-- origin would mean chasing pen-to-pen transfers recursively and hoping the
-- chain is unbroken. The rollover writes the origin down instead.
CREATE TABLE IF NOT EXISTS public.feed_pen_ledger (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pen_lot_id      UUID NOT NULL REFERENCES public.lots(id),
    source_lot_id   UUID NOT NULL REFERENCES public.lots(id),
    entry_date      DATE NOT NULL,
    head_delta      INTEGER NOT NULL CHECK (head_delta <> 0),
    entry_kind      TEXT NOT NULL CHECK (entry_kind IN ('transfer_in','rollover_in','rollover_out','removal')),
    transfer_id     UUID REFERENCES public.lot_transfers(id) ON DELETE CASCADE,
    removal_line_id UUID,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      UUID
);

COMMENT ON TABLE public.feed_pen_ledger IS
    'Head in the feed pen by the lot they came off. Positive on the way in, negative on removal. Attribution only — head math stays on lot_events/sales/lot_status.';

CREATE INDEX IF NOT EXISTS feed_pen_ledger_pen_idx    ON public.feed_pen_ledger (pen_lot_id, source_lot_id);
CREATE INDEX IF NOT EXISTS feed_pen_ledger_date_idx   ON public.feed_pen_ledger (entry_date);
CREATE INDEX IF NOT EXISTS feed_pen_ledger_xfer_idx   ON public.feed_pen_ledger (transfer_id);

-- ---------------------------------------------------------------------
-- 6. Removals — the four ways out
-- ---------------------------------------------------------------------
-- Decision 6. Each removal writes the head-math artifact that outcome
-- actually IS (ref_kind / ref_id), so nothing here is a second way to make
-- head disappear:
--
--   sold      -> a sales row on the pen lot; the money stays in the pen
--   butchered -> a negative 'adjustment' lot_event, cause 'butchered', $0
--   died      -> record_death_with_pasture, the existing RPC
--   missing   -> a negative 'adjustment' lot_event, cause 'missing'
--
-- Butchered and missing are NOT deaths: a butchered animal is a decision
-- and a missing one is a hole in the count, and filing either as a death
-- puts it in the mortality rate and the pull-failure denominators of the
-- Doctoring & Deaths report, which exist to measure the health program.
CREATE TABLE IF NOT EXISTS public.feed_pen_removals (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pen_lot_id     UUID NOT NULL REFERENCES public.lots(id),
    removal_date   DATE NOT NULL,
    method         TEXT NOT NULL CHECK (method IN ('sold','butchered','died','missing')),
    pasture_id     UUID NOT NULL REFERENCES public.pastures(id),
    head_count     INTEGER NOT NULL CHECK (head_count > 0),

    -- Decision 4: salvage stays in the pen. Decision 7: butchered is $0.
    proceeds_usd   NUMERIC NOT NULL DEFAULT 0 CHECK (proceeds_usd >= 0),
    buyer          TEXT,
    net_weight_lb  NUMERIC CHECK (net_weight_lb IS NULL OR net_weight_lb > 0),

    -- Decision 5: what these head cost in the pen, frozen the day they left,
    -- and split across the lots they came off on the lines below. Tracked,
    -- never posted to the source lot — it is very often already closed.
    pen_cost_usd   NUMERIC NOT NULL DEFAULT 0,

    tag_number     TEXT,
    cause          TEXT,
    notes          TEXT,

    ref_kind       TEXT NOT NULL CHECK (ref_kind IN ('sale','death','adjustment')),
    ref_id         UUID NOT NULL,
    -- What the save actually DID to the pasture assignment, so the reversal
    -- reads it instead of inferring it. A removal that CLOSED an assignment
    -- reverses by reopening it — head_count is left intact on close, so
    -- adding head back on top double-counts the herd. That is the
    -- delete_death_event trap and it was live in August.
    assignment_id       UUID,
    assignment_closed   BOOLEAN NOT NULL DEFAULT FALSE,

    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by     UUID
);

COMMENT ON TABLE public.feed_pen_removals IS
    'A head leaving the feed pen: sold, butchered, died or missing. Cannot be edited — delete and re-enter, which puts the cattle back.';

CREATE TABLE IF NOT EXISTS public.feed_pen_removal_lines (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    removal_id    UUID NOT NULL REFERENCES public.feed_pen_removals(id) ON DELETE CASCADE,
    source_lot_id UUID NOT NULL REFERENCES public.lots(id),
    head_count    INTEGER NOT NULL CHECK (head_count > 0),
    pen_cost_usd  NUMERIC NOT NULL DEFAULT 0,
    proceeds_usd  NUMERIC NOT NULL DEFAULT 0,
    UNIQUE (removal_id, source_lot_id)
);

COMMENT ON TABLE public.feed_pen_removal_lines IS
    'Which lots the removed head came off. Pre-filled pro-rata on what is standing (decision 10) because tags generally are not available; editable, and a named tag overrides it.';

CREATE INDEX IF NOT EXISTS feed_pen_removals_pen_idx  ON public.feed_pen_removals (pen_lot_id, removal_date);
CREATE INDEX IF NOT EXISTS feed_pen_rem_lines_rem_idx ON public.feed_pen_removal_lines (removal_id);
CREATE INDEX IF NOT EXISTS feed_pen_rem_lines_src_idx ON public.feed_pen_removal_lines (source_lot_id);

-- Added after the fact because the two tables reference each other in the
-- other direction. Guarded rather than DROP/ADD: dropping a live FK for a
-- moment is exactly when a concurrent write slips an orphan through.
DO $fk$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'feed_pen_ledger_line_fk'
           AND conrelid = 'public.feed_pen_ledger'::regclass
    ) THEN
        ALTER TABLE public.feed_pen_ledger ADD CONSTRAINT feed_pen_ledger_line_fk
            FOREIGN KEY (removal_line_id)
            REFERENCES public.feed_pen_removal_lines(id) ON DELETE CASCADE;
    END IF;
END
$fk$;

-- ---------------------------------------------------------------------
-- 7. RLS — derived decision 4: the pen carries dollars
-- ---------------------------------------------------------------------
-- can_read_books, not can_read_operational. Crew sees no pen money, the
-- same boundary that keeps them off sales and lot_transfers.
ALTER TABLE public.feed_pen_ledger        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_pen_removals      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_pen_removal_lines ENABLE ROW LEVEL SECURITY;

DO $pol$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['feed_pen_ledger','feed_pen_removals','feed_pen_removal_lines'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_select', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_insert', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_update', t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_delete', t);

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
-- 8. A feed pen transfer writes its own ledger row
-- ---------------------------------------------------------------------
-- A trigger rather than a line in record_lot_transfer, so the ledger cannot
-- be forgotten by a later caller — and so the ordinary transfer RPC stays
-- ignorant of the pen. Only kind 'feed_pen' fires: a rollover's source lot
-- is the OLD PEN, and close_feed_pen_year writes those rows itself with the
-- original lots preserved.
CREATE OR REPLACE FUNCTION public.feed_pen_ledger_from_transfer()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
BEGIN
    IF NEW.kind = 'feed_pen' THEN
        INSERT INTO public.feed_pen_ledger (
            pen_lot_id, source_lot_id, entry_date, head_delta, entry_kind,
            transfer_id, created_by
        ) VALUES (
            NEW.dest_lot_id, NEW.source_lot_id, NEW.transfer_date,
            NEW.head_count, 'transfer_in', NEW.id, NEW.created_by
        );
    END IF;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS feed_pen_ledger_on_transfer ON public.lot_transfers;
CREATE TRIGGER feed_pen_ledger_on_transfer
    AFTER INSERT ON public.lot_transfers
    FOR EACH ROW EXECUTE FUNCTION public.feed_pen_ledger_from_transfer();

-- ---------------------------------------------------------------------
-- 9. What the pen cost, and whose cattle it was spent on
-- ---------------------------------------------------------------------
-- Every view here is security_invoker (rule 3): without it a view runs as
-- its owner and bypasses RLS entirely, which is how ten views were once
-- readable by anon with no login at all.

-- 9a. Head in the pen per source lot per day. The day series comes from
-- lot_daily_head for the pen, which is why section 2 had to teach it about
-- transfer_in — before that this view had no days to stand on.
DROP VIEW IF EXISTS public.feed_pen_source_daily CASCADE;
CREATE VIEW public.feed_pen_source_daily
WITH (security_invoker = true) AS
WITH pen_days AS (
    SELECT d.lot_id AS pen_lot_id, d.as_of_date
      FROM public.lot_daily_head d
      JOIN public.lots l ON l.id = d.lot_id AND l.is_feed_pen
), pen_bounds AS (
    SELECT pen_lot_id, min(as_of_date) AS first_day, max(as_of_date) AS last_day
      FROM pen_days GROUP BY 1
), entries AS (
    -- Clamp into the pen's own window the way lot_daily_head clamps, so an
    -- entry dated outside it is carried rather than silently dropped.
    SELECT g.pen_lot_id, g.source_lot_id,
           LEAST(GREATEST(g.entry_date, b.first_day), b.last_day) AS d,
           sum(g.head_delta) AS delta
      FROM public.feed_pen_ledger g
      JOIN pen_bounds b ON b.pen_lot_id = g.pen_lot_id
     GROUP BY 1, 2, 3
), grid AS (
    SELECT pd.pen_lot_id, s.source_lot_id, pd.as_of_date
      FROM pen_days pd
      JOIN (SELECT DISTINCT pen_lot_id, source_lot_id FROM public.feed_pen_ledger) s
        ON s.pen_lot_id = pd.pen_lot_id
)
SELECT g.pen_lot_id,
       g.source_lot_id,
       g.as_of_date,
       GREATEST(0, sum(COALESCE(e.delta, 0)) OVER (
           PARTITION BY g.pen_lot_id, g.source_lot_id
           ORDER BY g.as_of_date ROWS UNBOUNDED PRECEDING))::integer AS head_on_hand
  FROM grid g
  LEFT JOIN entries e
    ON e.pen_lot_id = g.pen_lot_id AND e.source_lot_id = g.source_lot_id AND e.d = g.as_of_date;

-- 9b. What the pen spent each day. Feed rides lot_feed_daily, which already
-- spreads a usage over the head-days inside its period — the pen needs no
-- second costing path. Medicine is a POINT cost on the day it was given.
--
-- The database runs UTC and the ranch does not: doctoring_events.event_datetime
-- is timestamptz, and casting it to date in UTC becomes tomorrow at 7pm
-- Central. AT TIME ZONE 'America/Chicago' is the same fix ranch_today() is.
DROP VIEW IF EXISTS public.feed_pen_daily_cost CASCADE;
CREATE VIEW public.feed_pen_daily_cost
WITH (security_invoker = true) AS
WITH pens AS (SELECT id AS pen_lot_id FROM public.lots WHERE is_feed_pen),
feed AS (
    SELECT fd.lot_id AS pen_lot_id, fd.day AS d, sum(fd.cost_usd) AS usd
      FROM public.lot_feed_daily fd
      JOIN pens p ON p.pen_lot_id = fd.lot_id
     GROUP BY 1, 2
), med AS (
    SELECT de.lot_id AS pen_lot_id,
           (de.event_datetime AT TIME ZONE 'America/Chicago')::date AS d,
           sum(dem.cost) AS usd
      FROM public.doctoring_event_meds dem
      JOIN public.doctoring_events de ON de.id = dem.doctoring_event_id
      JOIN pens p ON p.pen_lot_id = de.lot_id
     GROUP BY 1, 2
)
SELECT COALESCE(f.pen_lot_id, m.pen_lot_id) AS pen_lot_id,
       COALESCE(f.d, m.d)                   AS day,
       COALESCE(f.usd, 0)                   AS feed_usd,
       COALESCE(m.usd, 0)                   AS med_usd
  FROM feed f
  FULL JOIN med m ON m.pen_lot_id = f.pen_lot_id AND m.d = f.d;

-- 9c. That daily cost split across the lots the cattle came off, by head
-- standing that day. This is the head-day allocation the feed module and
-- the closeout already use everywhere else.
DROP VIEW IF EXISTS public.feed_pen_cost_by_source_daily CASCADE;
CREATE VIEW public.feed_pen_cost_by_source_daily
WITH (security_invoker = true) AS
SELECT c.pen_lot_id,
       s.source_lot_id,
       c.day,
       s.head_on_hand,
       c.feed_usd * s.head_on_hand::numeric / t.total_head::numeric AS feed_usd,
       c.med_usd  * s.head_on_hand::numeric / t.total_head::numeric AS med_usd
  FROM public.feed_pen_daily_cost c
  JOIN public.feed_pen_source_daily s
    ON s.pen_lot_id = c.pen_lot_id AND s.as_of_date = c.day
  JOIN LATERAL (
      SELECT sum(s2.head_on_hand) AS total_head
        FROM public.feed_pen_source_daily s2
       WHERE s2.pen_lot_id = c.pen_lot_id AND s2.as_of_date = c.day
  ) t ON TRUE
 WHERE t.total_head > 0;

-- 9d. The answer to John's question: what have the feed pen cattle off
-- each lot cost. `frozen_removed_usd` is the figure taken AT THE DATE
-- REMOVED; `accrued_usd` is everything spent on that lot's head to date,
-- standing or gone. The gap between them is what the head still in the
-- pen have run up since.
DROP VIEW IF EXISTS public.feed_pen_cost_by_source CASCADE;
CREATE VIEW public.feed_pen_cost_by_source
WITH (security_invoker = true) AS
WITH src AS (
    SELECT DISTINCT g.pen_lot_id, g.source_lot_id FROM public.feed_pen_ledger g
)
SELECT s.pen_lot_id,
       pen.lot_number   AS pen_lot_number,
       pen.fiscal_year  AS pen_fiscal_year,
       s.source_lot_id,
       sl.lot_number    AS source_lot_number,
       sl.fiscal_year   AS source_fiscal_year,
       sl.closed_at     AS source_closed_at,
       COALESCE(arrived.head_in, 0)                AS head_in,
       -- Off the ledger, not head_in less removals: a fiscal-year rollover
       -- takes head out of the pen without ever being a removal line.
       COALESCE(bal.head_now, 0)                   AS head_on_hand,
       COALESCE(rem.head_out, 0)                   AS head_removed,
       COALESCE(rem.head_sold, 0)                  AS head_sold,
       COALESCE(rem.head_butchered, 0)             AS head_butchered,
       COALESCE(rem.head_died, 0)                  AS head_died,
       COALESCE(rem.head_missing, 0)               AS head_missing,
       COALESCE(acc.feed_usd, 0)                   AS feed_usd,
       COALESCE(acc.med_usd, 0)                    AS med_usd,
       COALESCE(acc.feed_usd, 0) + COALESCE(acc.med_usd, 0) AS accrued_usd,
       COALESCE(rem.frozen_usd, 0)                 AS frozen_removed_usd,
       GREATEST(0, COALESCE(acc.feed_usd, 0) + COALESCE(acc.med_usd, 0)
                 - COALESCE(rem.frozen_usd, 0))    AS accrued_open_usd,
       COALESCE(rem.proceeds_usd, 0)               AS salvage_usd
  FROM src s
  JOIN public.lots pen ON pen.id = s.pen_lot_id
  JOIN public.lots sl  ON sl.id  = s.source_lot_id
  LEFT JOIN LATERAL (
      SELECT sum(g.head_delta) AS head_in
        FROM public.feed_pen_ledger g
       WHERE g.pen_lot_id = s.pen_lot_id AND g.source_lot_id = s.source_lot_id
         AND g.head_delta > 0
  ) arrived ON TRUE
  LEFT JOIN LATERAL (
      SELECT sum(g.head_delta) AS head_now
        FROM public.feed_pen_ledger g
       WHERE g.pen_lot_id = s.pen_lot_id AND g.source_lot_id = s.source_lot_id
  ) bal ON TRUE
  LEFT JOIN LATERAL (
      SELECT sum(l.head_count)                                                    AS head_out,
             sum(l.head_count) FILTER (WHERE r.method = 'sold')                   AS head_sold,
             sum(l.head_count) FILTER (WHERE r.method = 'butchered')              AS head_butchered,
             sum(l.head_count) FILTER (WHERE r.method = 'died')                   AS head_died,
             sum(l.head_count) FILTER (WHERE r.method = 'missing')                AS head_missing,
             sum(l.pen_cost_usd)                                                  AS frozen_usd,
             sum(l.proceeds_usd)                                                  AS proceeds_usd
        FROM public.feed_pen_removal_lines l
        JOIN public.feed_pen_removals r ON r.id = l.removal_id
       WHERE r.pen_lot_id = s.pen_lot_id AND l.source_lot_id = s.source_lot_id
  ) rem ON TRUE
  LEFT JOIN LATERAL (
      SELECT sum(d.feed_usd) AS feed_usd, sum(d.med_usd) AS med_usd
        FROM public.feed_pen_cost_by_source_daily d
       WHERE d.pen_lot_id = s.pen_lot_id AND d.source_lot_id = s.source_lot_id
  ) acc ON TRUE;

COMMENT ON VIEW public.feed_pen_cost_by_source IS
    'What the feed pen cattle off each lot cost. frozen_removed_usd is the figure frozen at the date removed (John, 2026-09-07). Tracked, never posted to the source lot — that lot is very often closed by then.';

-- 9e. The pen's own books. Decision 4: salvage counts against pen cost, so
-- the pen has a margin to manage. Decision 8: this net is what posts to
-- Redwing at June 30.
DROP VIEW IF EXISTS public.feed_pen_summary CASCADE;
CREATE VIEW public.feed_pen_summary
WITH (security_invoker = true) AS
SELECT l.id AS pen_lot_id,
       l.lot_number,
       l.fiscal_year,
       l.arrival_date,
       l.closed_at,
       COALESCE(ls.head_current, 0)      AS head_on_hand,
       COALESCE(arrived.head_in, 0)      AS head_in,
       COALESCE(rem.head_sold, 0)        AS head_sold,
       COALESCE(rem.head_butchered, 0)   AS head_butchered,
       COALESCE(rem.head_died, 0)        AS head_died,
       COALESCE(rem.head_missing, 0)     AS head_missing,
       COALESCE(cst.feed_usd, 0)         AS feed_usd,
       COALESCE(cst.med_usd, 0)          AS med_usd,
       COALESCE(cst.feed_usd, 0) + COALESCE(cst.med_usd, 0) AS total_cost_usd,
       COALESCE(rem.proceeds_usd, 0)     AS salvage_usd,
       COALESCE(rem.proceeds_usd, 0)
         - (COALESCE(cst.feed_usd, 0) + COALESCE(cst.med_usd, 0)) AS net_usd,
       COALESCE(hd.head_days, 0)         AS head_days
  FROM public.lots l
  LEFT JOIN public.lot_status ls ON ls.lot_id = l.id
  LEFT JOIN LATERAL (
      SELECT sum(g.head_delta) AS head_in FROM public.feed_pen_ledger g
       WHERE g.pen_lot_id = l.id AND g.head_delta > 0
  ) arrived ON TRUE
  LEFT JOIN LATERAL (
      SELECT sum(r.head_count) FILTER (WHERE r.method = 'sold')      AS head_sold,
             sum(r.head_count) FILTER (WHERE r.method = 'butchered') AS head_butchered,
             sum(r.head_count) FILTER (WHERE r.method = 'died')      AS head_died,
             sum(r.head_count) FILTER (WHERE r.method = 'missing')   AS head_missing,
             sum(r.proceeds_usd)                                     AS proceeds_usd
        FROM public.feed_pen_removals r WHERE r.pen_lot_id = l.id
  ) rem ON TRUE
  LEFT JOIN LATERAL (
      SELECT sum(c.feed_usd) AS feed_usd, sum(c.med_usd) AS med_usd
        FROM public.feed_pen_daily_cost c WHERE c.pen_lot_id = l.id
  ) cst ON TRUE
  LEFT JOIN LATERAL (
      SELECT sum(d.head_on_hand) AS head_days
        FROM public.lot_daily_head d WHERE d.lot_id = l.id
  ) hd ON TRUE
 WHERE l.is_feed_pen;

COMMENT ON VIEW public.feed_pen_summary IS
    'The feed pen''s own books per fiscal year: salvage less feed less medicine. net_usd is what posts to Redwing at June 30 (John, 2026-09-07).';

-- 9f. Does the attribution ledger still tie to head math? It is a second
-- book beside lot_status, so it can drift, and a drift means dollars are
-- being attributed to the wrong lot. Feeds the Anomalies report.
DROP VIEW IF EXISTS public.feed_pen_reconciliation CASCADE;
CREATE VIEW public.feed_pen_reconciliation
WITH (security_invoker = true) AS
SELECT l.id AS pen_lot_id,
       l.lot_number,
       l.fiscal_year,
       COALESCE(ls.head_current, 0)              AS head_current,
       COALESCE(g.ledger_head, 0)                AS ledger_head,
       COALESCE(ls.head_current, 0) - COALESCE(g.ledger_head, 0) AS variance
  FROM public.lots l
  LEFT JOIN public.lot_status ls ON ls.lot_id = l.id
  LEFT JOIN LATERAL (
      SELECT sum(x.head_delta) AS ledger_head
        FROM public.feed_pen_ledger x WHERE x.pen_lot_id = l.id
  ) g ON TRUE
 WHERE l.is_feed_pen;

-- ---------------------------------------------------------------------
-- 10. record_feed_pen_removal — the four ways out, atomically
-- ---------------------------------------------------------------------
-- INVOKER, like every other head-math RPC. RLS decides who may write.
--
-- ORDER MATTERS AND IT IS NOT OBVIOUS: the frozen pen cost is computed
-- BEFORE any head-math row is written. Those cost views read
-- lot_daily_head, which reads the very lot_events / sales row this
-- function is about to insert — compute afterwards and the head being
-- removed have already stopped accruing, so the figure frozen against
-- their source lot is short by the cost of their last day.
CREATE OR REPLACE FUNCTION public.record_feed_pen_removal(
    p_pen_lot_id    UUID,
    p_pasture_id    UUID,
    p_removal_date  DATE,
    p_method        TEXT,
    p_lines         JSONB,
    p_proceeds_usd  NUMERIC DEFAULT 0,
    p_buyer         TEXT    DEFAULT NULL,
    p_net_weight_lb NUMERIC DEFAULT NULL,
    p_tag_number    TEXT    DEFAULT NULL,
    p_cause         TEXT    DEFAULT NULL,
    p_notes         TEXT    DEFAULT NULL,
    p_recorded_by   UUID    DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    v_id          UUID;
    v_head        INTEGER;
    v_is_pen      BOOLEAN;
    v_closed      TIMESTAMPTZ;
    v_pen_number  TEXT;
    v_first_day   DATE;
    v_assign      UUID;
    v_assign_head INTEGER;
    v_proceeds    NUMERIC;
    v_ref_kind    TEXT;
    v_ref_id      UUID;
    v_closed_assn BOOLEAN := FALSE;
    v_resid       INTEGER;
    v_pool        NUMERIC;
    v_standing    INTEGER;
    v_line_cost   NUMERIC;
    v_total_cost  NUMERIC := 0;
    rec           RECORD;
BEGIN
    ------------------------------------------------------------- the pen
    SELECT is_feed_pen, closed_at, lot_number
      INTO v_is_pen, v_closed, v_pen_number
      FROM public.lots WHERE id = p_pen_lot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Feed pen lot % not found.', p_pen_lot_id;
    END IF;
    IF NOT COALESCE(v_is_pen, FALSE) THEN
        RAISE EXCEPTION 'Lot % is not a feed pen. Ordinary lots sell and lose cattle through their own screens.', v_pen_number;
    END IF;
    IF v_closed IS NOT NULL THEN
        RAISE EXCEPTION 'Feed pen % is closed for the fiscal year. Reopen it before recording a removal.', v_pen_number;
    END IF;

    IF p_method IS NULL OR p_method NOT IN ('sold','butchered','died','missing') THEN
        RAISE EXCEPTION 'Removal method must be sold, butchered, died or missing (got %).', p_method;
    END IF;

    ------------------------------------------------------------- the date
    IF p_removal_date IS NULL THEN
        RAISE EXCEPTION 'A removal date is required.';
    END IF;
    IF p_removal_date > public.ranch_today() THEN
        RAISE EXCEPTION 'Removal date % is in the future (ranch today is %).',
            p_removal_date, public.ranch_today();
    END IF;

    SELECT min(as_of_date) INTO v_first_day
      FROM public.lot_daily_head WHERE lot_id = p_pen_lot_id;
    IF v_first_day IS NULL THEN
        RAISE EXCEPTION 'Feed pen % has no head-day history, so nothing has ever been in it.', v_pen_number;
    END IF;
    IF p_removal_date < v_first_day THEN
        RAISE EXCEPTION 'Removal date % is before anything was in the pen (first day %).',
            p_removal_date, v_first_day;
    END IF;

    ------------------------------------------------------------- the lines
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'At least one source lot line is required — the pen holds cattle off several lots at once.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_lines) e
         WHERE (e->>'source_lot_id') IS NULL
            OR (e->>'head_count') IS NULL
            OR (e->>'head_count')::integer <= 0
    ) THEN
        RAISE EXCEPTION 'Every line needs a source lot and a positive head count.';
    END IF;

    SELECT sum((e->>'head_count')::integer) INTO v_head
      FROM jsonb_array_elements(p_lines) e;

    -- Each source lot must actually have that many head standing in the pen.
    -- Aggregate first: two lines naming the same lot are tested on their sum.
    FOR rec IN
        SELECT (e->>'source_lot_id')::uuid AS src, sum((e->>'head_count')::integer) AS hd
          FROM jsonb_array_elements(p_lines) e GROUP BY 1
    LOOP
        SELECT COALESCE(sum(head_delta), 0) INTO v_standing
          FROM public.feed_pen_ledger
         WHERE pen_lot_id = p_pen_lot_id AND source_lot_id = rec.src;
        IF rec.hd > v_standing THEN
            RAISE EXCEPTION 'Lot % has % head standing in the pen; the removal draws %.',
                (SELECT lot_number FROM public.lots WHERE id = rec.src), v_standing, rec.hd;
        END IF;
    END LOOP;

    ---------------------------------------------------------- the pasture
    SELECT id, head_count INTO v_assign, v_assign_head
      FROM public.lot_pasture_assignments
     WHERE lot_id = p_pen_lot_id AND pasture_id = p_pasture_id AND moved_out IS NULL;
    IF v_assign IS NULL THEN
        RAISE EXCEPTION 'The feed pen has no open assignment in that pasture.';
    END IF;
    IF v_head > v_assign_head THEN
        RAISE EXCEPTION 'Cannot remove % head from a pen holding %.', v_head, v_assign_head;
    END IF;

    ---------------------------------------------------------- the dollars
    -- Decision 7: butchered carries no value. It is a disposal, not a sale.
    v_proceeds := COALESCE(p_proceeds_usd, 0);
    IF p_method <> 'sold' AND v_proceeds <> 0 THEN
        IF p_method = 'butchered' THEN
            RAISE EXCEPTION 'Butchered cattle carry no value (John, 2026-09-07). Record it as a sale if money changed hands.';
        END IF;
        RAISE EXCEPTION 'Only a sale carries proceeds.';
    END IF;
    IF v_proceeds < 0 THEN
        RAISE EXCEPTION 'Proceeds cannot be negative.';
    END IF;

    ------------------------------------------------------------- header
    INSERT INTO public.feed_pen_removals (
        pen_lot_id, removal_date, method, pasture_id, head_count,
        proceeds_usd, buyer, net_weight_lb, tag_number, cause, notes,
        ref_kind, ref_id, assignment_id, created_by
    ) VALUES (
        p_pen_lot_id, p_removal_date, p_method, p_pasture_id, v_head,
        v_proceeds, p_buyer, p_net_weight_lb, p_tag_number, p_cause, p_notes,
        'adjustment', p_pen_lot_id, v_assign, p_recorded_by   -- ref rewritten below
    ) RETURNING id INTO v_id;

    INSERT INTO public.feed_pen_removal_lines (removal_id, source_lot_id, head_count)
    SELECT v_id, (e->>'source_lot_id')::uuid, sum((e->>'head_count')::integer)
      FROM jsonb_array_elements(p_lines) e
     GROUP BY 2;

    ------------------------------------------------- freeze the pen cost
    -- Decision 5, and John's actual question: what did the feed pen cattle
    -- off this lot cost, at the date they left.
    --
    -- Each source lot has a POOL — everything the pen has spent on its head
    -- to date, less what earlier removals already froze — and this removal
    -- draws its share of that pool by head. Drawn down this way the frozen
    -- figures can never exceed what the pen actually spent, and a lot whose
    -- last head leaves takes its whole remaining pool with it.
    FOR rec IN
        SELECT id, source_lot_id, head_count FROM public.feed_pen_removal_lines
         WHERE removal_id = v_id ORDER BY id
    LOOP
        SELECT GREATEST(0, COALESCE(c.accrued_usd, 0) - COALESCE(f.frozen, 0))
          INTO v_pool
          FROM (SELECT 1) z
          LEFT JOIN public.feed_pen_cost_by_source c
                 ON c.pen_lot_id = p_pen_lot_id AND c.source_lot_id = rec.source_lot_id
          LEFT JOIN LATERAL (
              SELECT sum(l2.pen_cost_usd) AS frozen
                FROM public.feed_pen_removal_lines l2
                JOIN public.feed_pen_removals r2 ON r2.id = l2.removal_id
               WHERE r2.pen_lot_id = p_pen_lot_id
                 AND l2.source_lot_id = rec.source_lot_id
                 AND l2.removal_id <> v_id
          ) f ON TRUE;

        SELECT COALESCE(sum(head_delta), 0) INTO v_standing
          FROM public.feed_pen_ledger
         WHERE pen_lot_id = p_pen_lot_id AND source_lot_id = rec.source_lot_id;

        IF v_standing > 0 THEN
            v_line_cost := round(COALESCE(v_pool, 0) * rec.head_count::numeric / v_standing::numeric, 2);
        ELSE
            v_line_cost := 0;
        END IF;

        UPDATE public.feed_pen_removal_lines SET pen_cost_usd = v_line_cost WHERE id = rec.id;
        v_total_cost := v_total_cost + v_line_cost;
    END LOOP;

    UPDATE public.feed_pen_removals SET pen_cost_usd = v_total_cost WHERE id = v_id;

    ------------------------------------------------- allocate the salvage
    -- Largest-remainder, so the line shares sum EXACTLY to the check.
    -- Not "round each and dump the residual on the last line" — that works
    -- too, but always parks the error on whichever lot was typed last.
    IF v_proceeds > 0 THEN
        SELECT round(v_proceeds * 100)::integer - COALESCE(sum(floor(v_proceeds * 100 * l.head_count::numeric / v_head::numeric)), 0)::integer
          INTO v_resid
          FROM public.feed_pen_removal_lines l WHERE l.removal_id = v_id;

        WITH b AS (
            SELECT l.id,
                   floor(v_proceeds * 100 * l.head_count::numeric / v_head::numeric) AS cents,
                   (v_proceeds * 100 * l.head_count::numeric / v_head::numeric)
                     - floor(v_proceeds * 100 * l.head_count::numeric / v_head::numeric) AS frac
              FROM public.feed_pen_removal_lines l WHERE l.removal_id = v_id
        ), r AS (
            SELECT id, cents, row_number() OVER (ORDER BY frac DESC, id) AS rk FROM b
        )
        UPDATE public.feed_pen_removal_lines fl
           SET proceeds_usd = (r.cents + CASE WHEN r.rk <= v_resid THEN 1 ELSE 0 END)::numeric / 100
          FROM r WHERE fl.id = r.id;
    END IF;

    -------------------------------------------------------- the head math
    -- Each outcome writes the artifact it actually IS. Nothing here is a
    -- second way to make head disappear.
    IF p_method = 'died' THEN
        -- The existing RPC, so the death lands in the health reports and
        -- delete_death_event can reverse it unchanged.
        v_ref_id   := public.record_death_with_pasture(
            p_pen_lot_id, p_pasture_id, v_head, p_tag_number, p_cause,
            p_removal_date, COALESCE(p_notes, 'Feed pen death'), p_recorded_by);
        v_ref_kind := 'death';

    ELSIF p_method = 'sold' THEN
        INSERT INTO public.sales (
            lot_id, sale_date, head_count, net_weight_lb, total_price,
            price_per_head, buyer, notes, created_by
        ) VALUES (
            p_pen_lot_id, p_removal_date, v_head, p_net_weight_lb, v_proceeds,
            CASE WHEN v_head > 0 THEN round(v_proceeds / v_head, 2) END,
            p_buyer, COALESCE(p_notes, 'Feed pen salvage'), p_recorded_by
        ) RETURNING id INTO v_ref_id;
        v_ref_kind := 'sale';

    ELSE
        -- butchered / missing. A signed 'adjustment' is deliberate: it is
        -- already summed by lot_status AND lot_daily_head, and lot_events
        -- already carries a cause. Adding two new event types would mean
        -- teaching the two views every dollar in the app is built on.
        -- Negative head_count follows the death convention.
        INSERT INTO public.lot_events (
            lot_id, event_date, event_type, head_count, cause, pasture_id,
            tag_number, notes, source_record_id, created_by
        ) VALUES (
            p_pen_lot_id, p_removal_date, 'adjustment', -v_head, p_method,
            p_pasture_id, p_tag_number,
            COALESCE(p_notes, CASE WHEN p_method = 'butchered'
                                   THEN 'Feed pen — butchered'
                                   ELSE 'Feed pen — disappeared, no carcass and no check' END),
            v_id, p_recorded_by
        ) RETURNING id INTO v_ref_id;
        v_ref_kind := 'adjustment';
    END IF;

    -- record_death_with_pasture already moved the assignment. The other two
    -- paths have to, and have to record WHICH thing they did: closing leaves
    -- head_count intact, so a reversal that adds head back on top of a
    -- reopen double-counts the herd.
    IF p_method <> 'died' THEN
        IF v_assign_head - v_head = 0 THEN
            UPDATE public.lot_pasture_assignments
               SET moved_out = p_removal_date WHERE id = v_assign;
            v_closed_assn := TRUE;
        ELSE
            UPDATE public.lot_pasture_assignments
               SET head_count = v_assign_head - v_head WHERE id = v_assign;
        END IF;
    END IF;

    UPDATE public.feed_pen_removals
       SET ref_kind = v_ref_kind, ref_id = v_ref_id,
           assignment_closed = v_closed_assn,
           assignment_id = CASE WHEN p_method = 'died' THEN NULL ELSE v_assign END
     WHERE id = v_id;

    -------------------------------------------------------- the ledger out
    INSERT INTO public.feed_pen_ledger (
        pen_lot_id, source_lot_id, entry_date, head_delta, entry_kind,
        removal_line_id, created_by
    )
    SELECT p_pen_lot_id, l.source_lot_id, p_removal_date, -l.head_count,
           'removal', l.id, p_recorded_by
      FROM public.feed_pen_removal_lines l WHERE l.removal_id = v_id;

    RETURN v_id;
END;
$fn$;

COMMENT ON FUNCTION public.record_feed_pen_removal IS
    'A head leaves the feed pen sold, butchered, dead or missing. INVOKER. Freezes the pen cost against the lot each head came off BEFORE writing head math — the cost views read lot_daily_head, which this function is about to change.';

-- ---------------------------------------------------------------------
-- 11. delete_feed_pen_removal — and it really does put the cattle back
-- ---------------------------------------------------------------------
-- Derived decision 6: a removal cannot be edited, only deleted and
-- re-entered. Same posture as a saved shipment and for the same reason —
-- an edit would unwind head math that already happened.
--
-- Owner-only, by the DELETE policy: this is INVOKER, so RLS decides.
--
-- THE delete_death_event TRAP: a removal either DECREMENTED the pen's
-- assignment or CLOSED it, and those reverse differently. Closing leaves
-- head_count intact, so reopening alone restores the count; adding head
-- back on top double-counts the herd. 3 head, a death of all 3, a
-- reversal, and the lot came back with 6 — that was live in August. The
-- save writes down which one it did rather than making this infer it.
CREATE OR REPLACE FUNCTION public.delete_feed_pen_removal(p_removal_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    r          RECORD;
    v_pen_shut TIMESTAMPTZ;
    v_pen_no   TEXT;
    v_shipment UUID;
BEGIN
    SELECT * INTO r FROM public.feed_pen_removals WHERE id = p_removal_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Feed pen removal % not found.', p_removal_id;
    END IF;

    SELECT closed_at, lot_number INTO v_pen_shut, v_pen_no
      FROM public.lots WHERE id = r.pen_lot_id;
    IF v_pen_shut IS NOT NULL THEN
        RAISE EXCEPTION 'Feed pen % is closed and its year has been posted. Reopen it before reversing a removal.', v_pen_no;
    END IF;

    IF r.ref_kind = 'death' THEN
        -- The existing reversal, which already knows how to reopen an
        -- assignment its death closed outright.
        PERFORM public.delete_death_event(r.ref_id);

    ELSE
        IF r.ref_kind = 'sale' THEN
            SELECT shipment_id INTO v_shipment FROM public.sales WHERE id = r.ref_id;
            IF v_shipment IS NOT NULL THEN
                RAISE EXCEPTION 'That salvage sale has been attached to a shipment. Delete the shipment first.';
            END IF;
            DELETE FROM public.sales WHERE id = r.ref_id;
        ELSE
            DELETE FROM public.lot_events WHERE id = r.ref_id;
        END IF;

        IF r.assignment_id IS NOT NULL THEN
            IF r.assignment_closed THEN
                UPDATE public.lot_pasture_assignments
                   SET moved_out = NULL WHERE id = r.assignment_id;
            ELSE
                UPDATE public.lot_pasture_assignments
                   SET head_count = head_count + r.head_count WHERE id = r.assignment_id;
            END IF;
        END IF;
    END IF;

    -- Lines cascade from the header, and the ledger's negative rows cascade
    -- from the lines, so the attribution unwinds with it.
    DELETE FROM public.feed_pen_removals WHERE id = p_removal_id;
    RETURN TRUE;
END;
$fn$;

COMMENT ON FUNCTION public.delete_feed_pen_removal IS
    'Reverse a feed pen removal and put the cattle back. Owner-only via RLS, INVOKER. Reopens an assignment the removal closed outright rather than adding head on top of it.';

-- ---------------------------------------------------------------------
-- 12. close_feed_pen_year — June 30, and start again at zero
-- ---------------------------------------------------------------------
-- Decision 8, John: "Restart at zero at year end and net income or loss to
-- redwing books."
--
-- THE ROLLOVER IS DATED JULY 1, not June 30. The new pen's fiscal year
-- starts that day and record_lot_transfer refuses a transfer dated before
-- the destination lot existed — the floor that stops lot_daily_head
-- silently clamping an event up to a lot's first day and handing it
-- head-days for cattle that were not there. The old pen closes on the same
-- date, holding zero.
--
-- The ledger rows are written HERE and not by the trigger, because a
-- rollover transfer's source lot is the OLD PEN: derived from the transfer
-- alone every animal would come off "FEEDPEN-26" and the lot it actually
-- left would be lost. The origins carry across explicitly.
CREATE OR REPLACE FUNCTION public.close_feed_pen_year(
    p_pen_lot_id     UUID,
    p_new_pen_lot_id UUID DEFAULT NULL,
    p_rollover_date  DATE DEFAULT NULL,
    p_recorded_by    UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    v_is_pen     BOOLEAN;
    v_closed     TIMESTAMPTZ;
    v_fy         INTEGER;
    v_pen_no     TEXT;
    v_new_is_pen BOOLEAN;
    v_new_fy     INTEGER;
    v_new_shut   TIMESTAMPTZ;
    v_new_arr    DATE;
    v_new_no     TEXT;
    v_head       INTEGER;
    v_date       DATE;
    v_lines      JSONB;
    v_transfer   UUID;
    v_net        NUMERIC;
    v_feed       NUMERIC;
    v_med        NUMERIC;
    v_salvage    NUMERIC;
BEGIN
    SELECT is_feed_pen, closed_at, fiscal_year, lot_number
      INTO v_is_pen, v_closed, v_fy, v_pen_no
      FROM public.lots WHERE id = p_pen_lot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Feed pen lot % not found.', p_pen_lot_id;
    END IF;
    IF NOT COALESCE(v_is_pen, FALSE) THEN
        RAISE EXCEPTION 'Lot % is not a feed pen.', v_pen_no;
    END IF;
    IF v_closed IS NOT NULL THEN
        RAISE EXCEPTION 'Feed pen % is already closed.', v_pen_no;
    END IF;

    -- FY2026 runs to 30 Jun 2026, so FY2027 — and this rollover — begins
    -- 1 Jul 2026. The fiscal year is named for the year it ENDS.
    v_date := COALESCE(p_rollover_date, make_date(v_fy, 7, 1));
    IF v_date > public.ranch_today() THEN
        RAISE EXCEPTION 'Rollover date % is in the future (ranch today is %). The pen year cannot be closed before it ends.',
            v_date, public.ranch_today();
    END IF;

    SELECT head_current INTO v_head FROM public.lot_status WHERE lot_id = p_pen_lot_id;
    IF v_head IS NULL THEN
        RAISE EXCEPTION 'Could not read head_current for feed pen % (lot_status is keyed on lot_id, not id).', v_pen_no;
    END IF;

    ------------------------------------------------------------- roll over
    IF v_head > 0 THEN
        IF p_new_pen_lot_id IS NULL THEN
            RAISE EXCEPTION 'Feed pen % still holds % head. Create next year''s pen and name it, or remove the cattle first.',
                v_pen_no, v_head;
        END IF;
        IF p_new_pen_lot_id = p_pen_lot_id THEN
            RAISE EXCEPTION 'The pen cannot roll into itself.';
        END IF;

        SELECT is_feed_pen, fiscal_year, closed_at, arrival_date, lot_number
          INTO v_new_is_pen, v_new_fy, v_new_shut, v_new_arr, v_new_no
          FROM public.lots WHERE id = p_new_pen_lot_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Destination feed pen % not found.', p_new_pen_lot_id;
        END IF;
        IF NOT COALESCE(v_new_is_pen, FALSE) THEN
            RAISE EXCEPTION 'Lot % is not a feed pen.', v_new_no;
        END IF;
        IF v_new_shut IS NOT NULL THEN
            RAISE EXCEPTION 'Feed pen % is closed.', v_new_no;
        END IF;
        IF v_new_fy <> v_fy + 1 THEN
            RAISE EXCEPTION 'A pen rolls into the NEXT fiscal year: FY% into FY%, not FY%.',
                v_fy, v_fy + 1, v_new_fy;
        END IF;
        IF v_new_arr > v_date THEN
            RAISE EXCEPTION 'Feed pen % starts % — after the rollover date %. lot_daily_head would clamp the arrival up to its first day and hand it head-days for cattle that were not there.',
                v_new_no, v_new_arr, v_date;
        END IF;

        -- One line per pen the cattle are standing in, staying where they are.
        SELECT jsonb_agg(jsonb_build_object(
                   'from_pasture_id', a.pasture_id,
                   'to_pasture_id',   a.pasture_id,
                   'head_count',      a.head_count))
          INTO v_lines
          FROM public.lot_pasture_assignments a
         WHERE a.lot_id = p_pen_lot_id AND a.moved_out IS NULL AND a.head_count > 0;

        IF v_lines IS NULL THEN
            RAISE EXCEPTION 'Feed pen % holds % head but stands in no pasture. Fix the assignments before closing the year.',
                v_pen_no, v_head;
        END IF;

        -- Nothing here reimplements head math: the transfer RPC does the
        -- pasture sync, the transfer_out/transfer_in events and the audit.
        v_transfer := public.record_lot_transfer(
            p_source_lot_id      => p_pen_lot_id,
            p_dest_lot_id        => p_new_pen_lot_id,
            p_transfer_date      => v_date,
            p_kind               => 'fy_rollover',
            p_lines              => v_lines,
            p_basis_per_head     => 0,
            p_basis_total        => 0,
            p_basis_breakdown    => jsonb_build_object(
                                        'reason', 'fiscal year rollover',
                                        'note', 'Pen cost restarts at zero; FY net posted to Redwing.',
                                        'from_fiscal_year', v_fy,
                                        'to_fiscal_year', v_new_fy),
            p_weight_per_head_lb => NULL,
            p_weight_is_estimate => TRUE,
            p_tags               => NULL,
            p_tags_not_available => TRUE,
            p_close_source_lot   => FALSE,
            p_notes              => 'Fiscal year rollover: ' || v_pen_no || ' → ' || v_new_no,
            p_recorded_by        => p_recorded_by);

        -- Carry the ORIGINS across. This is the whole reason the ledger is a
        -- table: derived from the transfer, every one of these head would
        -- read as having come off the old pen.
        INSERT INTO public.feed_pen_ledger (
            pen_lot_id, source_lot_id, entry_date, head_delta, entry_kind,
            transfer_id, notes, created_by)
        SELECT p_pen_lot_id, x.source_lot_id, v_date, -x.head, 'rollover_out',
               v_transfer, 'Rolled to ' || v_new_no, p_recorded_by
          FROM (SELECT source_lot_id, sum(head_delta) AS head
                  FROM public.feed_pen_ledger
                 WHERE pen_lot_id = p_pen_lot_id
                 GROUP BY 1 HAVING sum(head_delta) > 0) x;

        INSERT INTO public.feed_pen_ledger (
            pen_lot_id, source_lot_id, entry_date, head_delta, entry_kind,
            transfer_id, notes, created_by)
        SELECT p_new_pen_lot_id, x.source_lot_id, v_date, x.head, 'rollover_in',
               v_transfer, 'Rolled from ' || v_pen_no, p_recorded_by
          FROM (SELECT source_lot_id, sum(head_delta) AS head
                  FROM public.feed_pen_ledger
                 WHERE pen_lot_id = p_pen_lot_id AND entry_kind <> 'rollover_out'
                 GROUP BY 1 HAVING sum(head_delta) > 0) x;
    END IF;

    -------------------------------------------------------- the year's net
    -- Read BEFORE closing: closing moves lot_daily_head's end_date, which
    -- is what the feed spread is divided over.
    SELECT COALESCE(feed_usd, 0), COALESCE(med_usd, 0),
           COALESCE(salvage_usd, 0), COALESCE(net_usd, 0)
      INTO v_feed, v_med, v_salvage, v_net
      FROM public.feed_pen_summary WHERE pen_lot_id = p_pen_lot_id;

    UPDATE public.lots
       SET closed_at = v_date::timestamptz, updated_at = now()
     WHERE id = p_pen_lot_id;

    RETURN jsonb_build_object(
        'pen_lot_id',     p_pen_lot_id,
        'pen_lot_number', v_pen_no,
        'fiscal_year',    v_fy,
        'rollover_date',  v_date,
        'head_rolled',    COALESCE(v_head, 0),
        'transfer_id',    v_transfer,
        'feed_usd',       v_feed,
        'med_usd',        v_med,
        'salvage_usd',    v_salvage,
        'net_usd',        v_net);
END;
$fn$;

COMMENT ON FUNCTION public.close_feed_pen_year IS
    'Close a feed pen''s fiscal year: roll what is standing into next year''s pen at zero and return the year net for the Redwing posting. INVOKER. The rollover is dated 1 July — the new pen does not exist before then.';

-- ---------------------------------------------------------------------
-- 13. Verify
-- ---------------------------------------------------------------------
-- Asserts rules 3, 4, 5 and 6 of the access-control section for everything
-- this migration adds, plus the two behaviours that are easy to get wrong
-- and impossible to see: a view that lost security_invoker runs as its
-- owner and bypasses RLS entirely, and a second RPC overload makes
-- PostgREST unable to resolve the function by name.
DO $verify$
DECLARE
    t          TEXT;
    v_count    INTEGER;
    v_missing  TEXT;
BEGIN
    -- the flag
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='lots' AND column_name='is_feed_pen') THEN
        RAISE EXCEPTION 'lots.is_feed_pen was not created.';
    END IF;

    -- tables: RLS on, four policies, nothing to anon
    FOREACH t IN ARRAY ARRAY['feed_pen_ledger','feed_pen_removals','feed_pen_removal_lines'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                        WHERE n.nspname='public' AND c.relname=t AND c.relrowsecurity) THEN
            RAISE EXCEPTION 'Table % has no row level security. Policies without ENABLE are decoration.', t;
        END IF;
        SELECT count(*) INTO v_count FROM pg_policies
         WHERE schemaname='public' AND tablename=t;
        IF v_count <> 4 THEN
            RAISE EXCEPTION 'Table % has % policies, expected 4 (select/insert/update/delete).', t, v_count;
        END IF;
        IF has_table_privilege('anon', 'public.'||t, 'SELECT') THEN
            RAISE EXCEPTION 'anon can read %. The publishable key is public, so anything granted to anon is public.', t;
        END IF;
    END LOOP;

    -- views: security_invoker, nothing to anon
    FOREACH t IN ARRAY ARRAY['feed_pen_source_daily','feed_pen_daily_cost',
                             'feed_pen_cost_by_source_daily','feed_pen_cost_by_source',
                             'feed_pen_summary','feed_pen_reconciliation','lot_daily_head'] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
             WHERE n.nspname='public' AND c.relname=t AND c.relkind='v'
               AND c.reloptions @> ARRAY['security_invoker=true']
        ) THEN
            RAISE EXCEPTION 'View % is missing security_invoker. Without it the view runs as its owner and bypasses RLS on every base table.', t;
        END IF;
        IF has_table_privilege('anon', 'public.'||t, 'SELECT') THEN
            RAISE EXCEPTION 'anon can read view %.', t;
        END IF;
    END LOOP;

    -- functions: exactly one overload each, and INVOKER
    FOREACH t IN ARRAY ARRAY['record_feed_pen_removal','delete_feed_pen_removal',
                             'close_feed_pen_year','record_lot_transfer'] LOOP
        SELECT count(*) INTO v_count FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='public' AND p.proname=t;
        IF v_count <> 1 THEN
            RAISE EXCEPTION 'Function % has % overloads. PostgREST resolves an RPC by argument names and cannot choose between two.', t, v_count;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                    WHERE n.nspname='public' AND p.proname=t AND p.prosecdef) THEN
            RAISE EXCEPTION 'Function % is SECURITY DEFINER. Head-math RPCs are INVOKER and must stay that way.', t;
        END IF;
    END LOOP;

    -- the transfer constraints actually moved
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid='public.lot_transfers'::regclass AND conname='lot_transfers_kind_check'
           AND pg_get_constraintdef(oid) LIKE '%feed_pen%'
    ) THEN
        RAISE EXCEPTION 'lot_transfers still refuses kind feed_pen.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid='public.lot_transfers'::regclass
           AND conname IN ('lot_transfers_basis_per_head_check','lot_transfers_basis_total_check')
           AND pg_get_constraintdef(oid) LIKE '%> (0)%'
    ) THEN
        RAISE EXCEPTION 'A lot_transfers basis check still demands a positive number; a feed pen move is zero by design.';
    END IF;

    -- lot_daily_head really did learn the third term
    IF pg_get_viewdef('public.lot_daily_head'::regclass, true) NOT LIKE '%transfer_in%' THEN
        RAISE EXCEPTION 'lot_daily_head does not reference transfer_in. A feed pen would have no head-days and every pound of its feed would land in feed_cost_unallocated.';
    END IF;

    -- the ledger trigger
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgrelid='public.lot_transfers'::regclass
                      AND tgname='feed_pen_ledger_on_transfer' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'The feed pen ledger trigger is missing; transfers into the pen would record no source lot.';
    END IF;

    -- one pen per fiscal year
    IF NOT EXISTS (SELECT 1 FROM pg_indexes
                    WHERE schemaname='public' AND indexname='lots_one_feed_pen_per_fy') THEN
        RAISE EXCEPTION 'The one-pen-per-fiscal-year index is missing.';
    END IF;

    -- and nothing already drifted
    SELECT string_agg(lot_number || ' (' || variance || ')', ', ')
      INTO v_missing FROM public.feed_pen_reconciliation WHERE variance <> 0;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Feed pen ledger does not tie to head math: %.', v_missing;
    END IF;

    RAISE NOTICE 'Feed pen verified: 3 tables x 4 policies, 7 invoker views, 4 single-overload invoker functions, ledger trigger live, nothing granted to anon.';
END
$verify$;

commit;

-- =====================================================================
-- After applying, create this fiscal year's pen. FY2027 runs
-- 1 Jul 2026 – 30 Jun 2027 and is named for the year it ENDS:
--
--   INSERT INTO public.lots (lot_number, arrival_date, fiscal_year, is_feed_pen, notes)
--   VALUES ('FEEDPEN-27', DATE '2026-07-01', 2027, TRUE,
--           'Feed pen: cripples and chronics, transferred in at $0.');
--
-- Then run supabase/migrations/20260821000300_rls_verify.sql.
-- =====================================================================
