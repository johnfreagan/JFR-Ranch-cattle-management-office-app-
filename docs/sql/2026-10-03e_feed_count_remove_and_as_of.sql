-- =====================================================================
-- Feed counts: remove a posted count, and book as of the count date
-- =====================================================================
-- STATUS: Applied 2026-10-03 on John's approval ("approved and you run sql"),
-- through apply_migration with begin/commit stripped. Verified afterwards:
-- md5(prosrc) matches this file for all four (feed_book_as_of
-- 16f26c9d83858be4e886d24cbf1c5f43, post_feed_count
-- 878c9567c1c3998cc8e9eb564d760aff, void_feed_count
-- 6ded7ff28d0d85a657177e5d00a39caf, feed_guard_count_delete
-- 613e778bf53f03999399cf75999fa591); all SECURITY INVOKER with search_path
-- public, pg_temp; no EXECUTE for anon or PUBLIC; the rls_verify checks
-- (RLS on, policies present, anon grants, definer functions, view
-- security_invoker) return no problems.
--
-- 2026-10-03. John counted Bag Storage on 10/1 before the truck loaded,
-- keyed it on 10/3, found mistakes in what he keyed, and had no way to
-- take the count back out. Two holes, one file.
--
-- HOLE 1 - A POSTED COUNT HAD NO UNDO. The only precedent is the one-off
-- script 2026-09-01_reverse_ton_pound_count.sql. void_feed_count() is that
-- script made general, owner only:
--   * every usage the count posted goes back through delete_feed_usage(),
--     so the pounds return to the exact layers they came off;
--   * every "found" layer comes off through delete_feed_receipt(), which
--     refuses if any of it has been fed since;
--   * the count row is KEPT with status 'voided', who, when and why. The
--     lines keep the book and variance they posted with. A correction to
--     the books leaves a note; it does not vanish.
-- Edit is remove and re-enter. There is no edit-in-place path to keep in
-- step with FIFO.
--
-- The consumption rows a mineral count splits across lots are not linked
-- from the count line (the line records the aggregate). They are found by
-- source = 'count', same location, same item, and created_at = the
-- count's posted_at: post_feed_count runs in one transaction, so now() is
-- one value for the count and everything it wrote. Checked 2026-10-03
-- against all six posted counts: the rows found that way sum to the
-- count's own short variance on every one. The function re-proves that
-- sum before it reverses anything and raises if it does not tie.
--
-- HOLE 2 - BOOK WAS "RIGHT NOW", NOT "ON THE COUNT DATE". post_feed_count
-- compared the counted pounds to SUM(qty_lb_remaining) at the moment of
-- posting. Count on the 1st, key it on the 3rd, and everything fed or
-- delivered in between lands on the wrong side of the count.
--
-- feed_book_as_of(location, date) is the book at the START of that date
-- (John, 2026-10-03: the count is taken before the truck loads). It is
-- today's layers, plus what usage dated on or after that day drew from
-- them, minus what receipts dated on or after that day laid down. Two
-- kinds of row dated ON the count date still count as before it:
--   * source 'count' usage and 'count_adjustment' receipts - an earlier
--     count's own corrections, which state what was there;
--   * 'opening_balance' receipts - they state what was there to begin with.
-- The count screen reads the same function, so the sheet and the post
-- agree. A weekly hand entry is dated by its usage_date (period end) and
-- is all-before or all-after; it is not split across a count.
--
-- Also: a raw DELETE of a posted count (owner RLS allows it) cascaded the
-- lines away and left its adjustments standing with nothing pointing at
-- them. A trigger now refuses; only a draft can be deleted.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. A count can be voided
-- ---------------------------------------------------------------------
ALTER TABLE public.feed_counts
    ADD COLUMN IF NOT EXISTS voided_at   timestamptz,
    ADD COLUMN IF NOT EXISTS voided_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS void_reason text;

ALTER TABLE public.feed_counts DROP CONSTRAINT IF EXISTS feed_counts_status_check;
ALTER TABLE public.feed_counts ADD CONSTRAINT feed_counts_status_check
    CHECK (status = ANY (ARRAY['draft'::text, 'posted'::text, 'voided'::text]));


