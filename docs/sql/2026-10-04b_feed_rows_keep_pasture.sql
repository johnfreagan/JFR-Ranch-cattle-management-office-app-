-- 2026-10-04b  Pasture head-days, build step 2: feed rows keep the pasture (D41).
--
-- Design: docs/pasture-headdays-phase-design.md, D41 and build step 2. Phase
-- feed (precon vs grower) comes from the pastures the calves stood in that day,
-- so every PB feed row posted to a lot must say WHICH pasture it was dropped
-- in. The PB report is per pen and a pen is a pasture, so no new input.
-- Go-forward only: rows already posted keep pasture_id NULL (D31). Shipping
-- this before go-live (Nov 1) is on purpose: every day before it is feed that
-- can never be split by pasture.
--
-- feed_usage.pasture_id already exists (FK to pastures, ON ... SET NULL) and
-- feed_usage_destination_shape already allows it on a 'lot' row. Until now no
-- path filled it on a lot row. Changes:
--
--   1. pb_posting_plan_by_pasture(report)  NEW. pb_posting_plan's body with a
--      pasture_id output column; lot rows are grouped per (lot, pasture), not
--      per lot. A lot standing in two pastures fed on the same load now gets
--      one row per pasture instead of one summed row. Pounds are identical:
--      the per-drop, per-lot shares are computed exactly as before
--      (lr_split by drop pounds, then by head); only the final GROUP BY adds
--      the pasture.
--   2. pb_posting_plan(report)  same signature and output, now a roll-up of (1),
--      so the planner exists once. pb_report_charges and the Feed pane read it
--      unchanged.
--   3. approve_pb_report  reads (1); a lot row passes p_pasture_id and its key
--      gains the pasture: pbmail:<date>:L<load>:<item>:<lot>:p<pasture>.
--      Unpost and pb_report_charges match 'pbmail:<date>:%', so they still
--      find every row. Cost-centre rows cannot carry a pasture (the shape
--      CHECK forbids it) and prefeed transfer rows are unchanged.
--   4. pb_charge_prefeeds  a prefeed charged to the first lot in passes the
--      hold's pasture (the feed was dropped there, the lot is standing there).
--
-- Not changed: hand-entered weekly feed (source 'manual') and count
-- adjustments carry no pasture; step 3 splits those by head share where
-- needed. pb_plan (unused since 2026-10-03) is left alone.
--
-- Live md5(prosrc) before this file, 2026-10-04:
--   pb_posting_plan    bc07d0911e2d6b1c511fdae11744dd40
--   approve_pb_report  d5230b2304343ea3770641d67b1704c7
--   pb_charge_prefeeds cd5632d3a30e9e5a79486750e28a9080
-- The guard below refuses to run if any of them changed since, so a parallel
-- edit is not silently overwritten.
--
-- No DROP or DELETE statement (connector note, docs/feed-pb-import.md
-- 2026-10-03). Idempotent: re-running replaces the
-- functions with the same bodies (the guard accepts the post-migration md5s).
-- For apply_migration or the CLI, strip the begin;/commit; lines.
-- Applied 2026-10-04 on John's approval through apply_migration (begin/commit
-- stripped), after migration 2026-10-04. Verified live: md5(prosrc) equals a
-- scratch build of this file for pb_posting_plan_by_pasture (7984896b...),
-- pb_posting_plan (a49e4c27...), approve_pb_report (c07d70a4...),
-- pb_charge_prefeeds (152ef672...). pb_posting_plan's output on the 9/28, 9/29
-- and 10/1 reports is byte-identical before and after (row count, pounds and
-- an md5 over every row). anon cannot execute the new function.
begin;

do $$
declare
    v text;
