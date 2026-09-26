-- PB changed the Delivery Daily Report layout (seen 2026-09-25). Parser now reads both:
--   old: "Loads tracked on MM-DD-YYYY", "Load 1 (Ration)", "TOTAL a b -"
--   new: "delivery report for <ranch> on MM-DD-YYYY", "Load 1 Ration", "Total a b - - -", "Head Movement on ..." table
-- Name matching ignores case, spaces and punctuation ("CornFeed" = "Corn (Feed)", "Corrid Crumbles 2.5" = "Corrid Crumbles 2.5%").

CREATE OR REPLACE FUNCTION public.pb_norm(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'public','pg_temp' AS $$
  SELECT regexp_replace(lower(COALESCE(p, '')), '[^a-z0-9]', '', 'g')
$$;

CREATE OR REPLACE FUNCTION public.pb_parse_delivery_email(p_text text)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO 'public','pg_temp' AS $$
DECLARE
  t          text := regexp_replace(COALESCE(p_text, ''), '\s+', ' ', 'g');
  m          text[];
  v_date     date;
  v_end      integer;
  v_cut      integer;
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
  hmsec      text;
  pen        text;
  ration     text;
  sum_t      numeric;
  sum_f      numeric;
  load_no    integer;
  marker     text;
BEGIN
  m := regexp_match(t, '((?:Loads tracked on|delivery report for .{1,80}? on) (\d{2})-(\d{2})-(\d{4}))', 'i');
  IF m IS NULL THEN
    RETURN jsonb_build_object('report_date', NULL, 'problems',
      ARRAY['Could not find the report date - not a PB delivery report or the format changed again.']);
  END IF;
  v_date := make_date(m[4]::int, m[2]::int, m[3]::int);

  loadsec := substr(t, strpos(t, m[1]) + length(m[1]));
  -- End of the loads section = the earliest trailing-section marker found.
  v_end := length(loadsec) + 1;
  FOREACH marker IN ARRAY ARRAY['There are no manual delivery', 'Manual Deliver', 'There are no head movement',
                                'Head Movement on', 'Bunk Scores on'] LOOP
    v_cut := strpos(lower(loadsec), lower(marker));
    IF v_cut > 0 AND v_cut < v_end THEN v_end := v_cut; END IF;
  END LOOP;
  loadsec := left(loadsec, v_end - 1);

  FOREACH chunk IN ARRAY regexp_split_to_array(loadsec, '(?=Load \d+ )') LOOP
    chunk := btrim(chunk, ' .');
    CONTINUE WHEN chunk !~ '^Load \d+ ';
    load_no := (regexp_match(chunk, '^Load (\d+)'))[1]::int;
    p := strpos(chunk, ' Target Fed Fed/Target ');
    IF p = 0 THEN
      problems := problems || format('Load %s: header not recognised.', load_no);
      CONTINUE;
    END IF;
    ration := btrim(substr(chunk, length('Load ' || load_no) + 2, p - length('Load ' || load_no) - 2));
    ration := btrim(regexp_replace(ration, '^\((.*)\)$', '\1'));
    rest := substr(chunk, p + length(' Target Fed Fed/Target '));

    -- drops ... Total t f - [- -]  ingredients ... Total t f - [- -]
    p := regexp_instr(rest, '(^| )total -?[\d,.]+ -?[\d,.]+', 1, 1, 0, 'i');
    IF p = 0 THEN problems := problems || format('Load %s: no drop Total row.', load_no); CONTINUE; END IF;
    dsec := left(rest, p);
    rest := btrim(substr(rest, p));
    dtot := regexp_match(rest, '^total (\S+) (\S+)', 'i');
    rest := regexp_replace(rest, '^total \S+ \S+( -)* ?', '', 'i');
    p := regexp_instr(rest, '(^| )total -?[\d,.]+ -?[\d,.]+', 1, 1, 0, 'i');
    IF p = 0 THEN problems := problems || format('Load %s: no ingredient Total row.', load_no); CONTINUE; END IF;
    isec := left(rest, p);
    itot := regexp_match(btrim(substr(rest, p)), '^total (\S+) (\S+)', 'i');

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
      problems := problems || format('Load %s drops: lines add to %s target / %s fed but PB Total says %s / %s.',
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
      problems := problems || format('Load %s ingredients: lines add to %s target / %s fed but PB Total says %s / %s.',
                                     load_no, sum_t, sum_f, itot[1], itot[2]);
    END IF;

    loads := loads || jsonb_build_object(
      'load_no', load_no, 'ration', ration,
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
    hmsec := substring(t FROM '(?i)Head Movements? on \d{2}-\d{2}-\d{4} (.*?) Bunk Scores on');
    hmsec := regexp_replace(COALESCE(hmsec, ''), '^Date Group Name Action Source Destination Head Count ', '');
    notes := notes || ('PB head movements (not imported - record them in the app): ' || COALESCE(NULLIF(btrim(hmsec), ''), 'see email'))::text;
  END IF;

  p := strpos(t, 'Pen Bunk Score ');
  IF p > 0 THEN
    bunksec := substr(t, p + length('Pen Bunk Score '));
    FOREACH marker IN ARRAY ARRAY['Prepared by', 'If you would like'] LOOP
      v_end := strpos(bunksec, marker);
      IF v_end > 0 THEN bunksec := left(bunksec, v_end - 1); END IF;
    END LOOP;
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
DECLARE v uuid; n text := pb_norm(p_name); c integer;
BEGIN
  SELECT pasture_id INTO v FROM pb_name_aliases WHERE kind='pen' AND pb_norm(pb_name) = n LIMIT 1;
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT count(*), min(p.id::text)::uuid INTO c, v FROM pastures p JOIN ranches r ON r.id=p.ranch_id
   WHERE p.is_active AND pb_norm(r.name || p.name) = n;
  IF c = 1 THEN RETURN v; END IF;
  SELECT count(*), min(id::text)::uuid INTO c, v FROM pastures WHERE is_active AND pb_norm(name) = n;
  IF c = 1 THEN RETURN v; END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION public.pb_resolve_item(p_name text) RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp' AS $$
DECLARE v uuid; n text := pb_norm(p_name);
BEGIN
  SELECT item_id INTO v FROM pb_name_aliases WHERE kind='item' AND pb_norm(pb_name) = n LIMIT 1;
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT id INTO v FROM feed_items WHERE pb_norm(pb_name) = n OR pb_norm(name) = n
   ORDER BY is_active DESC, (pb_norm(pb_name) = n) DESC NULLS LAST LIMIT 1;
  RETURN v;
END $$;