-- 2026-10-01  A pasture weighing becomes that pasture's weight, and the
--             weight goes with the cattle when they move.
--
-- John, 2026-09-29/10-01: "We will seldom weigh entire groups. For example we
-- weighed corner traps 1-3 the other day and moved. I think those weights
-- should be applied to that starting pasture and then the weight in the new
-- pasture is that weight." And on the four open calls:
--   1. A weighing counts for its pasture at 25% of the head there, for now.
--      The field app says how many that is.
--   2. Weight only. It does NOT move cost of gain, the closeout, break-even,
--      the PB feed plan or the dose suggestion - "we need to see it in action
--      for a while."
--   3. The sale-barn pay weight is the only starting weight there is, so the
--      ADG a weighing implies is measured against it, shrink and all.
--   4. The 9/29 corner-trap weighing counts: "that's the actual weight that
--      day." It already carries applies_to='pasture', so it qualifies under
--      this function as written - no data is corrected.
--
-- This is option B2 of docs/weight-estimation-design.md, which the 9/10
-- recommendation held back because "cattle move and a weight belongs to the
-- animals, not the pasture." John's answer is the resolution: the weight
-- FOLLOWS the head through lot_movements, blended by head where groups meet.
--
-- WHAT IT IS
--   lot_pasture_weight_detail(lot) - a read-only REPLAY, nothing stored.
--   Because nothing is stored, a reversed move, a corrected weighing or a
--   late approval is reflected the next time anyone looks; there is no state
--   to drift and no RPC that has to remember to maintain it.
--
--   Every head carries an OFFSET: pounds above (or below) the lot's book
--   projection, lot_projected_weight(). Unweighed head have offset 0 - they
--   ARE the book. A qualifying weighing sets its pasture's offset to
--   (booked average - book that day). A move carries the source's offset to
--   the destination and blends it there by head. The estimate on any date is
--   book + offset, so weighed cattle gain forward at the same rate the book
--   uses (phase, realized or assumed) and nothing has to walk a second ADG.
--
-- HEAD COUNTS ARE RECONSTRUCTED, AND APPROXIMATE
--   Receipts do not write lot_movements, and deaths, sales and transfers are
--   recorded against pastures only sometimes, so pasture head cannot be
--   rebuilt forward from zero. It is rebuilt BACKWARD from today's open
--   assignments through lot_movements:
--       head at start of d0 = head now - moved in since d0 + moved out since d0
--   A death or sale since the weighing is not added back, so the head used
--   for the 25% test and as blend weights can read a little low. Blending is
--   by head, so a few head either way moves an average by fractions of a
--   pound. The head on screen is always the real open-assignment head.
--
-- ORDER WITHIN A DAY
--   A whole-lot anchor first, then pasture weighings, then moves in the order
--   recorded - you weigh in the pasture, then move. If the weighed pasture
--   holds no head at that point (cattle gathered into a trap the same day and
--   weighed there), the weighing waits until that day's moves are in.
--
-- WHAT DOES NOT FEED IT
--   applies_to='lot' samples stay a note, as before. A whole-lot anchor
--   (coverage='whole_lot' AND applies_to='lot') already re-bases the book
--   itself, so on its date every offset resets to zero. Sale and individual
--   weights never count.
--
-- APPLIED 2026-10-01 via apply_migration (begin/commit stripped); the verify
-- block passed on all 12 lots. md5(prosrc) = e7a1c336de2ce06bb125ff072b66f929,
-- identical to the body below. rls_verify: PASS, 0 findings. Run as owner,
-- office, accountant and crew: all read 36-27 at 482.9 lb; crew's ADG column
-- is blank because crew cannot read invoices (the purchase weight).
-- Exercised against Test-1 inside a rolled-back block: an under-25% weighing,
-- a qualifying one, a blend through a move, a same-day gather-and-weigh, a
-- move reversal, a reweigh (ADG from the prior weighing) and a whole-lot
-- anchor reset all gave the expected numbers; nothing persisted.
--
-- Paste into the SQL editor WITHOUT the begin/commit lines.
begin;

