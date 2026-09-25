-- PB feed approvals: split one PB pen's drop across several pastures by weight.
--
-- APPLIED 2026-09-25 on John's approval, via apply_migration (begin/commit stripped).
-- Verified: md5(prosrc) of pb_split_drop, pb_report_summary and stage_pb_report
-- on the live database equals a scratch PostgreSQL build of this file.
--
-- Why: the feed cart can drop one PB pen's ration in more than one pasture.
-- pb_move_drop moves a pen's whole drop to ONE pasture; this lets the office
-- type the pounds that went to each pasture instead. approve_pb_report is
-- untouched: it already walks drop lines per load and splits each line's fed
-- pounds over the head standing in that line's pasture, so a split pen is
-- simply more drop lines.
--
-- Rules:
--   * The typed pounds must add EXACTLY to what PB says the pen was fed.
--     Nothing is absorbed: a gap is a feeding PB recorded wrong, and the
--     place to fix that is PB, not a quiet re-weighting here.
--   * A pen fed on several loads is split load by load in proportion to each
--     load's pounds (largest-remainder), with the last pasture taking the
--     remainder per load, so every pasture's total is exactly what was typed
--     AND every load still adds to PB's load TOTAL. If rounding would push a
--     remainder negative the function refuses rather than invent pounds.
--   * Re-splitting replaces the previous split. Undo = Move to one pasture
--     (pb_move_drop still works on split lines) or split with one part.
--   * The original PB figures survive in pb_daily_reports.parsed / raw_text.
--   * stage_pb_report now leaves a pending report alone when it is handed the
--     SAME gmail message again. The Cowork morning read re-seeing yesterday's
--     email would otherwise wipe every Move and Split.

begin;

ALTER TABLE public.pb_report_lines ADD COLUMN IF NOT EXISTS split_by uuid;
ALTER TABLE public.pb_report_lines ADD COLUMN IF NOT EXISTS split_at timestamptz;
COMMENT ON COLUMN public.pb_report_lines.split_at IS
 'Set when the office split this pen''s drop across pastures by weight (pb_split_drop). The line''s fed_lb is then the office''s share, not PB''s figure; PB''s is in pb_daily_reports.parsed.';

