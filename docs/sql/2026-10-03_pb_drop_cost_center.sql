-- Approvals > Feed: send a pen's PB drop to a cost centre (Cow/Calf Wip) instead of to lots.
--
-- Approved by John 2026-10-03 ("build the button"). Nichols Front Trap holds the cow herd, not
-- stocker lots; its PB feed belongs on the Cow/Calf Wip cost centre, the same destination hand-entered
-- cow feed already uses (feed_usage.destination_type = 'cost_center'). It never touches a lot's cost
-- of gain and shows in the Redwing export's cost-centre section.
--
-- 1. pb_report_lines.cost_center_id (nullable, FK cost_centers). Per pen, per pending day, like Move
--    and Prefeed; re-staging a different email for the day rebuilds the lines and drops it, as it
--    does moves.
-- 2. pb_set_cost_center(date, pen, cost centre name | NULL) sets or clears it. Setting it clears
--    Prefeed; pb_mark_prefeed(on) clears it - a drop is a lot charge, a prefeed hold or a cost
--    centre charge, never two.
-- 3. pb_posting_plan(report) is pb_plan plus an output column cost_center_id; a cost-centre drop
--    takes its whole share of each ingredient, with no head split. approve_pb_report and
--    pb_report_charges (pb_plan's only callers) now read pb_posting_plan. pb_plan itself is left in
--    place, unchanged and unused: changing its result columns needs DROP FUNCTION, and the Supabase
--    connector stalls on DROP statements (2026-10-03: even a rolled-back DROP with lock_timeout 5s
--    timed out at 60s), so the new name avoids a destructive statement. Drop pb_plan by hand later
--    if wanted; nothing calls it.
-- 4. pb_refresh_report: a cost-centre drop needs no lot standing and is left out of the
--    hand-entered-double check; an inactive cost centre is a problem.
-- 5. approve_pb_report posts cost-centre rows as destination 'cost_center', source 'pb_import',
--    pb_row_key 'pbmail:<date>:L<load>:<item>:cc<id>' - so unpost_pb_report (which removes every
--    pbmail: row for the day) backs them out unchanged.
-- 6. pb_report_charges adds 'cost_centers' [{cost_center, lb, items}] and counts it in total_lb;
--    pb_report_summary.by_pen adds 'cost_center' (name). Keeping the cost centre through a Split is in
--    2026-10-03b (not applied yet - see that file); until then a split clears it, the "no lot standing"
--    problem returns and blocks Approve, and the office taps Cost centre again. Nothing mis-posts.
--
-- No data changes. Verify block at the end raises if any part is missing or anon can execute.
--
-- APPLIED live 2026-10-03 through the Supabase connector in pieces, because the connector stalls
-- (60 s timeout, nothing applied) on any request containing DROP or DELETE:
--   pb_drop_cost_center_1_column, _2_posting_plan, _3_prefeed_refresh, _4_approve,
--   _5_charges_summary, _6_set_cost_center (grants included).
-- md5(prosrc) live = this file applied locally:
--   pb_posting_plan bc07d0911e2d6b1c511fdae11744dd40   pb_refresh_report 78bd59a1f18aea27b1b3b773c8f676b8
--   approve_pb_report d5230b2304343ea3770641d67b1704c7 pb_report_charges 8adb3b3e66cdf961a274f9229e37f266
--   pb_report_summary 2e08ea6f05667f29f4c509b64f2b87eb pb_mark_prefeed 6cc00ad63f398a4510d9daa56ac0ae24
--   pb_set_cost_center d2b5470878145fd84e9640432324b977 pb_plan unchanged 80fdca273223fe4f7041edf2991130b7
-- anon executes no PB function; rls_verify's assertions all hold (run as separate selects - the
-- script's text contains DELETE, which the connector stalls on).

begin;

ALTER TABLE public.pb_report_lines ADD COLUMN IF NOT EXISTS cost_center_id uuid REFERENCES public.cost_centers(id);

CREATE OR REPLACE FUNCTION public.pb_posting_plan(p_report_id uuid)
RETURNS TABLE (load_no integer, ration_name text, lot_id uuid, prefeed_pasture_id uuid, item_id uuid, from_location_id uuid, qty_lb numeric,
               cost_center_id uuid)
LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp' AS $$
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
          acc := acc || jsonb_build_object('lot', NULL, 'pre', NULL, 'cc', d_cc[i], 'item', ing.it, 'loc', ing.loc, 'lb', d_parts[i]);
        ELSIF d_pre[i] THEN
          acc := acc || jsonb_build_object('lot', NULL, 'pre', d_past[i], 'item', ing.it, 'loc', ing.loc, 'lb', d_parts[i]);
        ELSE
          SELECT array_agg(s.lot_id ORDER BY s.lot_id), array_agg(s.head ORDER BY s.lot_id) INTO h_lots, h_heads
            FROM pb_lots_standing(d_past[i], v_date) s;
          CONTINUE WHEN h_lots IS NULL;                -- blocked by pb_refresh_report; nothing to plan
          h_parts := lr_split(d_parts[i], h_heads, 2); -- drop share to lots, by head
          FOR k IN 1..cardinality(h_lots) LOOP
            CONTINUE WHEN h_parts[k] <= 0;
            acc := acc || jsonb_build_object('lot', h_lots[k], 'pre', NULL, 'item', ing.it, 'loc', ing.loc, 'lb', h_parts[k]);
          END LOOP;
        END IF;
      END LOOP;
    END LOOP;

    RETURN QUERY
      SELECT ld.load_no, ld.ration_name, x.lot, x.pre, x.item, x.loc, SUM(x.lb), x.cc
        FROM jsonb_to_recordset(acc) AS x(lot uuid, pre uuid, cc uuid, item uuid, loc uuid, lb numeric)
       GROUP BY x.lot, x.pre, x.cc, x.item, x.loc;
    acc := '[]';
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.pb_mark_prefeed(p_report_date date, p_pb_pen text, p_on boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
DECLARE v_rep pb_daily_reports%ROWTYPE; n integer;
BEGIN
  SELECT * INTO v_rep FROM pb_daily_reports WHERE report_date = p_report_date FOR UPDATE;
  IF NOT FOUND OR v_rep.status <> 'pending' THEN
    RAISE EXCEPTION 'pb_mark_prefeed: no pending PB report for %.', p_report_date;
  END IF;
  UPDATE pb_report_lines SET prefeed = p_on,
         cost_center_id = CASE WHEN p_on THEN NULL ELSE cost_center_id END
   WHERE report_id = v_rep.id AND line_kind = 'drop' AND pb_norm(pb_name) = pb_norm(p_pb_pen);
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'pb_mark_prefeed: no drop to "%" on %.', p_pb_pen, p_report_date; END IF;
  PERFORM pb_refresh_report(v_rep.id);
  RETURN pb_report_summary(p_report_date) || jsonb_build_object('charges', pb_report_charges(p_report_date));
END $$;

CREATE OR REPLACE FUNCTION public.pb_refresh_report(p_report_id uuid) RETURNS text[]
LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
DECLARE
  v_rep  pb_daily_reports%ROWTYPE;
  probs  text[];
  rec    record;
  v_from date;
  v_truck date;
BEGIN
  SELECT * INTO v_rep FROM pb_daily_reports WHERE id = p_report_id;
  probs := ARRAY(SELECT jsonb_array_elements_text(v_rep.parsed->'problems'));

  UPDATE pb_report_lines SET pasture_id = COALESCE(pasture_override, pb_resolve_pen(pb_name))
   WHERE report_id = p_report_id AND line_kind IN ('drop','bunk');
  UPDATE pb_report_lines SET item_id = pb_resolve_item(pb_name)
   WHERE report_id = p_report_id AND line_kind = 'ingredient';

  FOR rec IN SELECT DISTINCT pb_name FROM pb_report_lines
              WHERE report_id = p_report_id AND line_kind = 'drop' AND pasture_id IS NULL ORDER BY 1 LOOP
    probs := probs || format('Pen "%s" does not match a pasture - tell Claude which pasture it is.', rec.pb_name);
  END LOOP;
  FOR rec IN SELECT DISTINCT pb_name FROM pb_report_lines
              WHERE report_id = p_report_id AND line_kind = 'ingredient' AND item_id IS NULL ORDER BY 1 LOOP
    probs := probs || format('Ingredient "%s" does not match a feed item - tell Claude which item it is.', rec.pb_name);
  END LOOP;
  FOR rec IN SELECT DISTINCT i.name FROM pb_report_lines l JOIN feed_items i ON i.id = l.item_id
              WHERE l.report_id = p_report_id AND l.fed_lb > 0 AND i.default_location_id IS NULL LOOP
    probs := probs || format('Feed item "%s" has no default storage location to draw from.', rec.name);
  END LOOP;
  FOR rec IN SELECT DISTINCT l.pb_name, r.name || ' ' || p.name AS pname,
                    (SELECT string_agg(lo.lot_number, ', ') FROM lot_pasture_assignments a JOIN lots lo ON lo.id = a.lot_id
                      WHERE a.pasture_id = l.pasture_id AND a.head_count > 0 AND a.moved_in <= v_rep.report_date
                        AND (a.moved_out IS NULL OR a.moved_out >= v_rep.report_date)
                        AND (lo.is_test OR (lo.closed_at IS NOT NULL AND lo.closed_at::date < v_rep.report_date))) AS skipped
               FROM pb_report_lines l JOIN pastures p ON p.id = l.pasture_id JOIN ranches r ON r.id = p.ranch_id
              WHERE l.report_id = p_report_id AND l.line_kind = 'drop' AND l.fed_lb > 0 AND NOT l.prefeed AND l.cost_center_id IS NULL
                AND NOT EXISTS (SELECT 1 FROM pb_lots_standing(l.pasture_id, v_rep.report_date)) LOOP
    probs := probs || format('No real lot is standing in %s on %s in the app%s - enter the pasture moves, mark it Prefeed if cattle are coming, or Move/Split this drop.',
                             rec.pname, v_rep.report_date,
                             CASE WHEN rec.skipped IS NOT NULL THEN ' (only test/closed lot ' || rec.skipped || ')' ELSE '' END);
  END LOOP;
  FOR rec IN SELECT DISTINCT r.name || ' ' || p.name AS pname,
                    (SELECT string_agg(lo.lot_number, ', ') FROM pb_lots_standing(l.pasture_id, v_rep.report_date) s JOIN lots lo ON lo.id = s.lot_id) AS lots
               FROM pb_report_lines l JOIN pastures p ON p.id = l.pasture_id JOIN ranches r ON r.id = p.ranch_id
              WHERE l.report_id = p_report_id AND l.line_kind = 'drop' AND l.prefeed
                AND EXISTS (SELECT 1 FROM pb_lots_standing(l.pasture_id, v_rep.report_date)) LOOP
    probs := probs || format('%s is marked Prefeed but %s is already standing there on %s - unmark Prefeed; it posts to them normally.',
                             rec.pname, rec.lots, v_rep.report_date);
  END LOOP;
  FOR rec IN SELECT DISTINCT l.pb_name, cc.name FROM pb_report_lines l JOIN cost_centers cc ON cc.id = l.cost_center_id
              WHERE l.report_id = p_report_id AND l.line_kind = 'drop' AND NOT cc.is_active LOOP
    probs := probs || format('Pen "%s" is sent to cost centre %s, which is inactive - pick another or undo it.', rec.pb_name, rec.name);
  END LOOP;
  FOR rec IN SELECT l.load_no,
                    SUM(l.fed_lb) FILTER (WHERE l.line_kind='drop') d,
                    SUM(l.fed_lb) FILTER (WHERE l.line_kind='ingredient') i
               FROM pb_report_lines l WHERE l.report_id = p_report_id AND l.line_kind <> 'bunk'
              GROUP BY l.load_no LOOP
    IF COALESCE(rec.d,0) > 0 AND COALESCE(rec.i,0) = 0 THEN
      probs := probs || format('Load %s: drops show %s lb fed but no ingredient pounds.', rec.load_no, rec.d);
    ELSIF COALESCE(rec.d,0) = 0 AND COALESCE(rec.i,0) > 0 THEN
      probs := probs || format('Load %s: ingredients show %s lb fed but no drop pounds - nowhere to charge it.', rec.load_no, rec.i);
    END IF;
  END LOOP;

  SELECT pb_email_post_from, feed_truck_post_from INTO v_from, v_truck FROM ranch_settings LIMIT 1;
  IF v_from IS NULL THEN
    probs := probs || 'No PB cut-over date is set (ranch_settings.pb_email_post_from) - nothing can post yet.'::text;
  ELSIF v_rep.report_date < v_from THEN
    probs := probs || format('Report date %s is before the PB cut-over %s - that period is entered by hand.', v_rep.report_date, v_from);
  END IF;
  IF v_truck IS NOT NULL AND v_rep.report_date >= v_truck THEN
    probs := probs || format('Report date %s is on/after the feed truck cut-over %s - the truck posts this day, not PB.', v_rep.report_date, v_truck);
  END IF;
  FOR rec IN SELECT DISTINCT lo.lot_number FROM feed_usage u JOIN lots lo ON lo.id = u.lot_id
              WHERE u.destination_type = 'lot' AND u.source IN ('manual','truck')
                AND v_rep.report_date BETWEEN u.period_start AND u.period_end
                AND u.lot_id IN (SELECT s.lot_id FROM pb_report_lines l, LATERAL pb_lots_standing(l.pasture_id, v_rep.report_date) s
                                  WHERE l.report_id = p_report_id AND l.line_kind='drop' AND l.fed_lb > 0 AND l.pasture_id IS NOT NULL
                                    AND l.cost_center_id IS NULL) LOOP
    probs := probs || format('Lot %s already has feed entered by hand covering %s - posting would double it.', rec.lot_number, v_rep.report_date);
  END LOOP;

  UPDATE pb_daily_reports SET problems = probs WHERE id = p_report_id;
  RETURN probs;
END $$;

CREATE OR REPLACE FUNCTION public.approve_pb_report(p_report_date date, p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
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

  FOR pl IN SELECT * FROM pb_posting_plan(v_rep.id) LOOP
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
        p_lot_id => pl.lot_id, p_usage_date => p_report_date, p_source => 'pb_import',
        p_pb_row_key => format('pbmail:%s:L%s:%s:%s', p_report_date, pl.load_no, pl.item_id, pl.lot_id),
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
END $$;

CREATE OR REPLACE FUNCTION public.pb_report_charges(p_date date) RETURNS jsonb
LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $$
  WITH r AS (SELECT * FROM pb_daily_reports WHERE report_date = p_date),
  rows AS (
    SELECT p.lot_id, p.item_id, p.qty_lb FROM r, LATERAL pb_posting_plan(r.id) p WHERE r.status = 'pending' AND p.lot_id IS NOT NULL
    UNION ALL
    SELECT u.lot_id, u.item_id, u.qty_lb FROM r JOIN feed_usage u ON u.pb_row_key LIKE format('pbmail:%s:%%', r.report_date)
     WHERE r.status = 'approved' AND u.destination_type = 'lot'),
  per_lot AS (
    SELECT lo.lot_number, SUM(x.qty_lb) lb,
           jsonb_agg(jsonb_build_object('item', i.name, 'lb', x.qty_lb) ORDER BY i.name) items
      FROM (SELECT lot_id, item_id, SUM(qty_lb) qty_lb FROM rows GROUP BY 1,2) x
      JOIN lots lo ON lo.id = x.lot_id JOIN feed_items i ON i.id = x.item_id
     GROUP BY lo.lot_number),
  pre AS (
    SELECT p.prefeed_pasture_id AS pasture_id, p.item_id, p.qty_lb, 'will hold'::text AS state, NULL::date AS charged_on, NULL::text AS err
      FROM r, LATERAL pb_posting_plan(r.id) p WHERE r.status = 'pending' AND p.prefeed_pasture_id IS NOT NULL
    UNION ALL
    SELECT h.pasture_id, h.item_id, h.qty_lb, h.status, h.charged_on, h.last_error
      FROM r JOIN feed_prefeed_holds h ON h.report_id = r.id),
  pre_items AS (
    SELECT pasture_id, state, charged_on, item_id, SUM(qty_lb) qty_lb, max(err) err FROM pre GROUP BY 1,2,3,4),
  ccs AS (
    SELECT p.cost_center_id, p.item_id, p.qty_lb FROM r, LATERAL pb_posting_plan(r.id) p WHERE r.status = 'pending' AND p.cost_center_id IS NOT NULL
    UNION ALL
    SELECT u.cost_center_id, u.item_id, u.qty_lb FROM r JOIN feed_usage u ON u.pb_row_key LIKE format('pbmail:%s:%%', r.report_date)
     WHERE r.status = 'approved' AND u.destination_type = 'cost_center'),
  per_cc AS (
    SELECT cc.name, SUM(x.qty_lb) lb,
           jsonb_agg(jsonb_build_object('item', i.name, 'lb', x.qty_lb) ORDER BY i.name) items
      FROM (SELECT cost_center_id, item_id, SUM(qty_lb) qty_lb FROM ccs GROUP BY 1,2) x
      JOIN cost_centers cc ON cc.id = x.cost_center_id JOIN feed_items i ON i.id = x.item_id
     GROUP BY cc.name),
  per_pre AS (
    SELECT rn.name || ' ' || pa.name AS pasture, x.state, x.charged_on, SUM(x.qty_lb) lb,
           jsonb_agg(jsonb_build_object('item', i.name, 'lb', x.qty_lb) ORDER BY i.name) items,
           max(x.err) AS error
      FROM pre_items x JOIN pastures pa ON pa.id = x.pasture_id JOIN ranches rn ON rn.id = pa.ranch_id JOIN feed_items i ON i.id = x.item_id
     GROUP BY 1,2,3)
  SELECT jsonb_build_object(
    'basis', (SELECT CASE WHEN status = 'approved' THEN 'posted' ELSE 'plan' END FROM r),
    'total_lb', COALESCE((SELECT SUM(lb) FROM per_lot), 0) + COALESCE((SELECT SUM(lb) FROM per_pre), 0)
              + COALESCE((SELECT SUM(lb) FROM per_cc), 0),
    'cost_centers', COALESCE((SELECT jsonb_agg(jsonb_build_object('cost_center', name, 'lb', lb, 'items', items) ORDER BY name) FROM per_cc), '[]'),
    'lots', COALESCE((SELECT jsonb_agg(jsonb_build_object('lot', lot_number, 'lb', lb, 'items', items) ORDER BY lb DESC) FROM per_lot), '[]'),
    'prefeed', COALESCE((SELECT jsonb_agg(jsonb_build_object('pasture', pasture, 'state', state, 'charged_on', charged_on, 'lb', lb, 'items', items, 'error', error)) FROM per_pre), '[]'))
$$;

CREATE OR REPLACE FUNCTION public.pb_report_summary(p_date date) RETURNS jsonb
LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $$
  SELECT jsonb_build_object(
    'report_date', r.report_date,
    'status', r.status,
    'loads', (SELECT count(DISTINCT load_no) FROM pb_report_lines WHERE report_id = r.id AND line_kind='drop'),
    'drop_target_lb', (SELECT COALESCE(SUM(target_lb),0) FROM pb_report_lines WHERE report_id = r.id AND line_kind='drop'),
    'drop_fed_lb',    (SELECT COALESCE(SUM(fed_lb),0)    FROM pb_report_lines WHERE report_id = r.id AND line_kind='drop'),
    'ingredient_fed_lb', (SELECT COALESCE(SUM(fed_lb),0) FROM pb_report_lines WHERE report_id = r.id AND line_kind='ingredient'),
    'by_pen', (SELECT COALESCE(jsonb_agg(jsonb_build_object('pen', pb_name, 'pasture', pname,
                                                             'ranch', rname, 'pasture_name', paname,
                                                             'target_lb', t, 'fed_lb', f,
                                                             'moved', moved, 'split', split, 'prefeed', prefeed,
                                                             'cost_center', cost_center) ORDER BY pb_name, pname), '[]')
                 FROM (SELECT l.pb_name, rn.name || ' ' || p.name pname, rn.name rname, p.name paname,
                              SUM(l.target_lb) t, SUM(l.fed_lb) f,
                              bool_or(l.pasture_override IS NOT NULL) moved, bool_or(l.split_at IS NOT NULL) split,
                              bool_or(l.prefeed) prefeed, max(cc.name) cost_center
                         FROM pb_report_lines l LEFT JOIN pastures p ON p.id = l.pasture_id LEFT JOIN ranches rn ON rn.id = p.ranch_id
                              LEFT JOIN cost_centers cc ON cc.id = l.cost_center_id
                        WHERE l.report_id = r.id AND l.line_kind='drop' GROUP BY 1,2,3,4) s),
    'by_ingredient', (SELECT COALESCE(jsonb_agg(jsonb_build_object('pb_name', pb_name, 'item', item, 'target_lb', t, 'fed_lb', f) ORDER BY pb_name), '[]')
                 FROM (SELECT l.pb_name, i.name item, SUM(l.target_lb) t, SUM(l.fed_lb) f FROM pb_report_lines l
                        LEFT JOIN feed_items i ON i.id = l.item_id
                        WHERE l.report_id = r.id AND l.line_kind='ingredient' GROUP BY 1,2) s),
    'bunk_scores', (SELECT COALESCE(jsonb_agg(jsonb_build_object('pen', pb_name, 'score', bunk_score)), '[]')
                      FROM pb_report_lines WHERE report_id = r.id AND line_kind='bunk'),
    'problems', to_jsonb(r.problems),
    'notes', to_jsonb(r.notes),
    'usage_rows', r.usage_rows)
  FROM pb_daily_reports r WHERE r.report_date = p_date
$$;

-- Send a pen's drop for one pending day to a cost centre (e.g. Cow/Calf Wip) instead of the lots
-- standing in its pasture. NULL or '' takes it back off. Turning it on clears Prefeed for that pen.
CREATE OR REPLACE FUNCTION public.pb_set_cost_center(p_report_date date, p_pb_pen text, p_cost_center text)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
DECLARE v_rep pb_daily_reports%ROWTYPE; v_cc uuid; n integer;
BEGIN
  SELECT * INTO v_rep FROM pb_daily_reports WHERE report_date = p_report_date FOR UPDATE;
  IF NOT FOUND OR v_rep.status <> 'pending' THEN
    RAISE EXCEPTION 'pb_set_cost_center: no pending PB report for %.', p_report_date;
  END IF;
  IF COALESCE(btrim(p_cost_center), '') <> '' THEN
    SELECT id INTO v_cc FROM cost_centers WHERE lower(name) = lower(btrim(p_cost_center)) AND is_active;
    IF v_cc IS NULL THEN RAISE EXCEPTION 'pb_set_cost_center: no active cost centre "%".', p_cost_center; END IF;
  END IF;
  UPDATE pb_report_lines
     SET cost_center_id = v_cc,
         prefeed = CASE WHEN v_cc IS NOT NULL THEN false ELSE prefeed END
   WHERE report_id = v_rep.id AND line_kind = 'drop' AND pb_norm(pb_name) = pb_norm(p_pb_pen);
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'pb_set_cost_center: no drop to "%" on %.', p_pb_pen, p_report_date; END IF;
  PERFORM pb_refresh_report(v_rep.id);
  RETURN pb_report_summary(p_report_date) || jsonb_build_object('charges', pb_report_charges(p_report_date));
END $$;

REVOKE EXECUTE ON FUNCTION public.pb_set_cost_center(date, text, text) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.pb_posting_plan(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.pb_set_cost_center(date, text, text), public.pb_posting_plan(uuid) TO authenticated;

-- Verify
DO $$
DECLARE f text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                  AND table_name = 'pb_report_lines' AND column_name = 'cost_center_id') THEN
    RAISE EXCEPTION 'verify: pb_report_lines.cost_center_id missing';
  END IF;
  FOREACH f IN ARRAY ARRAY['pb_posting_plan','pb_refresh_report','approve_pb_report','pb_report_charges',
                           'pb_report_summary','pb_mark_prefeed','pb_set_cost_center'] LOOP
    IF position('cost_center' IN (SELECT prosrc FROM pg_proc WHERE proname = f AND pronamespace = 'public'::regnamespace)) = 0 THEN
      RAISE EXCEPTION 'verify: % does not handle cost centres', f;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'pb\_%'
              AND has_function_privilege('anon', p.oid, 'EXECUTE')) THEN
    RAISE EXCEPTION 'verify: anon can execute a PB function';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.pb_set_cost_center(date, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'verify: authenticated cannot execute pb_set_cost_center';
  END IF;
END $$;

commit;
