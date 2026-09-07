-- =====================================================================
-- Feed pen: close the death gap, and let found head in
-- =====================================================================
-- Follows docs/sql/2026-09-07_feed_pen.sql, which is applied. Two holes
-- that migration left, both found the same day it went live:
--
-- 1. A PEN EXIT RECORDED ANYWHERE ELSE wrote correct head math and no
--    ledger row — the lot's own death log, or a crew entry through
--    Approvals. Pen feed then kept splitting onto a lot whose head was
--    gone. It was detected (feed_pen_reconciliation + Anomalies) but not
--    prevented. Now the exit captures itself.
--
-- 2. FOUND HEAD COULD NOT GO IN AT ALL. The design assumed every animal
--    reaches the pen by transfer from a lot that is carrying it. John has
--    three calves standing in the pen that the books have never carried
--    anywhere — written off long ago, or never counted. There was no way
--    to enter them, and lot_daily_head would not have opened a window for
--    them even if there had been.
--
-- Idempotent. Paste into the SQL editor without the begin/commit lines.
-- Run supabase/migrations/20260821000300_rls_verify.sql afterwards.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. The two halves of a removal, extracted so there is ONE of each
-- ---------------------------------------------------------------------
-- The capture trigger below has to do exactly what record_feed_pen_removal
-- does: split head across source lots, draw each lot's cost pool down by
-- head, and allocate the salvage. Copying that arithmetic into a trigger is
-- how this app ended up with two head-day implementations that disagree by
-- 29%, and two renderDoctoringTable declarations in one scope. One body,
-- two callers.

-- Largest-remainder split of p_head across the lots standing in the pen.
-- Decision 10: pro-rata on what is standing, because nobody can tell by eye
-- which animal belongs to which lot. Returns NULL when nothing is standing
-- — the caller decides what that means rather than getting a silent empty
-- split. A NULL source_lot_id is an ordinary group here: head that came
-- from no lot at all still eat, still die, and still take their share.
CREATE OR REPLACE FUNCTION public.feed_pen_split_head(
    p_pen_lot_id UUID,
    p_head       INTEGER
) RETURNS JSONB
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_catalog'
AS $fn$
WITH standing AS (
    SELECT source_lot_id, sum(head_delta) AS hd
      FROM public.feed_pen_ledger
     WHERE pen_lot_id = p_pen_lot_id
     GROUP BY 1
    HAVING sum(head_delta) > 0
), tot AS (
    SELECT sum(hd) AS pool FROM standing
), base AS (
    SELECT s.source_lot_id, s.hd,
           floor(p_head::numeric * s.hd / t.pool) AS whole,
           (p_head::numeric * s.hd / t.pool)
             - floor(p_head::numeric * s.hd / t.pool) AS frac
      FROM standing s CROSS JOIN tot t
     WHERE t.pool > 0 AND p_head > 0
), resid AS (
    SELECT p_head - COALESCE(sum(whole), 0) AS r FROM base
), ranked AS (
    SELECT source_lot_id,
           (whole + CASE WHEN row_number() OVER (ORDER BY frac DESC, hd DESC, source_lot_id)
                              <= (SELECT r FROM resid) THEN 1 ELSE 0 END)::integer AS head_count
      FROM base
)
SELECT jsonb_agg(jsonb_build_object('source_lot_id', source_lot_id,
                                    'head_count',    head_count))
  FROM ranked WHERE head_count > 0;
$fn$;

COMMENT ON FUNCTION public.feed_pen_split_head IS
    'Largest-remainder split of head across the lots standing in a feed pen. NULL when nothing is standing.';

-- The pool drawdown. Each source lot has everything the pen has spent on
-- its head to date, less what earlier removals already froze; this removal
-- takes its share by head. Drawn down this way the frozen figures can never
-- exceed what the pen actually spent, and a lot whose last head leaves
-- takes its whole remaining pool with it.
--
-- CALL THIS BEFORE THE HEAD MATH IS WRITTEN. It reads
-- feed_pen_cost_by_source -> lot_daily_head, which reads the very
-- lot_events / sales row the caller is about to insert; run it afterwards
-- and the figure frozen against the source lot is short by the head's last
-- day.
CREATE OR REPLACE FUNCTION public.feed_pen_freeze_costs(p_removal_id UUID)
RETURNS NUMERIC
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    v_pen   UUID;
    v_pool  NUMERIC;
    v_stand INTEGER;
    v_cost  NUMERIC;
    v_total NUMERIC := 0;
    rec     RECORD;
