-- Revoke the default PUBLIC/anon EXECUTE on the PB email import functions.
--
-- Applied 2026-09-25 on John's approval via apply_migration (begin/commit
-- stripped); live afterwards: 13 PB functions, anon 0, authenticated 13.
-- docs/sql/2026-09-25_pb_email_import.sql
-- and ..._pb_report_list.sql created these functions without a REVOKE, so they
-- carried Postgres' default EXECUTE to PUBLIC, which reaches anon: CLAUDE.md
-- access-control rule 4. Every one is SECURITY INVOKER and the three PB tables'
-- policies are TO authenticated, so anon could read and write nothing through
-- them; this closes the grant itself. pb_split_drop (2026-09-25b) was already
-- revoked.
--
-- If the Cowork morning read ever calls stage_pb_report with the PUBLISHABLE
-- key and no signed-in user, this is what will refuse it. It must run as a
-- signed-in owner/office user or through the Supabase connector.

begin;

REVOKE ALL ON FUNCTION
  public.pb_num(text),
  public.pb_parse_delivery_email(text),
  public.pb_resolve_pen(text),
  public.pb_resolve_item(text),
  public.pb_refresh_report(uuid),
  public.pb_report_summary(date),
  public.stage_pb_report(text, text),
  public.approve_pb_report(date, text),
  public.pb_move_drop(date, text, text, text),
  public.unpost_pb_report(date, text),
  public.reject_pb_report(date, text),
  public.pb_report_list(integer)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
  public.pb_num(text),
  public.pb_parse_delivery_email(text),
  public.pb_resolve_pen(text),
  public.pb_resolve_item(text),
  public.pb_refresh_report(uuid),
  public.pb_report_summary(date),
  public.stage_pb_report(text, text),
  public.approve_pb_report(date, text),
  public.pb_move_drop(date, text, text, text),
  public.unpost_pb_report(date, text),
  public.reject_pb_report(date, text),
  public.pb_report_list(integer)
TO authenticated;

-- Verify: no PB function is executable by anon, every one is by authenticated.
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO bad
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND (p.proname LIKE 'pb\_%' OR p.proname IN ('stage_pb_report','approve_pb_report','reject_pb_report','unpost_pb_report'))
     AND has_function_privilege('anon', p.oid, 'EXECUTE');
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'verify: anon can still execute %', bad; END IF;
  SELECT string_agg(p.proname, ', ') INTO bad
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND (p.proname LIKE 'pb\_%' OR p.proname IN ('stage_pb_report','approve_pb_report','reject_pb_report','unpost_pb_report'))
     AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE');
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'verify: authenticated lost execute on %', bad; END IF;
END $$;

commit;
