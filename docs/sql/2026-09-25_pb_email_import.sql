-- PB Delivery Daily Report -> staged review -> feed_usage (source 'pb_import')
-- Flow: scheduled task reads the Gmail report, calls stage_pb_report(message_id, text).
--       John reviews the summary, then approve_pb_report(date) posts it.
--       unpost_pb_report(date, reason) backs it out. reject_pb_report(date, reason) discards it.

ALTER TABLE public.ranch_settings ADD COLUMN IF NOT EXISTS pb_email_post_from date;
COMMENT ON COLUMN public.ranch_settings.pb_email_post_from IS
 'First feeding date the PB daily email import may post. NULL = import stages only, never posts. Must stop before feed_truck_post_from once the truck takes over.';

CREATE TABLE IF NOT EXISTS public.pb_name_aliases (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind       text NOT NULL CHECK (kind IN ('pen','item')),
  pb_name    text NOT NULL,
  pasture_id uuid REFERENCES public.pastures(id) ON DELETE CASCADE,
  item_id    uuid REFERENCES public.feed_items(id) ON DELETE CASCADE,
  notes      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pb_alias_shape CHECK ((kind='pen' AND pasture_id IS NOT NULL AND item_id IS NULL)
                                OR (kind='item' AND item_id IS NOT NULL AND pasture_id IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS pb_name_aliases_uniq ON public.pb_name_aliases (kind, lower(pb_name));
COMMENT ON TABLE public.pb_name_aliases IS 'PB email spelling -> our pasture or feed item. One row per PB name that does not match on its own.';

CREATE TABLE IF NOT EXISTS public.pb_daily_reports (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_date      date NOT NULL UNIQUE,
  gmail_message_id text NOT NULL,
  raw_text         text NOT NULL,
  parsed           jsonb NOT NULL,
  status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  problems         text[] NOT NULL DEFAULT '{}',
  notes            text[] NOT NULL DEFAULT '{}',
  usage_rows       integer NOT NULL DEFAULT 0,
  bunk_read_ids    uuid[] NOT NULL DEFAULT '{}',
  staged_at        timestamptz NOT NULL DEFAULT now(),
  reviewed_by      uuid,
  reviewed_at      timestamptz,
  review_notes     text
);
COMMENT ON TABLE public.pb_daily_reports IS
 'PB Delivery Daily Report emails, one per feeding day. Nothing here is in the books until approve_pb_report posts it. problems block approval; notes do not.';

CREATE TABLE IF NOT EXISTS public.pb_report_lines (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id   uuid NOT NULL REFERENCES public.pb_daily_reports(id) ON DELETE CASCADE,
  line_kind   text NOT NULL CHECK (line_kind IN ('drop','ingredient','bunk')),
  load_no     integer,
  ration_name text,
  drop_no     integer,
  pb_name     text NOT NULL,
  target_lb   numeric,
  fed_lb      numeric,
  bunk_score  text,
  pasture_id  uuid REFERENCES public.pastures(id),
  pasture_override uuid REFERENCES public.pastures(id),
  item_id     uuid REFERENCES public.feed_items(id)
);
COMMENT ON COLUMN public.pb_report_lines.pasture_override IS
 'Office correction for this one day: the cart went here, not where PB says. Wins over the name match.';
CREATE INDEX IF NOT EXISTS pb_report_lines_report_idx ON public.pb_report_lines (report_id);

ALTER TABLE public.pb_name_aliases  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pb_daily_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pb_report_lines  ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['pb_name_aliases','pb_daily_reports','pb_report_lines'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %1$s_select ON public.%1$s', t);
    EXECUTE format('DROP POLICY IF EXISTS %1$s_insert ON public.%1$s', t);
    EXECUTE format('DROP POLICY IF EXISTS %1$s_update ON public.%1$s', t);
    EXECUTE format('DROP POLICY IF EXISTS %1$s_delete ON public.%1$s', t);
    EXECUTE format('CREATE POLICY %1$s_select ON public.%1$s FOR SELECT TO authenticated USING (can_read_books())', t);
    EXECUTE format('CREATE POLICY %1$s_insert ON public.%1$s FOR INSERT TO authenticated WITH CHECK (current_user_role() = ANY (ARRAY[''owner'',''office'']))', t);
    EXECUTE format('CREATE POLICY %1$s_update ON public.%1$s FOR UPDATE TO authenticated USING (current_user_role() = ANY (ARRAY[''owner'',''office''])) WITH CHECK (current_user_role() = ANY (ARRAY[''owner'',''office'']))', t);
    EXECUTE format('CREATE POLICY %1$s_delete ON public.%1$s FOR DELETE TO authenticated USING (current_user_role() = ''owner'')', t);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.pb_num(p text) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path TO 'public','pg_temp' AS $$
  SELECT CASE WHEN replace(p, ',', '') ~ '^-?\d+(\.\d+)?$' THEN replace(p, ',', '')::numeric END
$$;

CREATE OR REPLACE FUNCTION public.pb_parse_delivery_email(p_text text)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO 'public','pg_temp' AS $$
DECLARE
  t          text := regexp_replace(COALESCE(p_text, ''), '\s+', ' ', 'g');
  m          text[];
  v_date     date;
  v_end      integer;
  loadsec    text;
  chunk      text;
  rest       text;
  p          integer;
  dsec       text;
  isec       text;
  dtot       text[];
  itot       text[];
  r          text[];
  loads      jsonb := '[]';
  drops      jsonb;
  ings       jsonb;
  bunks      jsonb := '[]';
  problems   text[] := '{}';
  notes      text[] := '{}';
  bunksec    text;
  pen        text;
  sum_t      numeric;
  sum_f      numeric;
  load_no    integer;
BEGIN
  m := regexp_match(t, 'Loads tracked on (\d{2})-(\d{2})-(\d{4})');
  IF m IS NULL THEN
    RETURN jsonb_build_object('report_date', NULL, 'problems', ARRAY['Could not find "Loads tracked on MM-DD-YYYY" - not a PB delivery report or the format changed.']);
  END IF;
  v_date := make_date(m[3]::int, m[1]::int, m[2]::int);

  loadsec := substr(t, strpos(t, 'Loads tracked on') + length('Loads tracked on 00-00-0000'));
  v_end := COALESCE(NULLIF(position('There are no manual delivery' IN loadsec), 0),
                    NULLIF(position('Manual Deliver' IN loadsec), 0),
                    NULLIF(position('Bunk Scores on' IN loadsec), 0),
                    length(loadsec) + 1);
  loadsec := left(loadsec, v_end - 1);

  FOREACH chunk IN ARRAY regexp_split_to_array(loadsec, '(?=Load \d+ \()') LOOP
    chunk := btrim(chunk, ' .');
    CONTINUE WHEN chunk !~ '^Load \d+ \(';
    load_no := (regexp_match(chunk, '^Load (\d+)'))[1]::int;
    p := position(') Target Fed Fed/Target ' IN chunk);
    IF p = 0 THEN
      problems := problems || format('Load %s: header not recognised.', load_no);
      CONTINUE;
    END IF;
    rest := substr(chunk, p + length(') Target Fed Fed/Target '));

    p := position('TOTAL ' IN rest);
    IF p = 0 THEN problems := problems || format('Load %s: no drop TOTAL row.', load_no); CONTINUE; END IF;
    dsec := left(rest, p - 1);
    rest := substr(rest, p);
    dtot := regexp_match(rest, '^TOTAL (\S+) (\S+)');
    rest := regexp_replace(rest, '^TOTAL \S+ \S+ -? ?', '');
    p := position('TOTAL ' IN rest);
    IF p = 0 THEN problems := problems || format('Load %s: no ingredient TOTAL row.', load_no); CONTINUE; END IF;
    isec := left(rest, p - 1);
    itot := regexp_match(substr(rest, p), '^TOTAL (\S+) (\S+)');

    drops := '[]'; sum_t := 0; sum_f := 0;
    FOR r IN SELECT regexp_matches(dsec, '(.+?) \(Drop (\d+)\) (\S+) (\S+) (\S+)%', 'g') LOOP
      IF pb_num(r[3]) IS NULL OR pb_num(r[4]) IS NULL THEN
        problems := problems || format('Load %s drop "%s": numbers not readable (%s / %s).', load_no, btrim(r[1]), r[3], r[4]);
      END IF;
      drops := drops || jsonb_build_object('pen', btrim(r[1]), 'drop_no', r[2]::int,
                                            'target_lb', pb_num(r[3]), 'fed_lb', pb_num(r[4]));
      sum_t := sum_t + COALESCE(pb_num(r[3]), 0); sum_f := sum_f + COALESCE(pb_num(r[4]), 0);
    END LOOP;
    IF jsonb_array_length(drops) = 0 THEN
      problems := problems || format('Load %s: no drops read.', load_no);
    ELSIF sum_t IS DISTINCT FROM pb_num(dtot[1]) OR sum_f IS DISTINCT FROM pb_num(dtot[2]) THEN
      problems := problems || format('Load %s drops: lines add to %s target / %s fed but PB TOTAL says %s / %s.',
                                     load_no, sum_t, sum_f, dtot[1], dtot[2]);
    END IF;

    ings := '[]'; sum_t := 0; sum_f := 0;
    FOR r IN SELECT regexp_matches(isec, '(.+?) (\S+) (\S+) (\S+)%', 'g') LOOP
      IF pb_num(r[2]) IS NULL OR pb_num(r[3]) IS NULL THEN
        problems := problems || format('Load %s ingredient "%s": numbers not readable (%s / %s).', load_no, btrim(r[1]), r[2], r[3]);
      END IF;
      ings := ings || jsonb_build_object('name', btrim(r[1]), 'target_lb', pb_num(r[2]), 'fed_lb', pb_num(r[3]));
      sum_t := sum_t + COALESCE(pb_num(r[2]), 0); sum_f := sum_f + COALESCE(pb_num(r[3]), 0);
    END LOOP;
    IF jsonb_array_length(ings) = 0 THEN
      problems := problems || format('Load %s: no ingredients read.', load_no);
    ELSIF sum_t IS DISTINCT FROM pb_num(itot[1]) OR sum_f IS DISTINCT FROM pb_num(itot[2]) THEN
      problems := problems || format('Load %s ingredients: lines add to %s target / %s fed but PB TOTAL says %s / %s.',
                                     load_no, sum_t, sum_f, itot[1], itot[2]);
    END IF;

    loads := loads || jsonb_build_object(
      'load_no', load_no,
      'ration', btrim(substr(chunk, position('(' IN chunk) + 1, position(') Target Fed Fed/Target ' IN chunk) - position('(' IN chunk) - 1)),
      'drops', drops, 'drop_total', jsonb_build_object('target_lb', pb_num(dtot[1]), 'fed_lb', pb_num(dtot[2])),
      'ingredients', ings, 'ingredient_total', jsonb_build_object('target_lb', pb_num(itot[1]), 'fed_lb', pb_num(itot[2])));
  END LOOP;

  IF jsonb_array_length(loads) = 0 THEN
    notes := notes || 'No loads in this report.'::text;
  END IF;

  IF t !~* 'There are no manual delivery changes' THEN
    notes := notes || 'PB shows MANUAL DELIVERY CHANGES this day - check them in PB; they are not imported.'::text;
  END IF;
  IF t !~* 'There are no head movements' THEN
    notes := notes || 'PB shows HEAD MOVEMENTS this day - not imported; moves come from the app.'::text;
  END IF;

  p := position('Pen Bunk Score ' IN t);
  IF p > 0 THEN
    bunksec := substr(t, p + length('Pen Bunk Score '));
    v_end := position('If you would like' IN bunksec);
    IF v_end > 0 THEN bunksec := left(bunksec, v_end - 1); END IF;
    bunksec := ' ' || btrim(bunksec) || ' ';
    FOR pen IN SELECT DISTINCT d->>'pen' FROM jsonb_array_elements(loads) l, jsonb_array_elements(l->'drops') d LOOP
      r := regexp_match(bunksec, ' ' || regexp_replace(pen, '([.^$*+?()\[\]{}|\\-])', '\\\1', 'g') || ' (N/A|\d+(\.\d+)?) ');
      IF r IS NOT NULL THEN
        bunks := bunks || jsonb_build_object('pen', pen, 'score', r[1]);
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('report_date', v_date, 'loads', loads, 'bunks', bunks,
                            'problems', to_jsonb(problems), 'notes', to_jsonb(notes));
END $$;

CREATE OR REPLACE FUNCTION public.pb_resolve_pen(p_name text) RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp' AS $$
DECLARE v uuid; n text := lower(btrim(regexp_replace(p_name, '\s*-\s*', ' ', 'g')));
BEGIN
  SELECT pasture_id INTO v FROM pb_name_aliases WHERE kind='pen' AND lower(pb_name)=lower(btrim(p_name));
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT p.id INTO v FROM pastures p JOIN ranches r ON r.id=p.ranch_id
   WHERE p.is_active AND lower(r.name || ' ' || p.name) = n;
  IF FOUND AND (SELECT count(*) FROM pastures p JOIN ranches r ON r.id=p.ranch_id
                 WHERE p.is_active AND lower(r.name || ' ' || p.name) = n) = 1 THEN RETURN v; END IF;
  IF (SELECT count(*) FROM pastures WHERE is_active AND lower(name) = n) = 1 THEN
    SELECT id INTO v FROM pastures WHERE is_active AND lower(name) = n;
    RETURN v;
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION public.pb_resolve_item(p_name text) RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp' AS $$
DECLARE v uuid; n text := lower(btrim(p_name));
BEGIN
  SELECT item_id INTO v FROM pb_name_aliases WHERE kind='item' AND lower(pb_name)=n;
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT id INTO v FROM feed_items WHERE lower(COALESCE(pb_name, name)) = n OR lower(name) = n
   ORDER BY is_active DESC, (lower(pb_name) = n) DESC NULLS LAST LIMIT 1;
  RETURN v;
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
  FOR rec IN SELECT DISTINCT l.pb_name FROM pb_report_lines l
              WHERE l.report_id = p_report_id AND l.line_kind = 'drop' AND l.fed_lb > 0 AND l.pasture_id IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM lot_pasture_assignments a
                                 WHERE a.pasture_id = l.pasture_id AND a.head_count > 0
                                   AND a.moved_in <= v_rep.report_date
                                   AND (a.moved_out IS NULL OR a.moved_out >= v_rep.report_date)) LOOP
    probs := probs || format('No lot is standing in "%s" on %s in the app - fix the pasture move first.', rec.pb_name, v_rep.report_date);
  END LOOP;
  FOR rec IN SELECT load_no,
                    SUM(fed_lb) FILTER (WHERE line_kind='drop') d,
                    SUM(fed_lb) FILTER (WHERE line_kind='ingredient') i
               FROM pb_report_lines WHERE report_id = p_report_id AND line_kind <> 'bunk'
              GROUP BY load_no LOOP
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
                AND u.lot_id IN (SELECT a.lot_id FROM pb_report_lines l JOIN lot_pasture_assignments a ON a.pasture_id = l.pasture_id
                                  WHERE l.report_id = p_report_id AND l.line_kind='drop' AND l.fed_lb > 0
                                    AND a.moved_in <= v_rep.report_date
                                    AND (a.moved_out IS NULL OR a.moved_out >= v_rep.report_date)) LOOP
    probs := probs || format('Lot %s already has feed entered by hand covering %s - posting would double it.', rec.lot_number, v_rep.report_date);
  END LOOP;

  UPDATE pb_daily_reports SET problems = probs WHERE id = p_report_id;
  RETURN probs;
END $$;

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
                                                             'target_lb', t, 'fed_lb', f) ORDER BY pb_name), '[]')
                 FROM (SELECT l.pb_name, rn.name || ' ' || p.name pname, SUM(l.target_lb) t, SUM(l.fed_lb) f
                         FROM pb_report_lines l LEFT JOIN pastures p ON p.id = l.pasture_id LEFT JOIN ranches rn ON rn.id = p.ranch_id
                        WHERE l.report_id = r.id AND l.line_kind='drop' GROUP BY 1,2) s),
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