BEGIN
    SELECT pen_lot_id INTO v_pen FROM public.feed_pen_removals WHERE id = p_removal_id;
    IF v_pen IS NULL THEN
        RAISE EXCEPTION 'Feed pen removal % not found.', p_removal_id;
    END IF;

    FOR rec IN
        SELECT id, source_lot_id, head_count
          FROM public.feed_pen_removal_lines
         WHERE removal_id = p_removal_id ORDER BY id
    LOOP
        SELECT GREATEST(0, COALESCE(c.accrued_usd, 0) - COALESCE(f.frozen, 0))
          INTO v_pool
          FROM (SELECT 1) z
          -- IS NOT DISTINCT FROM, not =, so the unattributed group matches
          -- itself instead of vanishing on a NULL comparison.
          LEFT JOIN public.feed_pen_cost_by_source c
                 ON c.pen_lot_id = v_pen
                AND c.source_lot_id IS NOT DISTINCT FROM rec.source_lot_id
          LEFT JOIN LATERAL (
              SELECT sum(l2.pen_cost_usd) AS frozen
                FROM public.feed_pen_removal_lines l2
                JOIN public.feed_pen_removals r2 ON r2.id = l2.removal_id
               WHERE r2.pen_lot_id = v_pen
                 AND l2.source_lot_id IS NOT DISTINCT FROM rec.source_lot_id
                 AND l2.removal_id <> p_removal_id
          ) f ON TRUE;

        SELECT COALESCE(sum(head_delta), 0) INTO v_stand
          FROM public.feed_pen_ledger
         WHERE pen_lot_id = v_pen
           AND source_lot_id IS NOT DISTINCT FROM rec.source_lot_id;

        v_cost := CASE WHEN v_stand > 0
                       THEN round(COALESCE(v_pool, 0) * rec.head_count::numeric / v_stand::numeric, 2)
                       ELSE 0 END;

        UPDATE public.feed_pen_removal_lines SET pen_cost_usd = v_cost WHERE id = rec.id;
        v_total := v_total + v_cost;
    END LOOP;

    UPDATE public.feed_pen_removals SET pen_cost_usd = v_total WHERE id = p_removal_id;
    RETURN v_total;
END;
$fn$;

COMMENT ON FUNCTION public.feed_pen_freeze_costs IS
    'Freeze each source lot''s share of the pen cost onto a removal''s lines. MUST run before the removal''s head math is written — the cost views read lot_daily_head.';

-- Largest-remainder again, so the line shares sum EXACTLY to the check.
-- Not "round each and dump the residual on the last line" — that works too,
-- but always parks the error on whichever lot was typed last.
CREATE OR REPLACE FUNCTION public.feed_pen_allocate_proceeds(
    p_removal_id UUID,
    p_proceeds   NUMERIC
) RETURNS VOID
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    v_head  INTEGER;
    v_resid INTEGER;
BEGIN
    IF COALESCE(p_proceeds, 0) <= 0 THEN
        UPDATE public.feed_pen_removal_lines SET proceeds_usd = 0 WHERE removal_id = p_removal_id;
        RETURN;
    END IF;

    SELECT sum(head_count) INTO v_head
      FROM public.feed_pen_removal_lines WHERE removal_id = p_removal_id;
    IF COALESCE(v_head, 0) <= 0 THEN RETURN; END IF;

    SELECT round(p_proceeds * 100)::integer
           - COALESCE(sum(floor(p_proceeds * 100 * l.head_count::numeric / v_head::numeric)), 0)::integer
      INTO v_resid
      FROM public.feed_pen_removal_lines l WHERE l.removal_id = p_removal_id;

    WITH b AS (
        SELECT l.id,
               floor(p_proceeds * 100 * l.head_count::numeric / v_head::numeric) AS cents,
               (p_proceeds * 100 * l.head_count::numeric / v_head::numeric)
                 - floor(p_proceeds * 100 * l.head_count::numeric / v_head::numeric) AS frac
          FROM public.feed_pen_removal_lines l WHERE l.removal_id = p_removal_id
    ), r AS (
        SELECT id, cents, row_number() OVER (ORDER BY frac DESC, id) AS rk FROM b
    )
    UPDATE public.feed_pen_removal_lines fl
       SET proceeds_usd = (r.cents + CASE WHEN r.rk <= v_resid THEN 1 ELSE 0 END)::numeric / 100
      FROM r WHERE fl.id = r.id;
END;
$fn$;

-- ---------------------------------------------------------------------
-- 2. Mark what the app did not enter by hand
-- ---------------------------------------------------------------------
-- An auto-captured removal has no assignment_id: the death or sale that
-- triggered it owns the pasture assignment, and its own reversal restores
-- it. delete_feed_pen_removal must therefore refuse to be the one that
-- unwinds it, or the assignment is never put back.
ALTER TABLE public.feed_pen_removals
    ADD COLUMN IF NOT EXISTS captured_automatically BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.feed_pen_removals.captured_automatically IS
    'Written by the capture trigger because the exit was recorded outside Record removal. Reverse the underlying death or sale, not this row.';