begin
    select md5(prosrc) into v from pg_proc where oid = 'public.pb_posting_plan(uuid)'::regprocedure;
    if v <> 'bc07d0911e2d6b1c511fdae11744dd40' and not exists (
         select 1 from pg_proc where proname = 'pb_posting_plan_by_pasture' and pronamespace = 'public'::regnamespace) then
        raise exception 'pb_posting_plan changed since 2026-10-04 (md5 %); re-read it before applying', v;
    end if;
    select md5(prosrc) into v from pg_proc where oid = 'public.approve_pb_report(date, text)'::regprocedure;
    if v <> 'd5230b2304343ea3770641d67b1704c7' and position('pb_posting_plan_by_pasture' in
         (select prosrc from pg_proc where oid = 'public.approve_pb_report(date, text)'::regprocedure)) = 0 then
        raise exception 'approve_pb_report changed since 2026-10-04 (md5 %); re-read it before applying', v;
    end if;
    select md5(prosrc) into v from pg_proc where oid = 'public.pb_charge_prefeeds(uuid)'::regprocedure;
    if v <> 'cd5632d3a30e9e5a79486750e28a9080' and position('p_pasture_id => h.pasture_id' in
         (select prosrc from pg_proc where oid = 'public.pb_charge_prefeeds(uuid)'::regprocedure)) = 0 then
        raise exception 'pb_charge_prefeeds changed since 2026-10-04 (md5 %); re-read it before applying', v;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. The planner, per pasture.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pb_posting_plan_by_pasture(p_report_id uuid)
 RETURNS TABLE(load_no integer, ration_name text, lot_id uuid, pasture_id uuid, prefeed_pasture_id uuid, item_id uuid, from_location_id uuid, qty_lb numeric, cost_center_id uuid)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_date   date;
  ld       record;
  ing      record;
  d_ids    uuid[];
  d_past   uuid[];
  d_pre    boolean[];
  d_cc     uuid[];
  d_lb     numeric[];
  d_parts  numeric[];
  h_lots   uuid[];
  h_heads  numeric[];
  h_parts  numeric[];
  acc      jsonb := '[]';
  i        integer;
  k        integer;
BEGIN
  SELECT report_date INTO v_date FROM pb_daily_reports WHERE id = p_report_id;
  FOR ld IN SELECT DISTINCT l.load_no, l.ration_name FROM pb_report_lines l
             WHERE l.report_id = p_report_id AND l.line_kind = 'drop' ORDER BY l.load_no LOOP
    SELECT array_agg(l.id ORDER BY l.id), array_agg(l.pasture_id ORDER BY l.id), array_agg(l.prefeed ORDER BY l.id), array_agg(l.fed_lb ORDER BY l.id),
           array_agg(l.cost_center_id ORDER BY l.id)
      INTO d_ids, d_past, d_pre, d_lb, d_cc
      FROM pb_report_lines l
     WHERE l.report_id = p_report_id AND l.line_kind = 'drop' AND l.load_no = ld.load_no
       AND l.fed_lb > 0 AND l.pasture_id IS NOT NULL;
    CONTINUE WHEN d_ids IS NULL;

    FOR ing IN SELECT l.item_id AS it, fi.default_location_id AS loc, SUM(l.fed_lb) AS lb
                 FROM pb_report_lines l JOIN feed_items fi ON fi.id = l.item_id
                WHERE l.report_id = p_report_id AND l.line_kind = 'ingredient' AND l.load_no = ld.load_no AND l.fed_lb > 0
                GROUP BY 1,2 LOOP
      d_parts := lr_split(ing.lb, d_lb, 2);           -- item pounds to each drop, by drop pounds
      FOR i IN 1..cardinality(d_ids) LOOP
        CONTINUE WHEN d_parts[i] <= 0;
        IF d_cc[i] IS NOT NULL THEN                   -- the whole drop share goes to the cost centre, no lot split
          acc := acc || jsonb_build_object('lot', NULL, 'past', NULL, 'pre', NULL, 'cc', d_cc[i], 'item', ing.it, 'loc', ing.loc, 'lb', d_parts[i]);
        ELSIF d_pre[i] THEN
          acc := acc || jsonb_build_object('lot', NULL, 'past', NULL, 'pre', d_past[i], 'item', ing.it, 'loc', ing.loc, 'lb', d_parts[i]);
        ELSE
          SELECT array_agg(s.lot_id ORDER BY s.lot_id), array_agg(s.head ORDER BY s.lot_id) INTO h_lots, h_heads
            FROM pb_lots_standing(d_past[i], v_date) s;
          CONTINUE WHEN h_lots IS NULL;                -- blocked by pb_refresh_report; nothing to plan
          h_parts := lr_split(d_parts[i], h_heads, 2); -- drop share to lots, by head
          FOR k IN 1..cardinality(h_lots) LOOP
            CONTINUE WHEN h_parts[k] <= 0;
            -- D41: the lot row keeps the pasture the drop was made in
            acc := acc || jsonb_build_object('lot', h_lots[k], 'past', d_past[i], 'pre', NULL, 'item', ing.it, 'loc', ing.loc, 'lb', h_parts[k]);
          END LOOP;
        END IF;
      END LOOP;
    END LOOP;

    RETURN QUERY
      SELECT ld.load_no, ld.ration_name, x.lot, x.past, x.pre, x.item, x.loc, SUM(x.lb), x.cc
        FROM jsonb_to_recordset(acc) AS x(lot uuid, past uuid, pre uuid, cc uuid, item uuid, loc uuid, lb numeric)
       GROUP BY x.lot, x.past, x.pre, x.cc, x.item, x.loc;
    acc := '[]';
  END LOOP;