CREATE OR REPLACE FUNCTION public.pb_split_drop(p_report_date date, p_pb_pen text, p_parts jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $$
DECLARE
  v_rep    pb_daily_reports%ROWTYPE;
  v_pids   uuid[] := '{}';
  v_lbs    numeric[] := '{}';
  v_pid    uuid;
  v_lb     numeric;
  x        jsonb;
  ld       record;
  v_total  numeric;
  v_given  numeric[];
  v_share  numeric[];
  v_tshare numeric[];
  v_left   numeric;
  v_nload  integer;
  v_li     integer := 0;
  v_new    jsonb := '[]';
  k        integer;
  n        integer;
BEGIN
  SELECT * INTO v_rep FROM pb_daily_reports WHERE report_date = p_report_date FOR UPDATE;
  IF NOT FOUND OR v_rep.status <> 'pending' THEN
    RAISE EXCEPTION 'pb_split_drop: no pending PB report for %.', p_report_date;
  END IF;
  IF jsonb_typeof(p_parts) IS DISTINCT FROM 'array' OR jsonb_array_length(p_parts) = 0 THEN
    RAISE EXCEPTION 'pb_split_drop: give at least one pasture and its pounds.';
  END IF;

  FOR x IN SELECT * FROM jsonb_array_elements(p_parts) LOOP
    SELECT p.id INTO v_pid FROM pastures p JOIN ranches r ON r.id = p.ranch_id
     WHERE lower(r.name) = lower(btrim(x->>'ranch')) AND lower(p.name) = lower(btrim(x->>'pasture')) AND p.is_active;
    IF v_pid IS NULL THEN
      RAISE EXCEPTION 'pb_split_drop: no active pasture "%" on ranch "%".', x->>'pasture', x->>'ranch';
    END IF;
    IF v_pid = ANY (v_pids) THEN
      RAISE EXCEPTION 'pb_split_drop: % / % is listed twice - put its pounds on one line.', x->>'ranch', x->>'pasture';
    END IF;
    v_lb := pb_num(x->>'lb');
    IF v_lb IS NULL OR v_lb <= 0 THEN
      RAISE EXCEPTION 'pb_split_drop: pounds for % / % must be a number above zero (got "%").', x->>'ranch', x->>'pasture', x->>'lb';
    END IF;
    v_pids := v_pids || v_pid;
    v_lbs  := v_lbs || v_lb;
  END LOOP;
  n := cardinality(v_pids);

  SELECT SUM(fed_lb), count(DISTINCT load_no) INTO v_total, v_nload FROM pb_report_lines
   WHERE report_id = v_rep.id AND line_kind = 'drop' AND lower(pb_name) = lower(btrim(p_pb_pen));
  IF v_nload = 0 THEN RAISE EXCEPTION 'pb_split_drop: no drop to "%" on %.', p_pb_pen, p_report_date; END IF;
  IF COALESCE(v_total, 0) <= 0 THEN
    RAISE EXCEPTION 'pb_split_drop: PB shows nothing fed to "%" on % - nothing to split. Use Move to change the pasture.', p_pb_pen, p_report_date;
  END IF;
  SELECT SUM(u) INTO v_lb FROM unnest(v_lbs) u;
  IF v_lb <> v_total THEN
    RAISE EXCEPTION 'pb_split_drop: the pounds add to % but PB fed % lb to "%" - they must match exactly (% lb %).',
      v_lb, v_total, p_pb_pen, abs(v_total - v_lb), CASE WHEN v_lb > v_total THEN 'over' ELSE 'short' END;
  END IF;

  -- given[k] = pounds already handed to pasture k on earlier loads.
  v_given := array_fill(0::numeric, ARRAY[n]);

  FOR ld IN SELECT load_no, ration_name, MIN(drop_no) drop_no, SUM(target_lb) t, SUM(fed_lb) f
              FROM pb_report_lines
             WHERE report_id = v_rep.id AND line_kind = 'drop' AND lower(pb_name) = lower(btrim(p_pb_pen))
             GROUP BY load_no, ration_name ORDER BY load_no LOOP
    v_li := v_li + 1;
    IF v_li < v_nload THEN
      -- this load's pounds in the proportions typed
      v_share := lr_split(COALESCE(ld.f, 0), v_lbs, 2);
    ELSE
      -- last load: whatever each pasture is still owed, so the totals are exact
      v_share := '{}';
      FOR k IN 1..n LOOP v_share := v_share || (v_lbs[k] - v_given[k]); END LOOP;
      v_left := COALESCE(ld.f, 0);
      FOR k IN 1..n LOOP v_left := v_left - v_share[k]; END LOOP;
      IF v_left <> 0 OR EXISTS (SELECT 1 FROM unnest(v_share) s WHERE s < 0) THEN
        RAISE EXCEPTION 'pb_split_drop: "%" is fed on % loads and these pounds cannot be split across them without a negative share. Split it with rounder numbers.', p_pb_pen, v_nload;
      END IF;
    END IF;
    v_tshare := lr_split(COALESCE(ld.t, 0), v_lbs, 2);
    FOR k IN 1..n LOOP
      v_given[k] := v_given[k] + v_share[k];
      CONTINUE WHEN v_share[k] = 0 AND v_tshare[k] = 0;
      v_new := v_new || jsonb_build_object('load_no', ld.load_no, 'ration_name', ld.ration_name, 'drop_no', ld.drop_no,
                                           'pasture', v_pids[k], 'target_lb', v_tshare[k], 'fed_lb', v_share[k]);
    END LOOP;
  END LOOP;

  DELETE FROM pb_report_lines
   WHERE report_id = v_rep.id AND line_kind = 'drop' AND lower(pb_name) = lower(btrim(p_pb_pen));
  INSERT INTO pb_report_lines (report_id, line_kind, load_no, ration_name, drop_no, pb_name,
                               target_lb, fed_lb, pasture_override, split_by, split_at)
  SELECT v_rep.id, 'drop', s.load_no, s.ration_name, s.drop_no, btrim(p_pb_pen),
         round(s.target_lb, 2), round(s.fed_lb, 2), s.pasture, auth.uid(), now()
    FROM jsonb_to_recordset(v_new) AS s(load_no integer, ration_name text, drop_no integer,
                                        pasture uuid, target_lb numeric, fed_lb numeric);

  PERFORM pb_refresh_report(v_rep.id);
  RETURN pb_report_summary(p_report_date);
END $$;
COMMENT ON FUNCTION public.pb_split_drop(date, text, jsonb) IS
 'Approvals > Feed. Split one PB pen''s drop across pastures by weight for that day only. p_parts = [{ranch, pasture, lb}], lb must add exactly to PB''s fed lb for the pen.';

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
                                                             'moved', moved, 'split', split) ORDER BY pb_name, pname), '[]')
                 FROM (SELECT l.pb_name, rn.name || ' ' || p.name pname, rn.name rname, p.name paname,
                              SUM(l.target_lb) t, SUM(l.fed_lb) f,
                              bool_or(l.pasture_override IS NOT NULL) moved, bool_or(l.split_at IS NOT NULL) split
                         FROM pb_report_lines l LEFT JOIN pastures p ON p.id = l.pasture_id LEFT JOIN ranches rn ON rn.id = p.ranch_id
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
  -- The Cowork morning read may see the same email twice. Re-staging it
  -- would delete the lines and with them every Move and Split the office
  -- made. Same message = nothing to do. A DIFFERENT message for the same
  -- day (PB resent a corrected report) still replaces a pending one.
  IF FOUND AND v_rep.gmail_message_id = p_message_id THEN
    RETURN pb_report_summary(v_date) || jsonb_build_object('staging', 'same email already staged - left alone');
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

-- Verify
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'pb_split_drop' AND pronamespace = 'public'::regnamespace) THEN
    RAISE EXCEPTION 'verify: pb_split_drop missing';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'pb_split_drop' AND pronamespace = 'public'::regnamespace) <> 1 THEN
    RAISE EXCEPTION 'verify: more than one pb_split_drop - PostgREST cannot resolve an overload';
  END IF;
  IF (SELECT prosecdef FROM pg_proc WHERE proname = 'pb_split_drop' AND pronamespace = 'public'::regnamespace) THEN
    RAISE EXCEPTION 'verify: pb_split_drop must be SECURITY INVOKER';
  END IF;
END $$;

REVOKE ALL ON FUNCTION public.pb_split_drop(date, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_split_drop(date, text, jsonb) TO authenticated;

commit;