-- ---------------------------------------------------------------------
-- 3. entry_kind gains 'opening' — head that came from nowhere
-- ---------------------------------------------------------------------
-- The original design assumed every animal reaches the pen by transfer
-- from a lot that is carrying it. Three calves standing in the pen today
-- are carried nowhere at all. 'opening' is the feed module's own word for
-- the same thing (feed_receipts.source = 'opening_balance'), and it keeps
-- them distinguishable from a transfer forever after.
ALTER TABLE public.feed_pen_ledger DROP CONSTRAINT IF EXISTS feed_pen_ledger_entry_kind_check;
ALTER TABLE public.feed_pen_ledger
    ADD CONSTRAINT feed_pen_ledger_entry_kind_check
    CHECK (entry_kind IN ('transfer_in','rollover_in','rollover_out','removal','opening'));

-- ---------------------------------------------------------------------
-- 3b. ...and the source lot becomes OPTIONAL
-- ---------------------------------------------------------------------
-- John, 2026-09-07: "They literally don't come from a lot, I didn't enter
-- them because there wasn't a feed pen lot at that time."
--
-- The original schema made source_lot_id NOT NULL because the whole point
-- of the ledger is attribution. But head with genuinely no origin are a
-- real category, and forcing a lot onto them would be inventing a fact —
-- the report would then read "these came off 37X" when nobody believes
-- that. NULL is the honest value and it gets its own group, exactly the
-- way the Doctoring report separates "— no receiving protocol —" from
-- "— no load record for the tag —" instead of lumping them.
--
-- The cost still lands somewhere: an unattributed head eats its share of
-- pen feed like any other, and that share shows against "— no source
-- lot —" rather than being quietly spread over the lots that DO have a
-- claim, which would overstate them.
ALTER TABLE public.feed_pen_ledger        ALTER COLUMN source_lot_id DROP NOT NULL;
ALTER TABLE public.feed_pen_removal_lines ALTER COLUMN source_lot_id DROP NOT NULL;

-- A plain UNIQUE treats every NULL as distinct, so a removal could collect
-- several "no source lot" lines. NULLS NOT DISTINCT (PG15+; this database
-- runs 17.6) makes one line per removal per source, unattributed included.
ALTER TABLE public.feed_pen_removal_lines
    DROP CONSTRAINT IF EXISTS feed_pen_removal_lines_removal_id_source_lot_id_key;
DROP INDEX IF EXISTS public.feed_pen_removal_lines_one_per_source;
CREATE UNIQUE INDEX feed_pen_removal_lines_one_per_source
    ON public.feed_pen_removal_lines (removal_id, source_lot_id) NULLS NOT DISTINCT;