create or replace function public.lot_pasture_weight_detail(p_lot_id uuid)
returns table (
    row_kind        text,      -- 'pasture' (one per open assignment) | 'weighing' (one per session)
    pasture_id      uuid,
    -- pasture rows
    head_now        integer,
    book_lb         numeric,   -- lot_projected_weight() today
    offset_lb       numeric,   -- estimate minus book
    est_lb          numeric,   -- book + offset
    measured_share  numeric,   -- 0..1, share of the head here whose weight came off a scale
    last_weigh_date date,      -- newest qualifying weighing behind this estimate
    -- weighing rows
    weigh_date      date,
    session_key     text,
    head_weighed    integer,
    head_there      integer,   -- reconstructed head in the pasture at the weighing
    share           numeric,
    qualifies       boolean,
    avg_gross_lb    numeric,
    avg_booked_lb   numeric,
    book_at_lb      numeric,   -- the book that day
    vs_book_lb      numeric,
    adg             numeric,
    adg_since       date,
    adg_basis       text       -- 'purchase' | 'weighing'
)
language plpgsql
stable
security invoker
set search_path to 'public'
as $function$
DECLARE
    c_min_share   CONSTANT numeric := 0.25;   -- John, 2026-10-01: "25 for now"
    v_today       date := public.ranch_today();
    v_book_today  numeric;
    v_anchor_avg  numeric;
    v_anchor_date date;
    v_d0          date;
    v_cur_date    date;
    v_book        numeric;
    v_src         text;
    v_dst         text;
    v_n           numeric;
    v_hp          numeric;
    v_hq          numeric;
    v_op          numeric;
    v_oq          numeric;
    v_mp          numeric;
    v_bwp         numeric;
    v_bdp         date;
    v_bwq         numeric;
    v_bdq         date;
    v_moved_in    date;
    v_start_w     numeric;
    v_start_d     date;
    v_basis       text;
    v_qual        boolean;
    h   jsonb := '{}';   -- head
    o   jsonb := '{}';   -- offset lb/hd vs book
    m   jsonb := '{}';   -- measured head
    bw  jsonb := '{}';   -- basis weight (lb/hd, on bd) for the ADG of the next weighing
    bd  jsonb := '{}';   -- basis date
    lw  jsonb := '{}';   -- newest qualifying weigh date behind the offset
    ev  record;
    deferred  jsonb := '[]';
    dv  jsonb;
    out_rows jsonb := '[]';
