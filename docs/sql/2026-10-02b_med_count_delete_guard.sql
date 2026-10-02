-- =====================================================================
-- A draft count can be deleted. A posted one cannot.
-- =====================================================================
-- 2026-10-02. OPEN-ITEMS 0h, found while clearing up after the
-- processing-gate test, and brought forward because I had told John to
-- delete a leftover draft from a screen that had no delete button.
--
-- THE HOLE. med_count_lines.count_id is ON DELETE CASCADE and
-- med_purchase_lines.count_id is ON DELETE SET NULL. So deleting a
-- POSTED count threw away the count detail and left its opening layers
-- standing with nothing pointing at where they came from. No money
-- moved - the layers keep their value - but the trail from a bottle on
-- the shelf back to the count that put it there was gone, silently.
-- med_unpost_count() exists precisely so nobody has to delete one.
--
-- Also: med_purchase_lines.count_id had no index, so the SET NULL scan
-- went wide on a table that only grows.
--
-- The app now offers Delete on a draft row only. This trigger is the
-- part that does not depend on which screen somebody is on.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.med_guard_count_delete()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $fn$
BEGIN
    IF OLD.status = 'posted' THEN
        RAISE EXCEPTION 'That count is posted. Deleting it would throw away its lines and leave the layers it created with nothing pointing at where they came from. Un-post it first.'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN OLD;
END $fn$;

CREATE TRIGGER med_counts_delete_guard BEFORE DELETE ON public.med_counts
FOR EACH ROW EXECUTE FUNCTION public.med_guard_count_delete();

CREATE INDEX IF NOT EXISTS med_purchase_lines_count_idx ON public.med_purchase_lines (count_id);

REVOKE ALL ON FUNCTION public.med_guard_count_delete() FROM authenticated;

DO $verify$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM pg_trigger WHERE tgname='med_counts_delete_guard';
    IF n <> 1 THEN RAISE EXCEPTION 'the delete guard is missing'; END IF;
    SELECT count(*) INTO n FROM pg_indexes WHERE indexname='med_purchase_lines_count_idx';
    IF n <> 1 THEN RAISE EXCEPTION 'the count_id index is missing'; END IF;
    RAISE NOTICE 'VERIFIED: posted counts cannot be deleted, count_id is indexed.';
END
$verify$;