-- ---------------------------------------------------------------------
-- 2. Book at the start of a date
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.feed_book_as_of(p_location_id uuid, p_count_date date)
RETURNS TABLE (
    item_id          uuid,
    book_qty_lb      numeric,
    current_qty_lb   numeric,
    later_usage_lb   numeric,
    later_receipt_lb numeric
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
    WITH cur AS (
        SELECT r.item_id,
               SUM(r.qty_lb_remaining) AS lb,
               SUM(r.qty_lb) FILTER (
                   WHERE r.receipt_date > p_count_date
                      OR (r.receipt_date = p_count_date
                          AND COALESCE(r.source, '') NOT IN ('count_adjustment', 'opening_balance'))
               ) AS later_in
          FROM public.feed_receipts r
         WHERE r.location_id = p_location_id
         GROUP BY r.item_id
    ),
    drawn AS (
        -- Only pounds that came off a layer. A short draw (receipt_id NULL)
        -- never reduced the book, so there is nothing to put back.
        SELECT u.item_id, SUM(c.qty_lb) AS lb
          FROM public.feed_usage u
          JOIN public.feed_usage_costs c ON c.usage_id = u.id
         WHERE u.from_location_id = p_location_id
           AND c.receipt_id IS NOT NULL
           AND (u.usage_date > p_count_date
                OR (u.usage_date = p_count_date AND COALESCE(u.source, '') <> 'count'))
         GROUP BY u.item_id
    )
    SELECT cur.item_id,
           cur.lb + COALESCE(drawn.lb, 0) - COALESCE(cur.later_in, 0),
           cur.lb,
           COALESCE(drawn.lb, 0),
           COALESCE(cur.later_in, 0)
      FROM cur
      LEFT JOIN drawn ON drawn.item_id = cur.item_id
$fn$;

REVOKE ALL ON FUNCTION public.feed_book_as_of(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.feed_book_as_of(uuid, date) TO authenticated;


-- ---------------------------------------------------------------------
-- 3. post_feed_count - book is as of the count date
-- ---------------------------------------------------------------------
-- The body is 2026-08-28_feed_decisions.sql section 6 with two changes:
-- v_book comes from feed_book_as_of(), and a voided count cannot be
-- posted again. Everything else is unchanged.
CREATE OR REPLACE FUNCTION public.post_feed_count(p_count_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_c          record;
    v_line       record;
    v_item       record;
    v_book       numeric;
    v_var        numeric;
    v_last_cost  numeric;
    v_usage_id   uuid;
    v_receipt_id uuid;
    v_posted     integer := 0;

    v_prev_count date;
    v_period     date;
    v_total_hd   numeric;
    v_lot_ids    uuid[];
    v_hd         numeric[];
    v_floor      numeric[];
    v_rem        numeric[];
    v_n          integer;
    v_i          integer;
    v_cents      integer;
    v_share      numeric;
    v_order      integer[];
BEGIN
    SELECT * INTO v_c FROM public.feed_counts WHERE id = p_count_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'post_feed_count: count % not found.', p_count_id;
    END IF;
    IF v_c.status = 'posted' THEN
        RAISE EXCEPTION 'post_feed_count: this count was already posted. Start a new one.';
    END IF;
    IF v_c.status = 'voided' THEN
        RAISE EXCEPTION 'post_feed_count: this count was removed. Start a new one.';
    END IF;

    -- The window a consumption variance covers: since the previous posted
    -- count on this location.
    SELECT max(c.count_date) INTO v_prev_count
      FROM public.feed_counts c
     WHERE c.location_id = v_c.location_id
       AND c.status = 'posted'
       AND c.count_date < v_c.count_date;

    FOR v_line IN
        SELECT * FROM public.feed_count_lines WHERE count_id = p_count_id
    LOOP
        SELECT * INTO v_item FROM public.feed_items WHERE id = v_line.item_id;

        -- Book at the START of the count date, not at the moment of
        -- posting. A count keyed days late must not be compared to a book
        -- that has moved on since.
        SELECT COALESCE((
                   SELECT b.book_qty_lb
                     FROM public.feed_book_as_of(v_c.location_id, v_c.count_date) b
                    WHERE b.item_id = v_line.item_id), 0)
          INTO v_book;

        v_var := v_line.counted_qty_lb - v_book;
        v_usage_id := NULL;
        v_receipt_id := NULL;

        IF v_var < 0 AND v_item.count_variance_meaning = 'consumption' THEN
            -- ---------- mineral: the count IS the usage record ----------
            v_period := COALESCE(
                v_prev_count + 1,
                (SELECT min(r.receipt_date) FROM public.feed_receipts r
                  WHERE r.item_id = v_line.item_id AND r.location_id = v_c.location_id),
                v_c.count_date);
            IF v_period > v_c.count_date THEN
                v_period := v_c.count_date;
            END IF;

            SELECT array_agg(t.lot_id ORDER BY t.lot_id),
                   array_agg(t.head_days ORDER BY t.lot_id),
                   SUM(t.head_days)
              INTO v_lot_ids, v_hd, v_total_hd
              FROM (
                    SELECT d.lot_id, SUM(d.head_on_hand)::numeric AS head_days
                      FROM public.lot_daily_head d
                      JOIN public.lots l ON l.id = d.lot_id
                     WHERE d.as_of_date BETWEEN v_period AND v_c.count_date
                       AND l.lot_number NOT LIKE 'TEST\_%'
                       AND l.lot_number NOT LIKE 'TEST-%'
                     GROUP BY d.lot_id
                    HAVING SUM(d.head_on_hand) > 0
                   ) t;

            IF v_total_hd IS NULL OR v_total_hd <= 0 THEN
                -- Nothing to spread it over. Do NOT silently drop it: fall
                -- back to an adjustment so the pounds still leave the bay
                -- and the reason says why.
                v_usage_id := public.post_feed_usage(
                    p_item_id          => v_line.item_id,
                    p_from_location_id => v_c.location_id,
                    p_qty_lb           => -v_var,
                    p_destination_type => 'adjustment',
                    p_period_start     => v_period,
                    p_period_end       => v_c.count_date,
                    p_usage_date       => v_c.count_date,
                    p_source           => 'count',
                    p_reason           => 'Count ' || v_c.count_date::text
                                          || ' - consumption, but no head-days in the window to allocate over');
                v_posted := v_posted + 1;
            ELSE
                v_n := array_length(v_lot_ids, 1);

                -- Largest remainder, to the cent of a pound, so the parts
                -- sum EXACTLY to the variance. Not "round each and dump the
                -- residual on the last lot" - that always parks the error on
                -- whichever lot sorted last.
                v_floor := ARRAY[]::numeric[];
                v_rem   := ARRAY[]::numeric[];
                FOR v_i IN 1 .. v_n LOOP
                    v_share := (-v_var) * v_hd[v_i] / v_total_hd;
                    v_floor := v_floor || FLOOR(v_share * 100) / 100;
                    v_rem   := v_rem   || (v_share - FLOOR(v_share * 100) / 100);
                END LOOP;

                v_cents := ROUND(((-v_var) - (SELECT SUM(x) FROM unnest(v_floor) x)) * 100)::integer;

                SELECT array_agg(i ORDER BY v_rem[i] DESC, i) INTO v_order
                  FROM generate_series(1, v_n) i;

                FOR v_i IN 1 .. GREATEST(v_cents, 0) LOOP
                    v_floor[v_order[v_i]] := v_floor[v_order[v_i]] + 0.01;
                END LOOP;

                FOR v_i IN 1 .. v_n LOOP
                    IF v_floor[v_i] > 0 THEN
                        PERFORM public.post_feed_usage(
                            p_item_id          => v_line.item_id,
                            p_from_location_id => v_c.location_id,
                            p_qty_lb           => v_floor[v_i],
                            p_destination_type => 'lot',
                            p_lot_id           => v_lot_ids[v_i],
                            p_period_start     => v_period,
                            p_period_end       => v_c.count_date,
                            p_usage_date       => v_c.count_date,
                            p_source           => 'count',
                            p_reason           => 'Count ' || v_c.count_date::text
                                                  || ' - consumption allocated by head-days');
                        v_posted := v_posted + 1;
                    END IF;
                END LOOP;
                -- The line records the aggregate, not one of the splits.
                v_usage_id := NULL;
            END IF;

        ELSIF v_var < 0 THEN
            -- ---------- commodity: the residual is SHRINK ----------
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
            -- ---------- found feed, either meaning ----------
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


-- ---------------------------------------------------------------------
-- 4. void_feed_count - take a posted count back out
-- ---------------------------------------------------------------------
-- SECURITY INVOKER: the caller's own RLS applies. feed_usage and
-- feed_receipts DELETE are owner only, and under RLS a denied DELETE is a
-- silent no-op, so the role is checked up front AND the rows are proved
-- gone afterwards.
CREATE OR REPLACE FUNCTION public.void_feed_count(p_count_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    v_c           record;
    v_reason      text := NULLIF(btrim(COALESCE(p_reason, '')), '');
    v_usage_ids   uuid[];
    v_usage_lb    numeric;
    v_layered_lb  numeric;
    v_expect_lb   numeric;
    v_receipt_ids uuid[];
    v_found_lb    numeric;
    v_before      numeric;
    v_after       numeric;
    v_bad         text;
    v_id          uuid;
BEGIN
    IF public.current_user_role() IS DISTINCT FROM 'owner' THEN
        RAISE EXCEPTION 'Only the owner can remove a posted count.'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'Say why the count is being removed.';
    END IF;

    SELECT * INTO v_c FROM public.feed_counts WHERE id = p_count_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'void_feed_count: count % not found.', p_count_id;
    END IF;
    IF v_c.status = 'voided' THEN
        RAISE EXCEPTION 'That count was already removed.';
    END IF;
    IF v_c.status <> 'posted' THEN
        RAISE EXCEPTION 'That count is a draft. It posted nothing, so there is nothing to reverse.';
    END IF;

    -- A later count at the same place was measured against a book this
    -- count helped set. Take the later one out first.
    IF EXISTS (SELECT 1 FROM public.feed_counts c
                WHERE c.location_id = v_c.location_id
                  AND c.status = 'posted'
                  AND c.id <> v_c.id
                  AND c.posted_at > v_c.posted_at) THEN
        RAISE EXCEPTION 'A later count was posted at this location. Remove that one first.';
    END IF;

    -- Found layers must still be whole. Checked before anything moves.
    SELECT string_agg(i.name || ' (' || round(r.qty_lb - r.qty_lb_remaining, 2) || ' of '
                      || round(r.qty_lb, 2) || ' lb already fed)', '; ')
      INTO v_bad
      FROM public.feed_count_lines cl
      JOIN public.feed_receipts r ON r.id = cl.adjustment_receipt_id
      JOIN public.feed_items i    ON i.id = cl.item_id
     WHERE cl.count_id = p_count_id
       AND r.qty_lb_remaining <> r.qty_lb;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Feed this count found has been fed since: %. Reverse that usage first.', v_bad;
    END IF;

    SELECT array_agg(cl.adjustment_receipt_id), COALESCE(SUM(r.qty_lb), 0)
      INTO v_receipt_ids, v_found_lb
      FROM public.feed_count_lines cl
      JOIN public.feed_receipts r ON r.id = cl.adjustment_receipt_id
     WHERE cl.count_id = p_count_id;

    -- Every usage the count posted: the linked shrink rows, and the
    -- consumption rows split across lots (same transaction as the post).
    SELECT array_agg(u.id), COALESCE(SUM(u.qty_lb), 0)
      INTO v_usage_ids, v_usage_lb
      FROM public.feed_usage u
     WHERE u.source = 'count'
       AND u.from_location_id = v_c.location_id
       AND (u.id IN (SELECT cl.adjustment_usage_id FROM public.feed_count_lines cl
                      WHERE cl.count_id = p_count_id AND cl.adjustment_usage_id IS NOT NULL)
            OR (u.created_at = v_c.posted_at
                AND u.item_id IN (SELECT cl.item_id FROM public.feed_count_lines cl
                                   WHERE cl.count_id = p_count_id)));

    SELECT COALESCE(SUM(-cl.variance_lb), 0) INTO v_expect_lb
      FROM public.feed_count_lines cl
     WHERE cl.count_id = p_count_id AND cl.variance_lb < 0;

    IF abs(v_usage_lb - v_expect_lb) > 0.01 THEN
        RAISE EXCEPTION
            'Cannot prove which rows this count posted: its lines are short % lb but % lb of count usage was found. Nothing was changed.',
            round(v_expect_lb, 2), round(v_usage_lb, 2);
    END IF;

    SELECT COALESCE(SUM(c.qty_lb), 0) INTO v_layered_lb
      FROM public.feed_usage_costs c
     WHERE c.usage_id = ANY (COALESCE(v_usage_ids, ARRAY[]::uuid[]))
       AND c.receipt_id IS NOT NULL;

    SELECT COALESCE(SUM(qty_lb_remaining), 0) INTO v_before
      FROM public.feed_receipts WHERE location_id = v_c.location_id;

    -- 1. Pounds back on the layers they came off.
    FOREACH v_id IN ARRAY COALESCE(v_usage_ids, ARRAY[]::uuid[]) LOOP
        PERFORM public.delete_feed_usage(v_id);
    END LOOP;

    -- 2. Found layers off.
    FOREACH v_id IN ARRAY COALESCE(v_receipt_ids, ARRAY[]::uuid[]) LOOP
        PERFORM public.delete_feed_receipt(v_id);
    END LOOP;

    -- 3. Prove it. A denied DELETE under RLS returns no error.
    IF EXISTS (SELECT 1 FROM public.feed_usage
                WHERE id = ANY (COALESCE(v_usage_ids, ARRAY[]::uuid[])))
       OR EXISTS (SELECT 1 FROM public.feed_receipts
                   WHERE id = ANY (COALESCE(v_receipt_ids, ARRAY[]::uuid[]))) THEN
        RAISE EXCEPTION 'The count''s adjustments could not be removed. Nothing was changed.';
    END IF;

    SELECT COALESCE(SUM(qty_lb_remaining), 0) INTO v_after
      FROM public.feed_receipts WHERE location_id = v_c.location_id;
    IF abs((v_after - v_before) - (v_layered_lb - v_found_lb)) > 0.01 THEN
        RAISE EXCEPTION 'Expected on-hand to move by % lb, it moved by %. Nothing was changed.',
            round(v_layered_lb - v_found_lb, 2), round(v_after - v_before, 2);
    END IF;

    -- 4. Keep the count as the record of what happened.
    UPDATE public.feed_counts
       SET status      = 'voided',
           voided_at   = now(),
           voided_by   = auth.uid(),
           void_reason = v_reason,
           notes       = concat_ws(E'\n', NULLIF(notes, ''),
                           public.ranch_today()::text || ': count removed and its adjustments reversed ('
                           || COALESCE(array_length(v_usage_ids, 1), 0) || ' usage rows, '
                           || round(v_usage_lb, 2) || ' lb back; '
                           || COALESCE(array_length(v_receipt_ids, 1), 0) || ' found layers, '
                           || round(v_found_lb, 2) || ' lb off). Reason: ' || v_reason)
     WHERE id = p_count_id;

    RETURN jsonb_build_object(
        'usage_rows',     COALESCE(array_length(v_usage_ids, 1), 0),
        'usage_lb',       v_usage_lb,
        'found_layers',   COALESCE(array_length(v_receipt_ids, 1), 0),
        'found_lb',       v_found_lb,
        'on_hand_before', v_before,
        'on_hand_after',  v_after);
END
$fn$;

REVOKE ALL ON FUNCTION public.void_feed_count(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_feed_count(uuid, text) TO authenticated;


-- ---------------------------------------------------------------------
-- 5. Only a draft count can be deleted
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.feed_guard_count_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
BEGIN
    IF OLD.status <> 'draft' THEN
        RAISE EXCEPTION 'That count is %. Deleting it would throw away its lines and leave its adjustments with nothing pointing at them. Remove it from the Counts screen instead.', OLD.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN OLD;
END
$fn$;

DROP TRIGGER IF EXISTS feed_counts_delete_guard ON public.feed_counts;
CREATE TRIGGER feed_counts_delete_guard BEFORE DELETE ON public.feed_counts
FOR EACH ROW EXECUTE FUNCTION public.feed_guard_count_delete();

REVOKE ALL ON FUNCTION public.feed_guard_count_delete() FROM PUBLIC, anon, authenticated;


-- ---------------------------------------------------------------------
-- 6. Verify
-- ---------------------------------------------------------------------
DO $verify$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'public'
       AND p.proname IN ('post_feed_count', 'void_feed_count', 'feed_book_as_of', 'feed_guard_count_delete');
    IF n <> 4 THEN RAISE EXCEPTION 'expected 4 functions, one of each, found %', n; END IF;

    SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'public'
       AND p.proname IN ('post_feed_count', 'void_feed_count', 'feed_book_as_of', 'feed_guard_count_delete')
       AND p.prosecdef;
    IF n <> 0 THEN RAISE EXCEPTION 'a count function is SECURITY DEFINER'; END IF;

    IF has_function_privilege('anon', 'public.void_feed_count(uuid, text)', 'EXECUTE')
       OR has_function_privilege('anon', 'public.feed_book_as_of(uuid, date)', 'EXECUTE') THEN
        RAISE EXCEPTION 'anon can execute a count function';
    END IF;

    SELECT count(*) INTO n FROM pg_trigger WHERE tgname = 'feed_counts_delete_guard';
    IF n <> 1 THEN RAISE EXCEPTION 'the delete guard is missing'; END IF;

    -- With nothing dated after today, book as of tomorrow is the book now.
    SELECT count(*) INTO n
      FROM public.feed_storage_locations l
      CROSS JOIN LATERAL public.feed_book_as_of(l.id, public.ranch_today() + 1) b
     WHERE b.later_usage_lb = 0 AND b.later_receipt_lb = 0
       AND b.book_qty_lb <> b.current_qty_lb;
    IF n <> 0 THEN RAISE EXCEPTION 'feed_book_as_of disagrees with on-hand on % row(s)', n; END IF;

    RAISE NOTICE 'VERIFIED: counts can be removed by the owner, book is as of the count date, posted counts cannot be raw-deleted.';
END
$verify$;

commit;