CREATE OR REPLACE FUNCTION public.stage_pb_report(p_message_id text, p_text text)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
DECLARE
  v_parsed jsonb := pb_parse_delivery_email(p_text);
  v_date   date := (v_parsed->>'report_date')::date;
  v_rep    pb_daily_reports%ROWTYPE;
  l        jsonb;
  x        jsonb;
BEGIN
  IF v_date IS NULL THEN
    RAISE EXCEPTION 'stage_pb_report: %', v_parsed->'problems'->>0;
  END IF;
  SELECT * INTO v_rep FROM pb_daily_reports WHERE report_date = v_date FOR UPDATE;
  IF FOUND AND v_rep.status = 'approved' THEN
    RETURN pb_report_summary(v_date) || jsonb_build_object('staging', 'already approved - left alone');
  END IF;

  IF FOUND THEN
    DELETE FROM pb_report_lines WHERE report_id = v_rep.id;
    UPDATE pb_daily_reports
       SET gmail_message_id = p_message_id, raw_text = p_text, parsed = v_parsed, status = 'pending',
           notes = ARRAY(SELECT jsonb_array_elements_text(v_parsed->'notes')),
           staged_at = now(), reviewed_by = NULL, reviewed_at = NULL, review_notes = NULL
     WHERE id = v_rep.id;
  ELSE
    INSERT INTO pb_daily_reports (report_date, gmail_message_id, raw_text, parsed, notes)
    VALUES (v_date, p_message_id, p_text, v_parsed, ARRAY(SELECT jsonb_array_elements_text(v_parsed->'notes')))
    RETURNING * INTO v_rep;
  END IF;

  FOR l IN SELECT * FROM jsonb_array_elements(v_parsed->'loads') LOOP
    FOR x IN SELECT * FROM jsonb_array_elements(l->'drops') LOOP
      INSERT INTO pb_report_lines (report_id, line_kind, load_no, ration_name, drop_no, pb_name, target_lb, fed_lb)
      VALUES (v_rep.id, 'drop', (l->>'load_no')::int, l->>'ration', (x->>'drop_no')::int, x->>'pen',
              (x->>'target_lb')::numeric, (x->>'fed_lb')::numeric);
    END LOOP;
    FOR x IN SELECT * FROM jsonb_array_elements(l->'ingredients') LOOP
      INSERT INTO pb_report_lines (report_id, line_kind, load_no, ration_name, pb_name, target_lb, fed_lb)
      VALUES (v_rep.id, 'ingredient', (l->>'load_no')::int, l->>'ration', x->>'name',
              (x->>'target_lb')::numeric, (x->>'fed_lb')::numeric);
    END LOOP;
  END LOOP;
  FOR x IN SELECT * FROM jsonb_array_elements(v_parsed->'bunks') LOOP
    INSERT INTO pb_report_lines (report_id, line_kind, pb_name, bunk_score)
    VALUES (v_rep.id, 'bunk', x->>'pen', x->>'score');
  END LOOP;

  PERFORM pb_refresh_report(v_rep.id);
  RETURN pb_report_summary(v_date) || jsonb_build_object('staging', 'staged');