-- ---------------------------------------------------------------------
-- 4. lot_daily_head: a pen's window opens on its own arrival date
-- ---------------------------------------------------------------------
-- The transfer_in term added on 2026-09-07 is not enough. Head can also
-- arrive as an 'opening' adjustment — found standing in the pen, carried
-- nowhere in the books — and an adjustment is not a start-date source. A
-- pen whose only arrival was a found animal would have no rows at all.
--
-- The new term is gated on is_feed_pen, so it cannot reach an ordinary
-- lot. For FEEDPEN-27 it opens the window on 1 July, which is right: the
-- pen exists from the first day of its fiscal year and simply holds zero
-- head until something lands.
--
-- THE `WITH` CLAUSE IS NOT OPTIONAL. CREATE OR REPLACE VIEW **CLEARS** a
-- view's reloptions when it is omitted; leaving it out here would silently
-- strip security_invoker off lot_daily_head and leave it running as its
-- owner with RLS bypassed. Caught the hard way on 2026-09-07.
CREATE OR REPLACE VIEW public.lot_daily_head
WITH (security_invoker = true) AS
WITH bounds AS (
    SELECT l.id AS lot_id,
        LEAST(
            COALESCE((SELECT min(r.receipt_date) FROM delivery_receipts r WHERE r.lot_id = l.id), '9999-12-31'::date),
            COALESCE((SELECT min(i.invoice_date)  FROM invoices        i WHERE i.lot_id = l.id), '9999-12-31'::date),
            -- The feed pen's only arrival. Provably a no-op above for
            -- every lot that arrives the ordinary way.
            COALESCE((SELECT min(e.event_date) FROM lot_events e
                       WHERE e.lot_id = l.id AND e.event_type = 'transfer_in'), '9999-12-31'::date),
            -- A feed pen can also gain head from an 'opening' adjustment —
            -- animals found standing in it that the books never carried
            -- anywhere. That is not a transfer_in, so without this term a pen
            -- whose ONLY arrival was a found animal would have no window at
            -- all: no head-days, and every pound of its feed in
            -- feed_cost_unallocated. Gated on is_feed_pen, so it cannot
            -- reach any ordinary lot.
            COALESCE(CASE WHEN l.is_feed_pen THEN l.arrival_date END, '9999-12-31'::date)
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

ALTER VIEW public.lot_daily_head SET (security_invoker = true);

-- ---------------------------------------------------------------------
-- 5. record_feed_pen_removal, rebuilt on the shared halves
-- ---------------------------------------------------------------------
-- Same function, three changes: it turns the capture triggers off for its
-- own writes, and the freeze and salvage blocks are now calls to the two
-- functions above instead of inline copies. Everything else is untouched.
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
    v_standing    INTEGER;
    rec           RECORD;
BEGIN
    -- The capture triggers exist to catch a pen exit recorded ANYWHERE ELSE.
    -- The rows this function is about to write are that exit, so they must
    -- not be captured a second time. Transaction-local, so it cannot leak
    -- into another statement even if this one raises.
    PERFORM set_config('jfr.feed_pen_capture', 'off', TRUE);

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
         WHERE (e->>'head_count') IS NULL
            OR (e->>'head_count')::integer <= 0
    ) THEN
        -- source_lot_id may be null: head that came off no lot at all.
        RAISE EXCEPTION 'Every line needs a positive head count.';
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
         WHERE pen_lot_id = p_pen_lot_id
           AND source_lot_id IS NOT DISTINCT FROM rec.src;
        IF rec.hd > v_standing THEN
            RAISE EXCEPTION '% has % head standing in the pen; the removal draws %.',
                COALESCE((SELECT lot_number FROM public.lots WHERE id = rec.src),
                         'Head with no source lot'), v_standing, rec.hd;
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
    -- off this lot cost, at the date they left. The pool drawdown lives in
    -- feed_pen_freeze_costs so the capture triggers run the SAME arithmetic
    -- — a second copy is how this app got two head-day implementations that
    -- disagree by 29%.
    PERFORM public.feed_pen_freeze_costs(v_id);

    ------------------------------------------------- allocate the salvage
    -- Largest-remainder, so the line shares sum EXACTLY to the check.
    -- Shared with the capture triggers for the same reason as above.
    PERFORM public.feed_pen_allocate_proceeds(v_id, v_proceeds);

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

    PERFORM set_config('jfr.feed_pen_capture', 'on', TRUE);
    RETURN v_id;
END;
$fn$;

-- ---------------------------------------------------------------------
-- 6. The capture: a pen exit recorded anywhere else attributes itself
-- ---------------------------------------------------------------------
-- BEFORE INSERT, not AFTER, and that is the whole subtlety. The frozen pen
-- cost must be computed while this death or sale is still INVISIBLE to
-- lot_daily_head — the same ordering record_feed_pen_removal follows. An
-- AFTER trigger would freeze a figure short by the head's last day.
-- NEW.id is already populated in a BEFORE INSERT trigger (the column
-- default has been applied), so ref_id can point at a row that does not
-- exist yet; nothing references lot_events or sales by foreign key.
--
-- It does NOT set assignment_id. The death or sale owns the pasture
-- assignment and its own reversal restores it — see section 7.
CREATE OR REPLACE FUNCTION public.feed_pen_capture_exit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    v_lot     UUID;
    v_date    DATE;
    v_head    INTEGER;
    v_method  TEXT;
    v_refkind TEXT;
    v_past    UUID;
    v_money   NUMERIC := 0;
    v_buyer   TEXT;
    v_wt      NUMERIC;
    v_tag     TEXT;
    v_cause   TEXT;
    v_lines   JSONB;
    v_id      UUID;
    v_pen     BOOLEAN;
    v_penno   TEXT;
BEGIN
    -- record_feed_pen_removal already wrote the removal; the row being
    -- inserted IS that removal's head math, not a second exit.
    IF COALESCE(current_setting('jfr.feed_pen_capture', TRUE), 'on') = 'off' THEN
        RETURN NEW;
    END IF;

    IF TG_TABLE_NAME = 'lot_events' THEN
        v_lot   := NEW.lot_id;          v_date  := NEW.event_date;
        v_head  := abs(NEW.head_count); v_method := 'died';
        v_refkind := 'death';           v_past  := NEW.pasture_id;
        v_tag   := NEW.tag_number;      v_cause := NEW.cause;
    ELSE
        v_lot   := NEW.lot_id;          v_date  := NEW.sale_date;
        v_head  := NEW.head_count;      v_method := 'sold';
        v_refkind := 'sale';
        v_money := COALESCE(NEW.total_price, 0);
        v_buyer := NEW.buyer;           v_wt    := NEW.net_weight_lb;
    END IF;

    SELECT is_feed_pen, lot_number INTO v_pen, v_penno
      FROM public.lots WHERE id = v_lot;
    IF NOT COALESCE(v_pen, FALSE) THEN RETURN NEW; END IF;
    IF COALESCE(v_head, 0) <= 0 THEN RETURN NEW; END IF;

    -- Decision 10, the mixed-pasture rule: pro-rata on what is standing.
    v_lines := public.feed_pen_split_head(v_lot, v_head);
    IF v_lines IS NULL THEN
        -- Head math is still correct and the animal is still recorded; only
        -- the attribution is impossible. Never block the entry over it —
        -- this is animal health data. feed_pen_reconciliation and the
        -- Anomalies report will show the variance.
        RAISE WARNING 'Feed pen %: % head left with no source lot standing in the ledger. Head math is recorded; attribution is not, and feed_pen_reconciliation will flag it.',
            v_penno, v_head;
        RETURN NEW;
    END IF;

    -- A sale carries no pasture. Take the pen's fullest open assignment.
    IF v_past IS NULL THEN
        SELECT pasture_id INTO v_past
          FROM public.lot_pasture_assignments
         WHERE lot_id = v_lot AND moved_out IS NULL
         ORDER BY head_count DESC, id LIMIT 1;
    END IF;
    IF v_past IS NULL THEN
        RAISE WARNING 'Feed pen % stands in no pasture; exit attribution skipped and feed_pen_reconciliation will flag it.', v_penno;
        RETURN NEW;
    END IF;

    INSERT INTO public.feed_pen_removals (
        pen_lot_id, removal_date, method, pasture_id, head_count,
        proceeds_usd, buyer, net_weight_lb, tag_number, cause, notes,
        ref_kind, ref_id, assignment_id, assignment_closed,
        captured_automatically, created_by
    ) VALUES (
        v_lot, v_date, v_method, v_past, v_head,
        v_money, v_buyer, v_wt, v_tag, v_cause,
        'Captured automatically — recorded outside Record removal, so the pen ledger was written here.',
        v_refkind, NEW.id, NULL, FALSE,
        TRUE, NEW.created_by
    ) RETURNING id INTO v_id;

    INSERT INTO public.feed_pen_removal_lines (removal_id, source_lot_id, head_count)
    SELECT v_id, (e->>'source_lot_id')::uuid, (e->>'head_count')::integer
      FROM jsonb_array_elements(v_lines) e;

    -- Before the head math, which is the point of the BEFORE trigger.
    PERFORM public.feed_pen_freeze_costs(v_id);
    PERFORM public.feed_pen_allocate_proceeds(v_id, v_money);

    INSERT INTO public.feed_pen_ledger (
        pen_lot_id, source_lot_id, entry_date, head_delta, entry_kind,
        removal_line_id, created_by)
    SELECT v_lot, l.source_lot_id, v_date, -l.head_count, 'removal', l.id, NEW.created_by
      FROM public.feed_pen_removal_lines l WHERE l.removal_id = v_id;

    RETURN NEW;
END;
$fn$;

-- Deaths only on lot_events: the WHEN clause means PL/pgSQL is not entered
-- at all for an arrival, sale, transfer or adjustment, so the hottest audit
-- table in the app pays nothing. A negative 'adjustment' is deliberately
-- NOT captured — record_feed_pen_removal is the only thing that writes one.
DROP TRIGGER IF EXISTS feed_pen_capture_death ON public.lot_events;
CREATE TRIGGER feed_pen_capture_death
    BEFORE INSERT ON public.lot_events
    FOR EACH ROW WHEN (NEW.event_type = 'death')
    EXECUTE FUNCTION public.feed_pen_capture_exit();

-- Sales cannot be filtered by a WHEN clause (it cannot reach another
-- table), so this costs one indexed lookup on lots per sale row. A
-- shipment save inserts a handful; that is nothing.
DROP TRIGGER IF EXISTS feed_pen_capture_sale ON public.sales;
CREATE TRIGGER feed_pen_capture_sale
    BEFORE INSERT ON public.sales
    FOR EACH ROW EXECUTE FUNCTION public.feed_pen_capture_exit();

-- ---------------------------------------------------------------------
-- 7. And it unwinds when the death or sale is reversed
-- ---------------------------------------------------------------------
-- delete_death_event, the shipment reversal and the ordinary sale delete
-- all remove the underlying row. The attribution has to follow it, or the
-- ledger is left claiming head that head math no longer has — the same
-- drift in the other direction. Lines and ledger rows cascade from the
-- removal header.
CREATE OR REPLACE FUNCTION public.feed_pen_cleanup_exit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
BEGIN
    -- lot_events covers both shapes a removal can wear there: a death, and
    -- the negative 'adjustment' that butchered and missing are filed as.
    DELETE FROM public.feed_pen_removals
     WHERE ref_id = OLD.id
       AND ref_kind = ANY (CASE TG_TABLE_NAME
                             WHEN 'sales' THEN ARRAY['sale']
                             ELSE ARRAY['death','adjustment'] END);
    RETURN OLD;
END;
$fn$;

DROP TRIGGER IF EXISTS feed_pen_cleanup_death ON public.lot_events;
CREATE TRIGGER feed_pen_cleanup_death
    AFTER DELETE ON public.lot_events
    FOR EACH ROW WHEN (OLD.event_type IN ('death','adjustment'))
    EXECUTE FUNCTION public.feed_pen_cleanup_exit();

DROP TRIGGER IF EXISTS feed_pen_cleanup_sale ON public.sales;
CREATE TRIGGER feed_pen_cleanup_sale
    AFTER DELETE ON public.sales
    FOR EACH ROW EXECUTE FUNCTION public.feed_pen_cleanup_exit();

-- ---------------------------------------------------------------------
-- 8. delete_feed_pen_removal refuses what it cannot properly unwind
-- ---------------------------------------------------------------------
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

    -- An auto-captured removal did NOT touch the pasture assignment: the
    -- death or sale that triggered it owns that, and its own reversal is
    -- what puts the head back. Unwinding from this end would delete the
    -- underlying row and leave the assignment short — head math and
    -- pastures disagreeing, which is the one thing this module exists to
    -- prevent. The cleanup trigger removes this row when that reversal
    -- runs, so there is nothing to do here but say where to go.
    IF r.captured_automatically THEN
        RAISE EXCEPTION 'That % was recorded outside Record removal, so reverse it where it was entered — the pen attribution is removed automatically when you do.',
            CASE r.ref_kind WHEN 'sale' THEN 'sale' ELSE 'death' END;
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

-- ---------------------------------------------------------------------
-- 9. record_feed_pen_opening — head found standing in the pen
-- ---------------------------------------------------------------------
-- Three calves are in the pen today that the books have never carried
-- anywhere: written off long ago, or never counted. They cannot arrive by
-- transfer, because no lot is holding them to transfer them out of.
--
-- WHY A SOURCE LOT IS STILL REQUIRED. Every dollar the pen spends is split
-- by the ledger, and the ledger splits by source lot — head with no source
-- lot would sit in the pen eating feed that could be attributed to nobody,
-- and feed_pen_reconciliation would never tie. Naming the most likely lot
-- is the honest answer, and it is CHEAP TO BE WRONG: decision 5 makes pen
-- cost TRACKED, not charged, so this touches that lot's books in no way at
-- all. It says "the salvage we are spending is on cattle that came off
-- 37X", which is a management fact, not an accounting entry.
--
-- WHY A POSITIVE 'adjustment' AND NOT A RECEIPT OR AN INVOICE. Both of
-- those feed lot_daily_head's GREATEST(invoiced, received) and would give
-- the pen a head_in and a purchase cost it never had. 'adjustment' is
-- already signed and already summed by lot_status and lot_daily_head.
CREATE OR REPLACE FUNCTION public.record_feed_pen_opening(
    p_pen_lot_id    UUID,
    p_pasture_id    UUID,
    p_head          INTEGER,
    p_source_lot_id UUID,
    p_event_date    DATE DEFAULT NULL,
    p_notes         TEXT DEFAULT NULL,
    p_recorded_by   UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    v_is_pen   BOOLEAN;
    v_closed   TIMESTAMPTZ;
    v_pen_no   TEXT;
    v_arrival  DATE;
    v_src_no   TEXT;
    v_date     DATE;
    v_assign   UUID;
    v_event    UUID;
BEGIN
    SELECT is_feed_pen, closed_at, lot_number, arrival_date
      INTO v_is_pen, v_closed, v_pen_no, v_arrival
      FROM public.lots WHERE id = p_pen_lot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Feed pen lot % not found.', p_pen_lot_id;
    END IF;
    IF NOT COALESCE(v_is_pen, FALSE) THEN
        RAISE EXCEPTION 'Lot % is not a feed pen. Head cannot be conjured onto an ordinary lot — correct its receipts or invoices instead.', v_pen_no;
    END IF;
    IF v_closed IS NOT NULL THEN
        RAISE EXCEPTION 'Feed pen % is closed for the fiscal year.', v_pen_no;
    END IF;
    IF COALESCE(p_head, 0) <= 0 THEN
        RAISE EXCEPTION 'Head must be positive (got %).', p_head;
    END IF;

    -- A source lot is OPTIONAL. Some head genuinely came off no lot: they
    -- were never entered anywhere because there was no feed pen to put them
    -- in. Naming a lot they did not come from would be inventing a fact, so
    -- NULL is allowed and gets its own group on the cost report. A lot that
    -- IS named must exist, though — a typo'd uuid must not become a silent
    -- unattributed row.
    IF p_source_lot_id IS NOT NULL THEN
        SELECT lot_number INTO v_src_no FROM public.lots WHERE id = p_source_lot_id;
        IF v_src_no IS NULL THEN
            RAISE EXCEPTION 'Source lot % not found. Leave it null if these cattle came off no lot at all.', p_source_lot_id;
        END IF;
    END IF;

    v_date := COALESCE(p_event_date, public.ranch_today());
    IF v_date > public.ranch_today() THEN
        RAISE EXCEPTION 'Date % is in the future (ranch today is %).', v_date, public.ranch_today();
    END IF;
    IF v_date < v_arrival THEN
        RAISE EXCEPTION 'Date % is before feed pen % existed (%). lot_daily_head would clamp it up to the pen''s first day and charge it feed for cattle that were not there.',
            v_date, v_pen_no, v_arrival;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.pastures WHERE id = p_pasture_id) THEN
        RAISE EXCEPTION 'Pasture % not found.', p_pasture_id;
    END IF;

    INSERT INTO public.lot_events (
        lot_id, event_date, event_type, head_count, cause, pasture_id, notes, created_by
    ) VALUES (
        p_pen_lot_id, v_date, 'adjustment', p_head, 'opening', p_pasture_id,
        COALESCE(p_notes,
                 'Found standing in the feed pen and carried nowhere in the books. '
                 || CASE WHEN v_src_no IS NULL
                         THEN 'Came off no lot; pen cost is reported unattributed.'
                         ELSE 'Attributed to ' || v_src_no || ' for cost tracking only.' END),
        p_recorded_by
    ) RETURNING id INTO v_event;

    SELECT id INTO v_assign FROM public.lot_pasture_assignments
     WHERE lot_id = p_pen_lot_id AND pasture_id = p_pasture_id AND moved_out IS NULL;
    IF v_assign IS NULL THEN
        INSERT INTO public.lot_pasture_assignments (
            lot_id, pasture_id, head_count, moved_in, notes, recorded_by
        ) VALUES (
            p_pen_lot_id, p_pasture_id, p_head, v_date,
            'Opened by feed pen opening entry ' || v_event::text, p_recorded_by
        );
    ELSE
        UPDATE public.lot_pasture_assignments
           SET head_count = head_count + p_head WHERE id = v_assign;
    END IF;

    INSERT INTO public.feed_pen_ledger (
        pen_lot_id, source_lot_id, entry_date, head_delta, entry_kind,
        notes, created_by
    ) VALUES (
        p_pen_lot_id, p_source_lot_id, v_date, p_head, 'opening',
        CASE WHEN p_source_lot_id IS NULL
             THEN 'Found in the pen, never carried in inventory and off no lot.'
             ELSE 'Found in the pen, never carried in inventory. Source lot is an attribution, not a charge.' END,
        p_recorded_by
    );

    RETURN v_event;
END;
$fn$;

COMMENT ON FUNCTION public.record_feed_pen_opening IS
    'Head found standing in the feed pen that the books never carried. Positive adjustment + assignment + ledger row, atomically. INVOKER. The source lot is attribution only and is never charged.';



-- ---------------------------------------------------------------------
-- 11. The two views that join on the source lot
-- ---------------------------------------------------------------------
-- Both matched with `=`, which drops the unattributed group silently: NULL
-- = NULL is not true. IS NOT DISTINCT FROM makes it match itself, so head
-- that came off no lot get their own row and their own share of the feed
-- instead of disappearing out of a report that is supposed to add up.
--
-- CREATE OR REPLACE, not DROP CASCADE — feed_pen_cost_by_source_daily and
-- feed_pen_cost_by_source hang off the first of these. Column lists and
-- types are unchanged, so replace works, and THE `WITH` CLAUSE IS REPEATED
-- because omitting it clears security_invoker.
CREATE OR REPLACE VIEW public.feed_pen_source_daily
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
    ON e.pen_lot_id = g.pen_lot_id
   AND e.source_lot_id IS NOT DISTINCT FROM g.source_lot_id
   AND e.d = g.as_of_date;

CREATE OR REPLACE VIEW public.feed_pen_cost_by_source_daily
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
CREATE OR REPLACE VIEW public.feed_pen_cost_by_source
WITH (security_invoker = true) AS
WITH src AS (
    SELECT DISTINCT g.pen_lot_id, g.source_lot_id FROM public.feed_pen_ledger g
)
SELECT s.pen_lot_id,
       pen.lot_number   AS pen_lot_number,
       pen.fiscal_year  AS pen_fiscal_year,
       s.source_lot_id,
       COALESCE(sl.lot_number, '— no source lot —') AS source_lot_number,
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
  LEFT JOIN public.lots sl ON sl.id = s.source_lot_id
  LEFT JOIN LATERAL (
      SELECT sum(g.head_delta) AS head_in
        FROM public.feed_pen_ledger g
       WHERE g.pen_lot_id = s.pen_lot_id
         AND g.source_lot_id IS NOT DISTINCT FROM s.source_lot_id
         AND g.head_delta > 0
  ) arrived ON TRUE
  LEFT JOIN LATERAL (
      SELECT sum(g.head_delta) AS head_now
        FROM public.feed_pen_ledger g
       WHERE g.pen_lot_id = s.pen_lot_id
         AND g.source_lot_id IS NOT DISTINCT FROM s.source_lot_id
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
       WHERE r.pen_lot_id = s.pen_lot_id
         AND l.source_lot_id IS NOT DISTINCT FROM s.source_lot_id
  ) rem ON TRUE
  LEFT JOIN LATERAL (
      SELECT sum(d.feed_usd) AS feed_usd, sum(d.med_usd) AS med_usd
        FROM public.feed_pen_cost_by_source_daily d
       WHERE d.pen_lot_id = s.pen_lot_id
         AND d.source_lot_id IS NOT DISTINCT FROM s.source_lot_id
  ) acc ON TRUE;

ALTER VIEW public.feed_pen_source_daily  SET (security_invoker = true);
ALTER VIEW public.feed_pen_cost_by_source SET (security_invoker = true);

COMMENT ON VIEW public.feed_pen_cost_by_source IS
    'What the feed pen cattle off each lot cost. frozen_removed_usd is the figure frozen at the date removed. Tracked, never posted to the source lot. Head that came off no lot at all group under "— no source lot —".';

-- ---------------------------------------------------------------------
-- 12. Verify
-- ---------------------------------------------------------------------
DO $verify$
DECLARE
    t       TEXT;
    v_count INTEGER;
    v_bad   TEXT;
BEGIN
    -- the shared halves exist, exactly once each, and INVOKER
    FOREACH t IN ARRAY ARRAY['feed_pen_split_head','feed_pen_freeze_costs',
                             'feed_pen_allocate_proceeds','feed_pen_capture_exit',
                             'feed_pen_cleanup_exit','record_feed_pen_opening',
                             'record_feed_pen_removal','delete_feed_pen_removal'] LOOP
        SELECT count(*) INTO v_count FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='public' AND p.proname=t;
        IF v_count <> 1 THEN
            RAISE EXCEPTION 'Function % has % overloads; PostgREST resolves an RPC by argument names and cannot choose between two.', t, v_count;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                    WHERE n.nspname='public' AND p.proname=t AND p.prosecdef) THEN
            RAISE EXCEPTION 'Function % is SECURITY DEFINER. Head-math RPCs are INVOKER and must stay that way.', t;
        END IF;
    END LOOP;

    -- record_feed_pen_removal really does call the shared halves, rather
    -- than keeping the old inline copies alongside them
    IF (SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='public' AND p.proname='record_feed_pen_removal')
       NOT LIKE '%feed_pen_freeze_costs%' THEN
        RAISE EXCEPTION 'record_feed_pen_removal is not calling feed_pen_freeze_costs — two copies of the pool drawdown are live.';
    END IF;
    IF (SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='public' AND p.proname='record_feed_pen_removal')
       NOT LIKE '%feed_pen_capture%' THEN
        RAISE EXCEPTION 'record_feed_pen_removal does not disable the capture triggers; its own head math would be captured a second time.';
    END IF;

    -- four triggers, and the two capture ones must be BEFORE
    FOR t IN SELECT unnest(ARRAY['feed_pen_capture_death','feed_pen_capture_sale',
                                 'feed_pen_cleanup_death','feed_pen_cleanup_sale']) LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = t AND NOT tgisinternal) THEN
            RAISE EXCEPTION 'Trigger % is missing.', t;
        END IF;
    END LOOP;
    -- tgtype bit 1 = BEFORE. An AFTER capture would freeze a cost short by
    -- the head's last day, silently.
    IF EXISTS (SELECT 1 FROM pg_trigger
                WHERE tgname IN ('feed_pen_capture_death','feed_pen_capture_sale')
                  AND NOT tgisinternal AND (tgtype & 2) = 0) THEN
        RAISE EXCEPTION 'A feed pen capture trigger is not BEFORE INSERT. The frozen cost would be computed after the exit is visible to lot_daily_head and would be short by a day.';
    END IF;

    -- lot_daily_head kept security_invoker and learned the pen term
    IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                    WHERE n.nspname='public' AND c.relname='lot_daily_head'
                      AND c.reloptions @> ARRAY['security_invoker=true']) THEN
        RAISE EXCEPTION 'lot_daily_head lost security_invoker. CREATE OR REPLACE VIEW clears reloptions when WITH is omitted.';
    END IF;
    IF pg_get_viewdef('public.lot_daily_head'::regclass, true) NOT LIKE '%is_feed_pen%' THEN
        RAISE EXCEPTION 'lot_daily_head does not reference is_feed_pen; a pen holding only found head would have no head-days.';
    END IF;

    -- the new column and the widened check
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='feed_pen_removals'
                      AND column_name='captured_automatically') THEN
        RAISE EXCEPTION 'feed_pen_removals.captured_automatically is missing.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid='public.feed_pen_ledger'::regclass
                      AND conname='feed_pen_ledger_entry_kind_check'
                      AND pg_get_constraintdef(oid) LIKE '%opening%') THEN
        RAISE EXCEPTION 'feed_pen_ledger still refuses entry_kind opening.';
    END IF;

    -- and nothing drifted while we were in here
    SELECT string_agg(lot_number || ' (' || variance || ')', ', ')
      INTO v_bad FROM public.feed_pen_reconciliation WHERE variance <> 0;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Feed pen ledger does not tie to head math: %.', v_bad;
    END IF;

    RAISE NOTICE 'Feed pen gaps closed: 8 single-overload invoker functions, 4 triggers (both captures BEFORE INSERT), lot_daily_head still security_invoker and pen-aware, ledger ties.';
END
$verify$;

commit;
