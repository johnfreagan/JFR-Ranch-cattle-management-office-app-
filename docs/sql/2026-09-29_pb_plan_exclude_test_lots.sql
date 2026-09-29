-- 2026-09-29. Dry run of the 9/28 PB report would have charged 27,120 lb to TEST_DOC2 (is_test, 50 hd
-- parked in Garrett Goat Hill since April). Test lots and lots closed before the day never take feed.
-- One posting plan (pb_plan) now drives both approve_pb_report and the Feed tab preview, so what the
-- office sees is exactly what posts.

CREATE OR REPLACE FUNCTION public.pb_lots_standing(p_pasture uuid, p_date date)
RETURNS TABLE (lot_id uuid, head numeric)
LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $$
  SELECT a.lot_id, SUM(a.head_count)::numeric
    FROM lot_pasture_assignments a JOIN lots l ON l.id = a.lot_id
   WHERE a.pasture_id = p_pasture
     AND a.moved_in <= p_date
     AND (a.moved_out IS NULL OR a.moved_out >= p_date)
     AND NOT COALESCE(l.is_test, false)
     AND (l.closed_at IS NULL OR l.closed_at::date >= p_date)
   GROUP BY a.lot_id
  HAVING SUM(a.head_count) > 0
$$;
COMMENT ON FUNCTION public.pb_lots_standing(uuid, date) IS
 'Real lots standing in a pasture on a day, with head. Excludes is_test lots and lots closed before the day. Used by PB feed posting.';

-- The posting plan: one row per load x lot x item. Nothing is written.
CREATE OR REPLACE FUNCTION public.pb_plan(p_report_id uuid)
RETURNS TABLE (load_no integer, ration_name text, lot_id uuid, item_id uuid, from_location_id uuid, qty_lb numeric)
LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp' AS $$
DECLARE
  v_date   date;
  ld       record;
  d        record;
  ing      record;
  v_lots   uuid[];
  v_lb     numeric[];
  v_parts  numeric[];
  h_lots   uuid[];
  h_heads  numeric[];
  h_parts  numeric[];
  i        integer;
  k        integer;
  pos      integer;
BEGIN
  SELECT report_date INTO v_date FROM pb_daily_reports WHERE id = p_report_id;
  FOR ld IN SELECT DISTINCT l.load_no, l.ration_name FROM pb_report_lines l
             WHERE l.report_id = p_report_id AND l.line_kind = 'drop' ORDER BY l.load_no LOOP
    v_lots := '{}'; v_lb := '{}';
    FOR d IN SELECT l.pasture_id, l.fed_lb FROM pb_report_lines l
              WHERE l.report_id = p_report_id AND l.line_kind = 'drop' AND l.load_no = ld.load_no
                AND l.fed_lb > 0 AND l.pasture_id IS NOT NULL LOOP
      SELECT array_agg(s.lot_id ORDER BY s.lot_id), array_agg(s.head ORDER BY s.lot_id) INTO h_lots, h_heads
        FROM pb_lots_standing(d.pasture_id, v_date) s;
      CONTINUE WHEN h_lots IS NULL;
      h_parts := lr_split(d.fed_lb, h_heads, 2);
      FOR k IN 1..array_length(h_lots, 1) LOOP
        pos := array_position(v_lots, h_lots[k]);
        IF pos IS NULL THEN
          v_lots := v_lots || h_lots[k]; v_lb := v_lb || h_parts[k];
        ELSE
          v_lb[pos] := v_lb[pos] + h_parts[k];
        END IF;
      END LOOP;
    END LOOP;
    CONTINUE WHEN cardinality(v_lots) = 0;

    FOR ing IN SELECT l.item_id AS it, fi.default_location_id AS loc, SUM(l.fed_lb) AS lb
                 FROM pb_report_lines l JOIN feed_items fi ON fi.id = l.item_id
                WHERE l.report_id = p_report_id AND l.line_kind = 'ingredient' AND l.load_no = ld.load_no AND l.fed_lb > 0
                GROUP BY 1,2 LOOP
      v_parts := lr_split(ing.lb, v_lb, 2);
      FOR i IN 1..cardinality(v_lots) LOOP
        CONTINUE WHEN v_parts[i] <= 0;
        load_no := ld.load_no; ration_name := ld.ration_name; lot_id := v_lots[i];
        item_id := ing.it; from_location_id := ing.loc; qty_lb := v_parts[i];
        RETURN NEXT;
      END LOOP;
    END LOOP;
  END LOOP;
END $$;

-- Refresh: "standing" now means real, open lots.
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
              WHERE l.report_id = p_report_id AND l.line_kind = 'drop' AND l.fed_lb > 0
                AND NOT EXISTS (SELECT 1 FROM pb_lots_standing(l.pasture_id, v_rep.report_date)) LOOP
    probs := probs || format('No real lot is standing in %s on %s in the app%s - enter the pasture moves first, or Move/Split this drop.',
                             rec.pname, v_rep.report_date,
                             CASE WHEN rec.skipped IS NOT NULL THEN ' (only test/closed lot ' || rec.skipped || ')' ELSE '' END);
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
                                  WHERE l.report_id = p_report_id AND l.line_kind='drop' AND l.fed_lb > 0 AND l.pasture_id IS NOT NULL) LOOP
    probs := probs || format('Lot %s already has feed entered by hand covering %s - posting would double it.', rec.lot_number, v_rep.report_date);
  END LOOP;

  UPDATE pb_daily_reports SET problems = probs WHERE id = p_report_id;
  RETURN probs;
