-- 2026-09-29. Prefeed: feed dropped into a pasture before cattle arrive.
-- Decision (John): FIRST LOT IN PAYS. The feed leaves the barn on the feed day and sits in a per-pasture
-- holding location at cost ("Prefeed - <ranch> <pasture>"). The first day a real lot stands in that pasture
-- (on or before today), the whole hold is charged to the lots standing that day, split by head.
-- Also fixes pb_plan: a load's ingredients are split across ALL its drops by drop pounds first, then each
-- drop to its lots by head. Before, a load that dropped into two pastures charged all ingredients to the
-- pasture that had lots.

ALTER TABLE public.pb_report_lines ADD COLUMN IF NOT EXISTS prefeed boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.pb_report_lines.prefeed IS
 'Office marked this drop as prefeed: no cattle in the pasture yet. Posts to the pasture''s prefeed hold; first lot in pays.';

ALTER TABLE public.feed_storage_locations ADD COLUMN IF NOT EXISTS prefeed_pasture_id uuid REFERENCES public.pastures(id);
CREATE UNIQUE INDEX IF NOT EXISTS feed_storage_locations_prefeed_uniq ON public.feed_storage_locations (prefeed_pasture_id) WHERE prefeed_pasture_id IS NOT NULL;
COMMENT ON COLUMN public.feed_storage_locations.prefeed_pasture_id IS
 'Set = this location is the prefeed hold for that pasture: feed dropped before cattle arrived, still owned, not yet charged to a lot.';

