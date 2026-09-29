-- Approvals > Feed: show which pen is marked Prefeed, and keep the mark through a Split.
--
-- Approved by John 2026-09-29 ("Yes to your questions").
--
-- APPLIED live 2026-09-29 as migration pb_summary_prefeed_flag. md5(prosrc) after apply:
--   pb_report_summary 9d915061b15216204e0ce88e0f9cca2a, pb_split_drop b6af7f311c63c1d048b902ababbb4e33.
--
-- 1. pb_report_summary().by_pen gains 'prefeed' = bool_or(pb_report_lines.prefeed) for the
--    pen, beside 'moved' and 'split'. The Feed tab needs it to show the "Prefeed - first lot
--    in pays" chip and to label the button "Undo prefeed"; before this the summary carried
--    no per-pen prefeed state at all, so the screen could not tell which pen was marked.
-- 2. pb_split_drop() deletes a pen's drop lines and writes new ones. The new lines took the
--    column default prefeed = false, so splitting a pen marked Prefeed silently cleared the
--    mark. It now carries the pen's mark onto every line it writes. (pb_refresh_report still
--    refuses a Prefeed pen whose new pasture already has lots standing, so a split into an
--    occupied pasture shows as a problem rather than posting wrong.)
--
-- No data changes. Both functions keep their signatures (CREATE OR REPLACE).

begin;

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
                                                             'moved', moved, 'split', split, 'prefeed', prefeed) ORDER BY pb_name, pname), '[]')
                 FROM (SELECT l.pb_name, rn.name || ' ' || p.name pname, rn.name rname, p.name paname,
                              SUM(l.target_lb) t, SUM(l.fed_lb) f,
                              bool_or(l.pasture_override IS NOT NULL) moved, bool_or(l.split_at IS NOT NULL) split,
                              bool_or(l.prefeed) prefeed
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
  v_pre    boolean;
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

  SELECT SUM(fed_lb), count(DISTINCT load_no), COALESCE(bool_or(prefeed), false) INTO v_total, v_nload, v_pre FROM pb_report_lines
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
                               target_lb, fed_lb, pasture_override, split_by, split_at, prefeed)
  SELECT v_rep.id, 'drop', s.load_no, s.ration_name, s.drop_no, btrim(p_pb_pen),
         round(s.target_lb, 2), round(s.fed_lb, 2), s.pasture, auth.uid(), now(), v_pre
    FROM jsonb_to_recordset(v_new) AS s(load_no integer, ration_name text, drop_no integer,
                                        pasture uuid, target_lb numeric, fed_lb numeric);

  PERFORM pb_refresh_report(v_rep.id);
  RETURN pb_report_summary(p_report_date);
END $$;

-- Verify
DO $$
BEGIN
  IF position('''prefeed''' IN (SELECT prosrc FROM pg_proc WHERE proname = 'pb_report_summary' AND pronamespace = 'public'::regnamespace)) = 0 THEN
    RAISE EXCEPTION 'verify: pb_report_summary does not carry prefeed';
  END IF;
  IF position('v_pre' IN (SELECT prosrc FROM pg_proc WHERE proname = 'pb_split_drop' AND pronamespace = 'public'::regnamespace)) = 0 THEN
    RAISE EXCEPTION 'verify: pb_split_drop does not keep prefeed';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
              AND p.proname IN ('pb_report_summary','pb_split_drop') AND has_function_privilege('anon', p.oid, 'EXECUTE')) THEN
    RAISE EXCEPTION 'verify: anon can execute a PB function';
  END IF;
END $$;

commit;
