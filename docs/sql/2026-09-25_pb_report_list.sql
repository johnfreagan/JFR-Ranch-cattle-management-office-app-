-- One call for the Approvals > Feed tab: recent PB reports with their summaries, newest first.
CREATE OR REPLACE FUNCTION public.pb_report_list(p_days integer DEFAULT 30)
RETURNS jsonb LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $$
  SELECT COALESCE(jsonb_agg(pb_report_summary(r.report_date)
           || jsonb_build_object('staged_at', r.staged_at, 'reviewed_at', r.reviewed_at,
                                 'reviewed_by', (SELECT full_name FROM user_profiles WHERE id = r.reviewed_by),
                                 'review_notes', r.review_notes)
           ORDER BY (r.status = 'pending') DESC, r.report_date DESC), '[]'::jsonb)
    FROM pb_daily_reports r
   WHERE r.report_date >= ranch_today() - p_days OR r.status = 'pending'
$$;
COMMENT ON FUNCTION public.pb_report_list(integer) IS
 'Approvals > Feed tab. Pending reports first, then the last p_days of reviewed ones. Each element is pb_report_summary() plus review info.';