BEGIN
    v_book_today := public.lot_projected_weight(p_lot_id, v_today);

    SELECT a.anchor_avg_weight_lb, a.anchor_date
      INTO v_anchor_avg, v_anchor_date
      FROM public.lot_weight_anchor a
     WHERE a.lot_id = p_lot_id;

    -- First event that can set an offset. None: every pasture is the book.
    SELECT min(w.weigh_date) INTO v_d0
      FROM public.weights w
     WHERE w.lot_id = p_lot_id
       AND w.weigh_date <= v_today
       AND w.weight_type <> all (array['sale','individual'])
       AND ((w.applies_to = 'pasture' AND w.pasture_id IS NOT NULL)
         OR (w.coverage = 'whole_lot' AND w.applies_to = 'lot'));

    IF v_d0 IS NOT NULL AND v_book_today IS NOT NULL THEN
        -- Head per pasture at the start of v_d0, rebuilt backward.
        SELECT coalesce(jsonb_object_agg(x.pid, greatest(x.head, 0)), '{}')
          INTO h
          FROM (
            SELECT f.pid, sum(f.head) AS head FROM (
                SELECT a.pasture_id::text AS pid, a.head_count AS head
                  FROM public.lot_pasture_assignments a
                 WHERE a.lot_id = p_lot_id AND a.moved_out IS NULL
                UNION ALL
                SELECT mv.to_pasture_id::text, -mv.head_count
                  FROM public.lot_movements mv
                 WHERE mv.lot_id = p_lot_id AND mv.move_date >= v_d0
                UNION ALL
                SELECT mv.from_pasture_id::text, mv.head_count
                  FROM public.lot_movements mv
                 WHERE mv.lot_id = p_lot_id AND mv.move_date >= v_d0
                   AND mv.from_pasture_id IS NOT NULL
            ) f GROUP BY f.pid
          ) x;

        FOR ev IN
            WITH s AS (
                SELECT coalesce(w.weigh_session_id::text, 'd:' || w.weigh_date::text) AS skey,
                       w.weigh_date AS d,
                       w.pasture_id,
                       CASE WHEN w.coverage = 'whole_lot' AND w.applies_to = 'lot'
                            THEN 0 ELSE 1 END AS prio,
                       sum(w.head_weighed)   AS n,
                       sum(w.total_weight_lb) AS booked,
                       sum(w.gross_weight_lb) AS gross,
                       max(w.created_at)     AS at
                  FROM public.weights w
                 WHERE w.lot_id = p_lot_id
                   AND w.weigh_date <= v_today
                   AND w.weight_type <> all (array['sale','individual'])
                   AND ((w.applies_to = 'pasture' AND w.pasture_id IS NOT NULL)
                     OR (w.coverage = 'whole_lot' AND w.applies_to = 'lot'))
                 GROUP BY 1, 2, 3, 4
                HAVING sum(w.head_weighed) > 0 AND sum(w.total_weight_lb) > 0
            )
            SELECT 'w' AS k, s.d, s.prio, s.at, s.skey,
                   s.pasture_id::text AS src, NULL::text AS dst,
                   s.n::numeric AS n, s.booked, s.gross
              FROM s
            UNION ALL
            SELECT 'm', mv.move_date, 2, mv.created_at, mv.id::text,
                   mv.from_pasture_id::text, mv.to_pasture_id::text,
                   mv.head_count::numeric, NULL, NULL
              FROM public.lot_movements mv
             WHERE mv.lot_id = p_lot_id AND mv.move_date >= v_d0
            -- the trailing sentinel flushes the last day's deferred weighings
            UNION ALL
            SELECT 'end', v_today + 1, 9, NULL, NULL, NULL, NULL, NULL, NULL, NULL
            ORDER BY 2, 3, 4
        LOOP
            -- A new day: weighings that found their pasture empty run now,
            -- after the day's moves.
            IF v_cur_date IS NOT NULL AND ev.d <> v_cur_date AND jsonb_array_length(deferred) > 0 THEN
                FOR dv IN SELECT * FROM jsonb_array_elements(deferred) LOOP
                    v_src := dv->>'src';
                    v_hp  := coalesce((h->>v_src)::numeric, 0);
                    v_n   := (dv->>'n')::numeric;
                    v_book := public.lot_projected_weight(p_lot_id, (dv->>'d')::date);
                    v_qual := v_hp > 0 AND v_n >= c_min_share * v_hp;
                    -- ADG basis: the group's last weighing, else the purchase
                    v_bwp := (bw->>v_src)::numeric;  v_bdp := (bd->>v_src)::date;
                    IF v_bwp IS NOT NULL THEN
                        v_start_w := v_bwp; v_start_d := v_bdp; v_basis := 'weighing';
                    ELSE
                        v_start_w := v_anchor_avg; v_start_d := v_anchor_date; v_basis := 'purchase';
                    END IF;
                    out_rows := out_rows || jsonb_build_object(
                        'pasture_id', v_src, 'weigh_date', dv->>'d', 'session_key', dv->>'skey',
                        'head_weighed', v_n, 'head_there', v_hp,
                        'share', CASE WHEN v_hp > 0 THEN round(v_n / v_hp, 3) END,
                        'qualifies', v_qual,
                        'avg_gross_lb', CASE WHEN (dv->>'gross') IS NOT NULL THEN round((dv->>'gross')::numeric / v_n, 1) END,
                        'avg_booked_lb', round((dv->>'booked')::numeric / v_n, 1),
                        'book_at_lb', round(v_book, 1),
                        'vs_book_lb', round((dv->>'booked')::numeric / v_n - v_book, 1),
                        'adg', CASE WHEN v_start_w IS NOT NULL AND (dv->>'d')::date > v_start_d
                                    THEN round(((dv->>'booked')::numeric / v_n - v_start_w) / ((dv->>'d')::date - v_start_d), 2) END,
                        'adg_since', v_start_d, 'adg_basis', v_basis);
                    IF v_qual THEN
                        o  := jsonb_set(o,  array[v_src], to_jsonb((dv->>'booked')::numeric / v_n - v_book));
                        m  := jsonb_set(m,  array[v_src], to_jsonb(v_hp));
                        bw := jsonb_set(bw, array[v_src], to_jsonb((dv->>'booked')::numeric / v_n));
                        bd := jsonb_set(bd, array[v_src], to_jsonb(dv->>'d'));
                        lw := jsonb_set(lw, array[v_src], to_jsonb(dv->>'d'));
                    END IF;
                END LOOP;
                deferred := '[]';
            END IF;
            v_cur_date := ev.d;
            EXIT WHEN ev.k = 'end';

            IF ev.k = 'w' AND ev.prio = 0 THEN
                -- Whole-lot anchor: the book itself is now measured. Every
                -- offset goes to zero and every head counts as weighed.
                o := '{}';  lw := '{}';
                m := h;
                v_book := public.lot_projected_weight(p_lot_id, ev.d);
                SELECT coalesce(jsonb_object_agg(k2, to_jsonb(v_book)), '{}'),
                       coalesce(jsonb_object_agg(k2, to_jsonb(ev.d)), '{}')
                  INTO bw, bd
                  FROM jsonb_object_keys(h) k2;

            ELSIF ev.k = 'w' THEN
                v_src := ev.src;
                v_hp  := coalesce((h->>v_src)::numeric, 0);
                IF v_hp <= 0 THEN
                    deferred := deferred || jsonb_build_object(
                        'src', v_src, 'n', ev.n, 'booked', ev.booked, 'gross', ev.gross,
                        'd', ev.d, 'skey', ev.skey);
                ELSE
                    v_book := public.lot_projected_weight(p_lot_id, ev.d);
                    v_qual := ev.n >= c_min_share * v_hp;
                    v_bwp := (bw->>v_src)::numeric;  v_bdp := (bd->>v_src)::date;
                    IF v_bwp IS NOT NULL THEN
                        v_start_w := v_bwp; v_start_d := v_bdp; v_basis := 'weighing';
                    ELSE
                        -- Never weighed: the purchase, dated from the
                        -- earlier of the lot's weighted arrival and the day
                        -- these cattle went into this pasture. Drafts that
                        -- landed before the weighted arrival (36-27's corner
                        -- traps, 8/12-8/16 against 8/27) have been gaining
                        -- since they got off the truck; a pasture filled by a
                        -- later move dates from the lot's arrival.
                        v_start_w := v_anchor_avg;
                        v_basis   := 'purchase';
                        SELECT min(a.moved_in) INTO v_moved_in
                          FROM public.lot_pasture_assignments a
                         WHERE a.lot_id = p_lot_id
                           AND a.pasture_id::text = v_src
                           AND a.moved_in <= ev.d
                           AND (a.moved_out IS NULL OR a.moved_out >= ev.d);
                        v_start_d := least(v_anchor_date, coalesce(v_moved_in, v_anchor_date));
                    END IF;
                    out_rows := out_rows || jsonb_build_object(
                        'pasture_id', v_src, 'weigh_date', ev.d, 'session_key', ev.skey,
                        'head_weighed', ev.n, 'head_there', v_hp,
                        'share', round(ev.n / v_hp, 3),
                        'qualifies', v_qual,
                        'avg_gross_lb', CASE WHEN ev.gross IS NOT NULL THEN round(ev.gross / ev.n, 1) END,
                        'avg_booked_lb', round(ev.booked / ev.n, 1),
                        'book_at_lb', round(v_book, 1),
                        'vs_book_lb', round(ev.booked / ev.n - v_book, 1),
                        'adg', CASE WHEN v_start_w IS NOT NULL AND ev.d > v_start_d
                                    THEN round((ev.booked / ev.n - v_start_w) / (ev.d - v_start_d), 2) END,
                        'adg_since', v_start_d, 'adg_basis', v_basis);
                    IF v_qual THEN
                        o  := jsonb_set(o,  array[v_src], to_jsonb(ev.booked / ev.n - v_book));
                        m  := jsonb_set(m,  array[v_src], to_jsonb(v_hp));
                        bw := jsonb_set(bw, array[v_src], to_jsonb(ev.booked / ev.n));
                        bd := jsonb_set(bd, array[v_src], to_jsonb(ev.d));
                        lw := jsonb_set(lw, array[v_src], to_jsonb(ev.d));
                    END IF;
                END IF;

            ELSE
                -- A move. The source's average is unchanged by head leaving;
                -- the destination blends by head.
                v_src := ev.src;  v_dst := ev.dst;  v_n := ev.n;
                IF v_src IS NULL THEN
                    v_hp := 0; v_op := 0; v_mp := 0; v_bwp := NULL; v_bdp := NULL;
                ELSE
                    v_hp  := coalesce((h->>v_src)::numeric, 0);
                    v_op  := coalesce((o->>v_src)::numeric, 0);
                    v_mp  := CASE WHEN v_hp > 0 THEN least(coalesce((m->>v_src)::numeric, 0) / v_hp, 1) ELSE 0 END;
                    v_bwp := (bw->>v_src)::numeric;  v_bdp := (bd->>v_src)::date;
                END IF;
                v_hq  := coalesce((h->>v_dst)::numeric, 0);
                v_oq  := coalesce((o->>v_dst)::numeric, 0);
                v_bwq := (bw->>v_dst)::numeric;  v_bdq := (bd->>v_dst)::date;

                o := jsonb_set(o, array[v_dst], to_jsonb((v_hq * v_oq + v_n * v_op) / (v_hq + v_n)));
                m := jsonb_set(m, array[v_dst], to_jsonb(coalesce((m->>v_dst)::numeric, 0) + v_n * v_mp));
                -- A basis survives only where every head here shares a
                -- weigh date; mixed bases fall back to the purchase.
                IF v_hq <= 0 THEN
                    bw := CASE WHEN v_bwp IS NULL THEN bw - v_dst ELSE jsonb_set(bw, array[v_dst], to_jsonb(v_bwp)) END;
                    bd := CASE WHEN v_bdp IS NULL THEN bd - v_dst ELSE jsonb_set(bd, array[v_dst], to_jsonb(v_bdp)) END;
                ELSIF v_bdp IS NOT NULL AND v_bdq IS NOT NULL AND v_bdp = v_bdq THEN
                    bw := jsonb_set(bw, array[v_dst], to_jsonb((v_hq * v_bwq + v_n * v_bwp) / (v_hq + v_n)));
                ELSE
                    bw := bw - v_dst;  bd := bd - v_dst;
                END IF;
                IF (lw->>v_src) IS NOT NULL
                   AND ((lw->>v_dst) IS NULL OR (lw->>v_src)::date > (lw->>v_dst)::date) THEN
                    lw := jsonb_set(lw, array[v_dst], lw->v_src);
                END IF;

                h := jsonb_set(h, array[v_dst], to_jsonb(v_hq + v_n));
                IF v_src IS NOT NULL THEN
                    h := jsonb_set(h, array[v_src], to_jsonb(greatest(v_hp - v_n, 0)));
                    m := jsonb_set(m, array[v_src], to_jsonb(greatest(v_hp - v_n, 0) * v_mp));
                    IF v_hp - v_n <= 0 THEN
                        -- Emptied: what comes in later starts from the book.
                        o := o - v_src;  m := m - v_src;  bw := bw - v_src;  bd := bd - v_src;  lw := lw - v_src;
                    END IF;
                END IF;
            END IF;
        END LOOP;
    END IF;

    RETURN QUERY
    SELECT 'pasture'::text, a.pasture_id,
           a.head_count,
           round(v_book_today, 1),
           round(coalesce((o->>a.pasture_id::text)::numeric, 0), 1),
           round(v_book_today + coalesce((o->>a.pasture_id::text)::numeric, 0), 1),
           CASE WHEN coalesce((h->>a.pasture_id::text)::numeric, 0) > 0
                THEN round(least(coalesce((m->>a.pasture_id::text)::numeric, 0)
                                 / (h->>a.pasture_id::text)::numeric, 1), 3)
                ELSE 0 END,
           (lw->>a.pasture_id::text)::date,
           NULL::date, NULL::text, NULL::integer, NULL::integer, NULL::numeric, NULL::boolean,
           NULL::numeric, NULL::numeric, NULL::numeric, NULL::numeric, NULL::numeric, NULL::date, NULL::text
      FROM public.lot_pasture_assignments a
     WHERE a.lot_id = p_lot_id AND a.moved_out IS NULL
    UNION ALL
    SELECT 'weighing'::text, (r->>'pasture_id')::uuid,
           NULL::integer, NULL::numeric, NULL::numeric, NULL::numeric, NULL::numeric, NULL::date,
           (r->>'weigh_date')::date, r->>'session_key',
           (r->>'head_weighed')::numeric::integer, round((r->>'head_there')::numeric)::integer,
           (r->>'share')::numeric, (r->>'qualifies')::boolean,
           (r->>'avg_gross_lb')::numeric, (r->>'avg_booked_lb')::numeric,
           (r->>'book_at_lb')::numeric, (r->>'vs_book_lb')::numeric,
           (r->>'adg')::numeric, (r->>'adg_since')::date, r->>'adg_basis'
      FROM jsonb_array_elements(out_rows) r;