END $function$;

-- ---------------------------------------------------------------------
-- 2. The old planner, now a roll-up of the per-pasture one. Same signature,
-- same output, same STABLE; the planner logic lives in one place.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pb_posting_plan(p_report_id uuid)
 RETURNS TABLE(load_no integer, ration_name text, lot_id uuid, prefeed_pasture_id uuid, item_id uuid, from_location_id uuid, qty_lb numeric, cost_center_id uuid)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- 2026-10-04b: a roll-up of pb_posting_plan_by_pasture over the pasture,
  -- so pb_report_charges and the Feed pane read the same pounds as before.
  RETURN QUERY
    SELECT p.load_no, p.ration_name, p.lot_id, p.prefeed_pasture_id, p.item_id, p.from_location_id, SUM(p.qty_lb), p.cost_center_id
      FROM pb_posting_plan_by_pasture(p_report_id) p
     GROUP BY p.load_no, p.ration_name, p.lot_id, p.prefeed_pasture_id, p.item_id, p.from_location_id, p.cost_center_id
     ORDER BY p.load_no;
END $function$;

-- ---------------------------------------------------------------------
-- 3. Approve: lot rows keep the pasture. Only the planner call, the lot
-- branch's p_pasture_id and its row key differ from the live body.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_pb_report(p_report_date date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_rep    pb_daily_reports%ROWTYPE;
  probs    text[];
  pl       record;
  b        record;
  v_rows   integer := 0;
  v_bunks  uuid[] := '{}';
  v_bid    uuid;
  v_score  numeric;
  v_loc    uuid;
  v_uid    uuid;