CREATE TABLE IF NOT EXISTS public.feed_prefeed_holds (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id         uuid REFERENCES public.pb_daily_reports(id),
  pasture_id        uuid NOT NULL REFERENCES public.pastures(id),
  feed_date         date NOT NULL,
  load_no           integer,
  item_id           uuid NOT NULL REFERENCES public.feed_items(id),
  location_id       uuid NOT NULL REFERENCES public.feed_storage_locations(id),
  qty_lb            numeric NOT NULL CHECK (qty_lb > 0),
  transfer_usage_id uuid,
  status            text NOT NULL DEFAULT 'held' CHECK (status IN ('held','charged')),
  charged_on        date,
  charged_lots      jsonb,
  last_error        text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS feed_prefeed_holds_held_idx ON public.feed_prefeed_holds (pasture_id) WHERE status = 'held';
COMMENT ON TABLE public.feed_prefeed_holds IS
 'Prefeed waiting for cattle. One row per report x load x pasture x item. First lot in pays: charged whole to the lots standing on the first day real cattle are in the pasture.';

ALTER TABLE public.feed_prefeed_holds ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS feed_prefeed_holds_select ON public.feed_prefeed_holds;
DROP POLICY IF EXISTS feed_prefeed_holds_insert ON public.feed_prefeed_holds;
DROP POLICY IF EXISTS feed_prefeed_holds_update ON public.feed_prefeed_holds;
DROP POLICY IF EXISTS feed_prefeed_holds_delete ON public.feed_prefeed_holds;
CREATE POLICY feed_prefeed_holds_select ON public.feed_prefeed_holds FOR SELECT TO authenticated USING (can_read_books());
CREATE POLICY feed_prefeed_holds_insert ON public.feed_prefeed_holds FOR INSERT TO authenticated WITH CHECK (current_user_role() = ANY (ARRAY['owner','office']));
CREATE POLICY feed_prefeed_holds_update ON public.feed_prefeed_holds FOR UPDATE TO authenticated USING (current_user_role() = ANY (ARRAY['owner','office'])) WITH CHECK (current_user_role() = ANY (ARRAY['owner','office']));
CREATE POLICY feed_prefeed_holds_delete ON public.feed_prefeed_holds FOR DELETE TO authenticated USING (current_user_role() = 'owner');

-- Holding location for a pasture, created on first use.
CREATE OR REPLACE FUNCTION public.prefeed_location(p_pasture uuid) RETURNS uuid
LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
DECLARE v uuid; v_name text;
BEGIN
  SELECT id INTO v FROM feed_storage_locations WHERE prefeed_pasture_id = p_pasture;
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT 'Prefeed - ' || r.name || ' ' || p.name INTO v_name FROM pastures p JOIN ranches r ON r.id = p.ranch_id WHERE p.id = p_pasture;
  INSERT INTO feed_storage_locations (name, kind, is_bulk, prefeed_pasture_id, notes)
  VALUES (v_name, 'other', true, p_pasture, 'Feed dropped in this pasture before cattle arrived. Charged to the first lot in.')
  RETURNING id INTO v;
  RETURN v;
END $$;

-- The posting plan. lot_id set = charge that lot; prefeed_pasture_id set = hold for that pasture.
DROP FUNCTION IF EXISTS public.pb_plan(uuid);
CREATE FUNCTION public.pb_plan(p_report_id uuid)
RETURNS TABLE (load_no integer, ration_name text, lot_id uuid, prefeed_pasture_id uuid, item_id uuid, from_location_id uuid, qty_lb numeric)
LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp' AS $$
DECLARE
  v_date   date;
  ld       record;
  ing      record;
  d_ids    uuid[];
  d_past   uuid[];
  d_pre    boolean[];
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
    SELECT array_agg(l.id ORDER BY l.id), array_agg(l.pasture_id ORDER BY l.id), array_agg(l.prefeed ORDER BY l.id), array_agg(l.fed_lb ORDER BY l.id)
      INTO d_ids, d_past, d_pre, d_lb
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
        IF d_pre[i] THEN
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
      SELECT ld.load_no, ld.ration_name, x.lot, x.pre, x.item, x.loc, SUM(x.lb)
        FROM jsonb_to_recordset(acc) AS x(lot uuid, pre uuid, item uuid, loc uuid, lb numeric)
       GROUP BY x.lot, x.pre, x.item, x.loc;
    acc := '[]';
  END LOOP;
END $$;

-- Mark / unmark a pen's drop as prefeed for a pending day.
CREATE OR REPLACE FUNCTION public.pb_mark_prefeed(p_report_date date, p_pb_pen text, p_on boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
DECLARE v_rep pb_daily_reports%ROWTYPE; n integer;
BEGIN
  SELECT * INTO v_rep FROM pb_daily_reports WHERE report_date = p_report_date FOR UPDATE;
  IF NOT FOUND OR v_rep.status <> 'pending' THEN
    RAISE EXCEPTION 'pb_mark_prefeed: no pending PB report for %.', p_report_date;
  END IF;
  UPDATE pb_report_lines SET prefeed = p_on
   WHERE report_id = v_rep.id AND line_kind = 'drop' AND pb_norm(pb_name) = pb_norm(p_pb_pen);
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'pb_mark_prefeed: no drop to "%" on %.', p_pb_pen, p_report_date; END IF;
  PERFORM pb_refresh_report(v_rep.id);
  RETURN pb_report_summary(p_report_date) || jsonb_build_object('charges', pb_report_charges(p_report_date));
END $$;

-- Refresh: prefeed drops skip the "no lot standing" block, but may not be marked where lots ARE standing.
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
              WHERE l.report_id = p_report_id AND l.line_kind = 'drop' AND l.fed_lb > 0 AND NOT l.prefeed
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

-- Charge every held prefeed whose pasture now has real cattle. First lot in pays, split by head.
-- Never raises: a hold that can't charge keeps its error in last_error and stays held.
CREATE OR REPLACE FUNCTION public.pb_charge_prefeeds(p_pasture uuid DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
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
          p_lot_id => v_lots[k], p_usage_date => v_day, p_source => 'pb_import',
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
END $$;

-- Cattle moving into a pasture with held prefeed charge it right away. Never blocks the move.
CREATE OR REPLACE FUNCTION public.lpa_charge_prefeed() RETURNS trigger
LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM feed_prefeed_holds WHERE status = 'held' AND pasture_id = NEW.pasture_id) THEN
    BEGIN
      PERFORM pb_charge_prefeeds(NEW.pasture_id);
    EXCEPTION WHEN others THEN NULL;  -- per-hold errors are already recorded in last_error
    END;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS lpa_charge_prefeed ON public.lot_pasture_assignments;
CREATE TRIGGER lpa_charge_prefeed AFTER INSERT OR UPDATE OF pasture_id, moved_in, head_count ON public.lot_pasture_assignments
  FOR EACH ROW EXECUTE FUNCTION lpa_charge_prefeed();

-- Approve: lot rows post to lots; prefeed rows move to the pasture's hold; then sweep holds.
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

  FOR pl IN SELECT * FROM pb_plan(v_rep.id) LOOP
    IF pl.lot_id IS NOT NULL THEN
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

-- Unpost backs out prefeed charges, then the holds, then the day. Owner only (deletes feed_usage).
CREATE OR REPLACE FUNCTION public.unpost_pb_report(p_report_date date, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
DECLARE v_rep pb_daily_reports%ROWTYPE; u record; n integer := 0;
BEGIN
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'unpost_pb_report: give a reason.'; END IF;
  SELECT * INTO v_rep FROM pb_daily_reports WHERE report_date = p_report_date FOR UPDATE;
  IF NOT FOUND OR v_rep.status <> 'approved' THEN
    RAISE EXCEPTION 'unpost_pb_report: no approved PB report for %.', p_report_date;
  END IF;
  FOR u IN SELECT fu.id FROM feed_usage fu JOIN feed_prefeed_holds h ON fu.pb_row_key LIKE 'pbpre:' || h.id || ':%'
            WHERE h.report_id = v_rep.id LOOP
    PERFORM delete_feed_usage(u.id); n := n + 1;
  END LOOP;
  FOR u IN SELECT id FROM feed_usage WHERE pb_row_key LIKE format('pbmail:%s:%%', p_report_date) LOOP
    PERFORM delete_feed_usage(u.id); n := n + 1;
  END LOOP;
  DELETE FROM feed_prefeed_holds WHERE report_id = v_rep.id;
  DELETE FROM bunk_reads WHERE id = ANY (v_rep.bunk_read_ids);
  UPDATE pb_daily_reports
     SET status = 'pending', usage_rows = 0, bunk_read_ids = '{}',
         review_notes = COALESCE(review_notes || ' | ', '') || 'Unposted ' || now()::date || ': ' || p_reason
   WHERE id = v_rep.id;
  RETURN jsonb_build_object('report_date', p_report_date, 'usage_rows_removed', n);
END $$;

-- Feed tab "Charges to": lots, plus prefeed held/charged.
CREATE OR REPLACE FUNCTION public.pb_report_charges(p_date date) RETURNS jsonb
LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $$
  WITH r AS (SELECT * FROM pb_daily_reports WHERE report_date = p_date),
  rows AS (
    SELECT p.lot_id, p.item_id, p.qty_lb FROM r, LATERAL pb_plan(r.id) p WHERE r.status = 'pending' AND p.lot_id IS NOT NULL
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
      FROM r, LATERAL pb_plan(r.id) p WHERE r.status = 'pending' AND p.prefeed_pasture_id IS NOT NULL
    UNION ALL
    SELECT h.pasture_id, h.item_id, h.qty_lb, h.status, h.charged_on, h.last_error
      FROM r JOIN feed_prefeed_holds h ON h.report_id = r.id),
  per_pre AS (
    SELECT rn.name || ' ' || pa.name AS pasture, x.state, x.charged_on, SUM(x.qty_lb) lb,
           jsonb_agg(jsonb_build_object('item', i.name, 'lb', x.qty_lb) ORDER BY i.name) items,
           max(x.err) AS error
      FROM pre x JOIN pastures pa ON pa.id = x.pasture_id JOIN ranches rn ON rn.id = pa.ranch_id JOIN feed_items i ON i.id = x.item_id
     GROUP BY 1,2,3)
  SELECT jsonb_build_object(
    'basis', (SELECT CASE WHEN status = 'approved' THEN 'posted' ELSE 'plan' END FROM r),
    'total_lb', COALESCE((SELECT SUM(lb) FROM per_lot), 0) + COALESCE((SELECT SUM(lb) FROM per_pre), 0),
    'lots', COALESCE((SELECT jsonb_agg(jsonb_build_object('lot', lot_number, 'lb', lb, 'items', items) ORDER BY lb DESC) FROM per_lot), '[]'),
    'prefeed', COALESCE((SELECT jsonb_agg(jsonb_build_object('pasture', pasture, 'state', state, 'charged_on', charged_on, 'lb', lb, 'items', items, 'error', error)) FROM per_pre), '[]'))
$$;

-- Everything still waiting for cattle, for the Feed tab header and morning triage.
CREATE OR REPLACE FUNCTION public.prefeed_waiting() RETURNS jsonb
LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('pasture', pname, 'fed', feed_date, 'lb', lb, 'days_waiting', ranch_today() - feed_date, 'error', err)
                            ORDER BY feed_date), '[]')
    FROM (SELECT r.name || ' ' || p.name pname, h.feed_date, SUM(h.qty_lb) lb, max(h.last_error) err
            FROM feed_prefeed_holds h JOIN pastures p ON p.id = h.pasture_id JOIN ranches r ON r.id = p.ranch_id
           WHERE h.status = 'held' GROUP BY 1,2) s
$$;

REVOKE EXECUTE ON FUNCTION public.prefeed_location(uuid) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.pb_plan(uuid) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.pb_mark_prefeed(date, text, boolean) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.pb_charge_prefeeds(uuid) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.pb_report_charges(date) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.prefeed_waiting() FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.approve_pb_report(date, text) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.unpost_pb_report(date, text) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.pb_refresh_report(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.prefeed_location(uuid), public.pb_plan(uuid), public.pb_mark_prefeed(date, text, boolean),
  public.pb_charge_prefeeds(uuid), public.pb_report_charges(date), public.prefeed_waiting(),
  public.approve_pb_report(date, text), public.unpost_pb_report(date, text), public.pb_refresh_report(uuid) TO authenticated;