END;
$function$;

comment on function public.lot_pasture_weight_detail(uuid) is
    'Estimated weight per pasture a lot stands in, and every pasture weighing behind it. A weighing of at least 25% of the head in a pasture sets that pasture''s offset from the book; the offset follows the head through lot_movements and blends by head. Display only - lot_projected_weight(), cost of gain, the closeout, the PB feed plan and the dose suggestion do not read it (John, 2026-10-01: "only weight for now").';

revoke all on function public.lot_pasture_weight_detail(uuid) from public;
revoke all on function public.lot_pasture_weight_detail(uuid) from anon;
grant execute on function public.lot_pasture_weight_detail(uuid) to authenticated;
grant execute on function public.lot_pasture_weight_detail(uuid) to service_role;

do $verify$
DECLARE
    v_lot   uuid;
    v_open  integer;
    v_rows  integer;
    v_bad   integer;
BEGIN
    IF has_function_privilege('anon', 'public.lot_pasture_weight_detail(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'anon can execute lot_pasture_weight_detail.';
    END IF;

    FOR v_lot IN SELECT l.id FROM public.lots l LOOP
        -- One pasture row per OPEN assignment, no more, no fewer.
        SELECT count(*) INTO v_open FROM public.lot_pasture_assignments
         WHERE lot_id = v_lot AND moved_out IS NULL;
        SELECT count(*) INTO v_rows FROM public.lot_pasture_weight_detail(v_lot)
         WHERE row_kind = 'pasture';
        IF v_rows <> v_open THEN
            RAISE EXCEPTION 'lot %: % pasture rows against % open assignments.', v_lot, v_rows, v_open;
        END IF;
        -- est = book + offset, and a share is a share.
        SELECT count(*) INTO v_bad FROM public.lot_pasture_weight_detail(v_lot)
         WHERE row_kind = 'pasture'
           AND (abs(coalesce(est_lb, 0) - coalesce(book_lb, 0) - coalesce(offset_lb, 0)) > 0.11
             OR measured_share < 0 OR measured_share > 1);
        IF v_bad > 0 THEN
            RAISE EXCEPTION 'lot %: % pasture rows fail est = book + offset or 0 <= share <= 1.', v_lot, v_bad;
        END IF;
    END LOOP;

    RAISE NOTICE 'lot_pasture_weight_detail: % lots checked.', (SELECT count(*) FROM public.lots);
END
$verify$;

commit;
