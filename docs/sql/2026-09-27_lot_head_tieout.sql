-- D8: daily head-count tie-out for every open lot.
--
-- One row per open lot (closed_at IS NULL, is_test not true). Two checks:
--   head  : lot_status.head_current against the open lot_pasture_assignments.
--           This is the head-math invariant in CLAUDE.md; any gap is drift.
--           It decides `status` (TIES / OFF).
--   tags  : count(lot_tags), any status, against lot_status.head_in.
--           Informational only (`tag_flag`). A tag gap is a paperwork gap
--           (37X has tags on 72 of 369 head), not a head-math error, so it
--           never turns a lot OFF.
--
-- lot_id is carried beside the requested columns so the app can open the lot.
-- The feed pen is included: it is an open lot with head math like any other.
--
-- security_invoker so it reads through each base table's RLS (rule 3), and
-- read-only: SELECT to authenticated, nothing to anon or PUBLIC (rule 4).
--
-- Applied 2026-09-27 via apply_migration (begin/commit stripped).

begin;

CREATE OR REPLACE VIEW public.lot_head_tieout
WITH (security_invoker = true) AS
WITH base AS (
  SELECT l.id         AS lot_id,
         l.lot_number,
         COALESCE(ls.head_current, 0)::int AS books_head,
         COALESCE((SELECT sum(a.head_count)
                     FROM public.lot_pasture_assignments a
                    WHERE a.lot_id = l.id AND a.moved_out IS NULL), 0)::int AS pasture_head,
         (SELECT count(*) FROM public.lot_tags t WHERE t.lot_id = l.id)::int AS tags_registered,
         COALESCE(ls.head_in, 0)::int AS tags_expected
    FROM public.lots l
    LEFT JOIN public.lot_status ls ON ls.lot_id = l.id
   WHERE l.closed_at IS NULL
     AND l.is_test IS NOT TRUE
)
SELECT lot_id,
       lot_number,
       books_head,
       pasture_head,
       books_head - pasture_head                           AS head_gap,
       tags_registered,
       tags_expected,
       tags_registered - tags_expected                    AS tag_gap,
       CASE WHEN books_head = pasture_head THEN 'TIES' ELSE 'OFF' END AS status,
       (tags_registered <> tags_expected)                 AS tag_flag
  FROM base;

REVOKE ALL ON public.lot_head_tieout FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.lot_head_tieout TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_class
                  WHERE oid = 'public.lot_head_tieout'::regclass
                    AND reloptions @> ARRAY['security_invoker=true']) THEN
    RAISE EXCEPTION 'verify: lot_head_tieout lacks security_invoker';
  END IF;
  IF has_table_privilege('anon', 'public.lot_head_tieout', 'SELECT')
     OR has_table_privilege('anon', 'public.lot_head_tieout', 'INSERT') THEN
    RAISE EXCEPTION 'verify: anon holds a privilege on lot_head_tieout';
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.lot_head_tieout', 'SELECT') THEN
    RAISE EXCEPTION 'verify: authenticated cannot SELECT lot_head_tieout';
  END IF;
  IF has_table_privilege('authenticated', 'public.lot_head_tieout', 'INSERT')
     OR has_table_privilege('authenticated', 'public.lot_head_tieout', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.lot_head_tieout', 'DELETE') THEN
    RAISE EXCEPTION 'verify: authenticated can write lot_head_tieout';
  END IF;
END $$;

commit;
