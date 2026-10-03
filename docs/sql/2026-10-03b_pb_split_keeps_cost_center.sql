-- Approvals > Feed: a Split keeps the pen's cost centre (follows 2026-10-03_pb_drop_cost_center.sql).
--
-- APPLIED 2026-10-03 by John in the Supabase dashboard SQL editor (the connector stalls on any request
-- containing DELETE, and this function has to delete the pen's old drop lines before writing the
-- split ones). Verified afterwards: md5(prosrc) of pb_split_drop = bba5d7b36af4269096f5edf3a757949e,
-- the copy tested locally; anon cannot execute it, authenticated can. It replaced
-- b6af7f311c63c1d048b902ababbb4e33 (the 2026-09-29d version), which cleared a pen's cost centre on a split.
--
-- The only change from 29d: v_cc carries max(cost_center_id) onto every line the split writes, as
-- v_pre already carries Prefeed.

begin;

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
  v_cc     uuid;
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

  SELECT SUM(fed_lb), count(DISTINCT load_no), COALESCE(bool_or(prefeed), false), max(cost_center_id::text)::uuid
    INTO v_total, v_nload, v_pre, v_cc FROM pb_report_lines
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
                               target_lb, fed_lb, pasture_override, split_by, split_at, prefeed, cost_center_id)
  SELECT v_rep.id, 'drop', s.load_no, s.ration_name, s.drop_no, btrim(p_pb_pen),
         round(s.target_lb, 2), round(s.fed_lb, 2), s.pasture, auth.uid(), now(), v_pre, v_cc
    FROM jsonb_to_recordset(v_new) AS s(load_no integer, ration_name text, drop_no integer,
                                        pasture uuid, target_lb numeric, fed_lb numeric);

  PERFORM pb_refresh_report(v_rep.id);
  RETURN pb_report_summary(p_report_date);
END $$;

DO $$
BEGIN
  IF position('v_cc' IN (SELECT prosrc FROM pg_proc WHERE proname = 'pb_split_drop' AND pronamespace = 'public'::regnamespace)) = 0 THEN
    RAISE EXCEPTION 'verify: pb_split_drop does not keep the cost centre';
  END IF;
END $$;

commit;