END $$;

-- Approve posts exactly the plan.
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

  FOR pl IN SELECT * FROM pb_plan(v_rep.id) LOOP
    PERFORM post_feed_usage(
      p_item_id          => pl.item_id,
      p_from_location_id => pl.from_location_id,
      p_qty_lb           => pl.qty_lb,
      p_destination_type => 'lot',
      p_period_start     => p_report_date,
      p_period_end       => p_report_date,
      p_lot_id           => pl.lot_id,
      p_usage_date       => p_report_date,
      p_source           => 'pb_import',
      p_pb_row_key       => format('pbmail:%s:L%s:%s:%s', p_report_date, pl.load_no, pl.item_id, pl.lot_id),
      p_notes            => format('PB email %s load %s (%s)', p_report_date, pl.load_no, pl.ration_name));
    v_rows := v_rows + 1;
  END LOOP;

  FOR b IN SELECT pasture_id, bunk_score FROM pb_report_lines
            WHERE report_id = v_rep.id AND line_kind = 'bunk' AND pasture_id IS NOT NULL AND bunk_score ~ '^\d+(\.\d+)?$' LOOP
    v_score := b.bunk_score::numeric;
    v_bid := NULL;
    INSERT INTO bunk_reads (read_date, pasture_id, bunk_score, notes)
    VALUES (p_report_date, b.pasture_id,
            CASE WHEN v_score IN (0, 0.5, 1, 2, 3) THEN v_score END,
            'PB email score ' || b.bunk_score)
    ON CONFLICT (read_date, pasture_id) DO NOTHING
    RETURNING id INTO v_bid;
    IF v_bid IS NOT NULL THEN v_bunks := v_bunks || v_bid; END IF;
  END LOOP;

  UPDATE pb_daily_reports
     SET status = 'approved', usage_rows = v_rows, bunk_read_ids = v_bunks,
         reviewed_by = auth.uid(), reviewed_at = now(), review_notes = p_notes
   WHERE id = v_rep.id;
  RETURN pb_report_summary(p_report_date);
END $$;

-- Feed tab "Charges to" section: pending = the plan; approved = what actually posted.
CREATE OR REPLACE FUNCTION public.pb_report_charges(p_date date) RETURNS jsonb
LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $$
  WITH r AS (SELECT * FROM pb_daily_reports WHERE report_date = p_date),
  rows AS (
    SELECT p.lot_id, p.item_id, p.qty_lb FROM r, LATERAL pb_plan(r.id) p WHERE r.status = 'pending'
    UNION ALL
    SELECT u.lot_id, u.item_id, u.qty_lb FROM r JOIN feed_usage u ON u.pb_row_key LIKE format('pbmail:%s:%%', r.report_date)
     WHERE r.status = 'approved'),
  per_lot AS (
    SELECT lo.lot_number, SUM(x.qty_lb) lb,
           jsonb_agg(jsonb_build_object('item', i.name, 'lb', x.qty_lb) ORDER BY i.name) items
      FROM (SELECT lot_id, item_id, SUM(qty_lb) qty_lb FROM rows GROUP BY 1,2) x
      JOIN lots lo ON lo.id = x.lot_id JOIN feed_items i ON i.id = x.item_id
     GROUP BY lo.lot_number)
  SELECT jsonb_build_object(
    'basis', (SELECT CASE WHEN status = 'approved' THEN 'posted' ELSE 'plan' END FROM r),
    'total_lb', COALESCE((SELECT SUM(lb) FROM per_lot), 0),
    'lots', COALESCE((SELECT jsonb_agg(jsonb_build_object('lot', lot_number, 'lb', lb, 'items', items) ORDER BY lb DESC) FROM per_lot), '[]'))
$$;
COMMENT ON FUNCTION public.pb_report_charges(date) IS
 'Approvals > Feed. Lot x item pounds: the posting plan for a pending report, the posted feed_usage rows for an approved one.';

CREATE OR REPLACE FUNCTION public.pb_report_list(p_days integer DEFAULT 30)
RETURNS jsonb LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $$
  SELECT COALESCE(jsonb_agg(pb_report_summary(r.report_date)
           || jsonb_build_object('staged_at', r.staged_at, 'reviewed_at', r.reviewed_at,
                                 'reviewed_by', (SELECT full_name FROM user_profiles WHERE id = r.reviewed_by),
                                 'review_notes', r.review_notes,
                                 'charges', pb_report_charges(r.report_date))
           ORDER BY (r.status = 'pending') DESC, r.report_date DESC), '[]'::jsonb)
    FROM pb_daily_reports r
   WHERE r.report_date >= ranch_today() - p_days OR r.status = 'pending'
$$;

REVOKE EXECUTE ON FUNCTION public.pb_lots_standing(uuid, date) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.pb_plan(uuid) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.pb_report_charges(date) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.pb_lots_standing(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pb_plan(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pb_report_charges(date) TO authenticated;