BEGIN
  SELECT * INTO v_rep FROM pb_daily_reports WHERE report_date = p_report_date FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'approve_pb_report: no PB report staged for %.', p_report_date; END IF;
  IF v_rep.status <> 'pending' THEN
    RAISE EXCEPTION 'approve_pb_report: the % report is %, only a pending report posts.', p_report_date, v_rep.status;
  END IF;
  probs := pb_refresh_report(v_rep.id);
  IF cardinality(probs) > 0 THEN
    RAISE EXCEPTION 'approve_pb_report: % problem(s) block posting: %', cardinality(probs), array_to_string(probs, ' | ');
  END IF;

  FOR pl IN SELECT * FROM pb_posting_plan_by_pasture(v_rep.id) LOOP
    IF pl.cost_center_id IS NOT NULL THEN
      PERFORM post_feed_usage(
        p_item_id => pl.item_id, p_from_location_id => pl.from_location_id, p_qty_lb => pl.qty_lb,
        p_destination_type => 'cost_center', p_cost_center_id => pl.cost_center_id,
        p_period_start => p_report_date, p_period_end => p_report_date,
        p_usage_date => p_report_date, p_source => 'pb_import',
        p_pb_row_key => format('pbmail:%s:L%s:%s:cc%s', p_report_date, pl.load_no, pl.item_id, pl.cost_center_id),
        p_notes => format('PB email %s load %s (%s) - cost centre', p_report_date, pl.load_no, pl.ration_name));
    ELSIF pl.lot_id IS NOT NULL THEN
      PERFORM post_feed_usage(
        p_item_id => pl.item_id, p_from_location_id => pl.from_location_id, p_qty_lb => pl.qty_lb,
        p_destination_type => 'lot', p_period_start => p_report_date, p_period_end => p_report_date,
        p_lot_id => pl.lot_id, p_pasture_id => pl.pasture_id, p_usage_date => p_report_date, p_source => 'pb_import',
        p_pb_row_key => format('pbmail:%s:L%s:%s:%s:p%s', p_report_date, pl.load_no, pl.item_id, pl.lot_id, pl.pasture_id),
        p_notes => format('PB email %s load %s (%s)', p_report_date, pl.load_no, pl.ration_name));
    ELSE
      v_loc := prefeed_location(pl.prefeed_pasture_id);
      v_uid := post_feed_usage(
        p_item_id => pl.item_id, p_from_location_id => pl.from_location_id, p_qty_lb => pl.qty_lb,
        p_destination_type => 'transfer', p_to_location_id => v_loc,
        p_period_start => p_report_date, p_period_end => p_report_date,
        p_usage_date => p_report_date, p_source => 'pb_import',
        p_pb_row_key => format('pbmail:%s:L%s:%s:pf%s', p_report_date, pl.load_no, pl.item_id, pl.prefeed_pasture_id),
        p_notes => format('PB email %s load %s (%s) - prefeed', p_report_date, pl.load_no, pl.ration_name));
      INSERT INTO feed_prefeed_holds (report_id, pasture_id, feed_date, load_no, item_id, location_id, qty_lb, transfer_usage_id)
      VALUES (v_rep.id, pl.prefeed_pasture_id, p_report_date, pl.load_no, pl.item_id, v_loc, pl.qty_lb, v_uid);
    END IF;
    v_rows := v_rows + 1;
  END LOOP;

  FOR b IN SELECT pasture_id, bunk_score FROM pb_report_lines
            WHERE report_id = v_rep.id AND line_kind = 'bunk' AND pasture_id IS NOT NULL AND bunk_score ~ '^\d+(\.\d+)?$' LOOP
    v_score := b.bunk_score::numeric;
    v_bid := NULL;
    INSERT INTO bunk_reads (read_date, pasture_id, bunk_score, notes)
    VALUES (p_report_date, b.pasture_id, CASE WHEN v_score IN (0, 0.5, 1, 2, 3) THEN v_score END, 'PB email score ' || b.bunk_score)
    ON CONFLICT (read_date, pasture_id) DO NOTHING
    RETURNING id INTO v_bid;
    IF v_bid IS NOT NULL THEN v_bunks := v_bunks || v_bid; END IF;
  END LOOP;

  UPDATE pb_daily_reports
     SET status = 'approved', usage_rows = v_rows, bunk_read_ids = v_bunks,
         reviewed_by = auth.uid(), reviewed_at = now(), review_notes = p_notes
   WHERE id = v_rep.id;

  PERFORM pb_charge_prefeeds();   -- cattle may already be in by the time the office approves
  RETURN pb_report_summary(p_report_date) || jsonb_build_object('charges', pb_report_charges(p_report_date));
END $function$;