END $$;

CREATE OR REPLACE FUNCTION public.approve_pb_report(p_report_date date, p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
DECLARE
  v_rep    pb_daily_reports%ROWTYPE;
  probs    text[];
  ld       record;
  ing      record;
  b        record;
  d        record;
  v_lots   uuid[];
  v_lb     numeric[];
  v_parts  numeric[];
  h_lots   uuid[];
  h_heads  numeric[];
  h_parts  numeric[];
  v_rows   integer := 0;
  v_bunks  uuid[] := '{}';
  v_bid    uuid;
  v_score  numeric;
  i        integer;
  k        integer;
  pos      integer;
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

  FOR ld IN SELECT DISTINCT load_no, ration_name FROM pb_report_lines
             WHERE report_id = v_rep.id AND line_kind = 'drop' ORDER BY load_no LOOP
    -- Lot weights for this load: each drop's fed lb split by head standing in that pasture.
    v_lots := '{}'; v_lb := '{}';
    FOR d IN SELECT pasture_id, fed_lb FROM pb_report_lines
              WHERE report_id = v_rep.id AND line_kind = 'drop' AND load_no = ld.load_no AND fed_lb > 0 LOOP
      SELECT array_agg(lot_id ORDER BY lot_id), array_agg(head ORDER BY lot_id) INTO h_lots, h_heads
        FROM (SELECT a.lot_id, SUM(a.head_count)::numeric head
                FROM lot_pasture_assignments a
               WHERE a.pasture_id = d.pasture_id
                 AND a.moved_in <= p_report_date
                 AND (a.moved_out IS NULL OR a.moved_out >= p_report_date)
               GROUP BY a.lot_id HAVING SUM(a.head_count) > 0) s;
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

    FOR ing IN SELECT l.item_id, fi.default_location_id loc, SUM(l.fed_lb) lb
                 FROM pb_report_lines l JOIN feed_items fi ON fi.id = l.item_id
                WHERE l.report_id = v_rep.id AND l.line_kind = 'ingredient' AND l.load_no = ld.load_no AND l.fed_lb > 0
                GROUP BY 1,2 LOOP
      v_parts := lr_split(ing.lb, v_lb, 2);
      FOR i IN 1..cardinality(v_lots) LOOP
        CONTINUE WHEN v_parts[i] <= 0;
        PERFORM post_feed_usage(
          p_item_id          => ing.item_id,
          p_from_location_id => ing.loc,
          p_qty_lb           => v_parts[i],
          p_destination_type => 'lot',
          p_period_start     => p_report_date,
          p_period_end       => p_report_date,
          p_lot_id           => v_lots[i],
          p_usage_date       => p_report_date,
          p_source           => 'pb_import',
          p_pb_row_key       => format('pbmail:%s:L%s:%s:%s', p_report_date, ld.load_no, ing.item_id, v_lots[i]),
          p_notes            => format('PB email %s load %s (%s)', p_report_date, ld.load_no, ld.ration_name));
        v_rows := v_rows + 1;
      END LOOP;
    END LOOP;
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

CREATE OR REPLACE FUNCTION public.pb_move_drop(p_report_date date, p_pb_pen text, p_ranch text, p_pasture text)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
DECLARE v_rep pb_daily_reports%ROWTYPE; v_p uuid; n integer;
BEGIN
  SELECT * INTO v_rep FROM pb_daily_reports WHERE report_date = p_report_date FOR UPDATE;
  IF NOT FOUND OR v_rep.status <> 'pending' THEN
    RAISE EXCEPTION 'pb_move_drop: no pending PB report for %.', p_report_date;
  END IF;
  SELECT p.id INTO v_p FROM pastures p JOIN ranches r ON r.id = p.ranch_id
   WHERE lower(r.name) = lower(btrim(p_ranch)) AND lower(p.name) = lower(btrim(p_pasture)) AND p.is_active;
  IF v_p IS NULL THEN RAISE EXCEPTION 'pb_move_drop: no active pasture "%" on ranch "%".', p_pasture, p_ranch; END IF;
  UPDATE pb_report_lines SET pasture_override = v_p
   WHERE report_id = v_rep.id AND line_kind = 'drop' AND lower(pb_name) = lower(btrim(p_pb_pen));
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'pb_move_drop: no drop to "%" on %.', p_pb_pen, p_report_date; END IF;
  PERFORM pb_refresh_report(v_rep.id);
  RETURN pb_report_summary(p_report_date);
END $$;

CREATE OR REPLACE FUNCTION public.unpost_pb_report(p_report_date date, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
DECLARE v_rep pb_daily_reports%ROWTYPE; u record; n integer := 0;
BEGIN
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'unpost_pb_report: give a reason.'; END IF;
  SELECT * INTO v_rep FROM pb_daily_reports WHERE report_date = p_report_date FOR UPDATE;
  IF NOT FOUND OR v_rep.status <> 'approved' THEN
    RAISE EXCEPTION 'unpost_pb_report: no approved PB report for %.', p_report_date;
  END IF;
  FOR u IN SELECT id FROM feed_usage WHERE pb_row_key LIKE format('pbmail:%s:%%', p_report_date) LOOP
    PERFORM delete_feed_usage(u.id); n := n + 1;
  END LOOP;
  DELETE FROM bunk_reads WHERE id = ANY (v_rep.bunk_read_ids);
  UPDATE pb_daily_reports
     SET status = 'pending', usage_rows = 0, bunk_read_ids = '{}',
         review_notes = COALESCE(review_notes || ' | ', '') || 'Unposted ' || now()::date || ': ' || p_reason
   WHERE id = v_rep.id;
  RETURN jsonb_build_object('report_date', p_report_date, 'usage_rows_removed', n);
END $$;

CREATE OR REPLACE FUNCTION public.reject_pb_report(p_report_date date, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
BEGIN
  UPDATE pb_daily_reports SET status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), review_notes = p_reason
   WHERE report_date = p_report_date AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'reject_pb_report: no pending PB report for %.', p_report_date; END IF;
  RETURN pb_report_summary(p_report_date);
END $$;
