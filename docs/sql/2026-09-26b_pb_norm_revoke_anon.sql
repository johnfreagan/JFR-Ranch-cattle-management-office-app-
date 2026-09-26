-- Revoke the default PUBLIC/anon EXECUTE on pb_norm() (CLAUDE.md access-control rule 4).
--
-- Applied 2026-09-26 on John's approval via apply_migration (begin/commit stripped).
-- 2026-09-26_pb_parse_2026_format.sql created pb_norm() without a REVOKE, so it
-- carried Postgres' default EXECUTE to PUBLIC, which reaches anon. It is a pure
-- text function (lower-case, strip everything but a-z0-9) and exposes no data,
-- but the rule is the rule, and the verify block below now covers every PB
-- function, so the next one added without a REVOKE is caught the same way.

begin;

REVOKE ALL ON FUNCTION public.pb_norm(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_norm(text) TO authenticated;

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