-- ---------------------------------------------------------------------
-- 4. Prefeed charged to the first lot in keeps the hold's pasture. Only the
-- p_pasture_id argument differs from the live body.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pb_charge_prefeeds(p_pasture uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  h        record;
  v_day    date;
  v_lots   uuid[];
  v_heads  numeric[];
  v_parts  numeric[];
  v_list   jsonb;
  v_pname  text;
  v_dup    text;
  n        integer := 0;
  k        integer;
BEGIN
  FOR h IN SELECT * FROM feed_prefeed_holds
            WHERE status = 'held' AND (p_pasture IS NULL OR pasture_id = p_pasture)
            ORDER BY feed_date, created_at FOR UPDATE SKIP LOCKED LOOP
    BEGIN
      -- first day after the feed day, up to today, with a real lot standing
      SELECT min(d) INTO v_day FROM (
        SELECT GREATEST(a.moved_in, h.feed_date + 1) AS d
          FROM lot_pasture_assignments a JOIN lots l ON l.id = a.lot_id
         WHERE a.pasture_id = h.pasture_id AND a.head_count > 0
           AND NOT COALESCE(l.is_test, false)
           AND (a.moved_out IS NULL OR a.moved_out >= GREATEST(a.moved_in, h.feed_date + 1))) s
       WHERE d <= ranch_today();
      CONTINUE WHEN v_day IS NULL;

      SELECT array_agg(s.lot_id ORDER BY s.lot_id), array_agg(s.head ORDER BY s.lot_id) INTO v_lots, v_heads
        FROM pb_lots_standing(h.pasture_id, v_day) s;
      CONTINUE WHEN v_lots IS NULL;

      SELECT string_agg(DISTINCT lo.lot_number, ', ') INTO v_dup
        FROM feed_usage u JOIN lots lo ON lo.id = u.lot_id
       WHERE u.destination_type = 'lot' AND u.source IN ('manual','truck')
         AND v_day BETWEEN u.period_start AND u.period_end AND u.lot_id = ANY (v_lots);
      IF v_dup IS NOT NULL THEN
        UPDATE feed_prefeed_holds SET last_error = format('Lot %s already has hand-entered feed covering %s - posting would double it.', v_dup, v_day),
               updated_at = now() WHERE id = h.id;
        CONTINUE;
      END IF;

      SELECT r.name || ' ' || p.name INTO v_pname FROM pastures p JOIN ranches r ON r.id = p.ranch_id WHERE p.id = h.pasture_id;
      v_parts := lr_split(h.qty_lb, v_heads, 2);
      v_list := '[]';
      FOR k IN 1..cardinality(v_lots) LOOP
        CONTINUE WHEN v_parts[k] <= 0;
        PERFORM post_feed_usage(
          p_item_id => h.item_id, p_from_location_id => h.location_id, p_qty_lb => v_parts[k],
          p_destination_type => 'lot', p_period_start => v_day, p_period_end => v_day,
          p_lot_id => v_lots[k], p_pasture_id => h.pasture_id, p_usage_date => v_day, p_source => 'pb_import',
          p_pb_row_key => format('pbpre:%s:%s', h.id, v_lots[k]),
          p_notes => format('Prefeed %s fed %s, first lot in %s', v_pname, h.feed_date, v_day));
        v_list := v_list || jsonb_build_object('lot_id', v_lots[k], 'head', v_heads[k], 'lb', v_parts[k]);
      END LOOP;
      UPDATE feed_prefeed_holds SET status = 'charged', charged_on = v_day, charged_lots = v_list, last_error = NULL, updated_at = now()
       WHERE id = h.id;
      n := n + 1;
    EXCEPTION WHEN others THEN
      UPDATE feed_prefeed_holds SET last_error = SQLERRM, updated_at = now() WHERE id = h.id;
    END;
  END LOOP;
  RETURN n;
END $function$;

REVOKE ALL ON FUNCTION public.pb_posting_plan_by_pasture(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.pb_posting_plan_by_pasture(uuid) TO authenticated;
-- the replaced functions keep their existing grants; restated so a fresh
-- database ends the same
REVOKE ALL ON FUNCTION public.pb_posting_plan(uuid), public.approve_pb_report(date, text),
                       public.pb_charge_prefeeds(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.pb_posting_plan(uuid), public.approve_pb_report(date, text),
                          public.pb_charge_prefeeds(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- Verify: on every report on file, the roll-up equals the per-pasture plan
-- in total pounds per (load, item), and no lot row lacks a pasture.
-- ---------------------------------------------------------------------
do $$
declare
    r record; n_bad integer := 0; n_rep integer := 0;
begin
    for r in select id, report_date from pb_daily_reports loop
        n_rep := n_rep + 1;
        if exists (
            with a as (select load_no, item_id, sum(qty_lb) lb from pb_posting_plan(r.id) group by 1,2),
                 b as (select load_no, item_id, sum(qty_lb) lb from pb_posting_plan_by_pasture(r.id) group by 1,2)
            select 1 from a full join b using (load_no, item_id) where a.lb is distinct from b.lb) then
            raise warning 'report %: roll-up and per-pasture plan disagree', r.report_date;
            n_bad := n_bad + 1;
        end if;
        if exists (select 1 from pb_posting_plan_by_pasture(r.id) where lot_id is not null and pasture_id is null) then
            raise warning 'report %: a lot row has no pasture', r.report_date;
            n_bad := n_bad + 1;
        end if;
    end loop;
    if n_bad > 0 then raise exception 'feed rows keep pasture: % check(s) failed', n_bad; end if;
    raise notice 'feed rows keep pasture: % report(s) planned, roll-up ties, every lot row has a pasture', n_rep;
end $$;

commit;
