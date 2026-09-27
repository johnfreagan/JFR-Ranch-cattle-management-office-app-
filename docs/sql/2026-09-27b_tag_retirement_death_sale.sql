-- =====================================================================
-- Tag retirement on death and sale (2026-09-27)
-- =====================================================================
-- John's rule: retire a tag when the animal dies or sells, if the tag is
-- known. Done with triggers rather than in the app so every entry path is
-- covered: the office app, field-app approvals, the RPCs and raw SQL.
--
--   lot_events (death, numeric tag_number)  -> that lot's lot_tags row
--       status 'retired', retired_at now(), retired_reason 'Died <date>'
--   sales (tag_start AND tag_end set)       -> every tag in the range for
--       that lot except missing_tags, retired_reason 'Sold <date>'
--
-- Only rows with status = 'active' are ever retired, so a tag already
-- retired or voided for another reason is never overwritten.
--
-- UNDO. Deleting the event or sale, or changing the fields that decided
-- which tags it retired, puts those tags back to 'active' -- but ONLY a
-- tag whose retired_reason starts with 'Died' (deaths) or 'Sold' (sales),
-- so a tag retired by lot close or by hand is left alone. A tag that
-- another death or sale in the same lot still accounts for is also left
-- retired: two rows naming one tag should not be undone by removing one.
-- An update that moves the tag, lot, range or date undoes the old retire
-- and applies the new one, so the reason carries the current date.
--
-- SECURITY INVOKER. Only owner and office may write lot_events and sales,
-- and those are exactly the roles lot_tags_update allows, so the trigger
-- never needs to see past RLS. search_path is pinned anyway and EXECUTE is
-- revoked from PUBLIC (rule 4: revoking from anon alone does nothing).
--
-- A tag_number that is not a plain number (1-9 digits) is ignored: the
-- column is TEXT on lot_events and INTEGER on lot_tags.
--
-- Backfill at the foot: retires the 27 active tags that match a recorded
-- death in the same lot, and raises (rolling everything back) if the count
-- is anything else. No sale carries a tag range, so sales are not
-- backfilled. Two deaths on 37X carry a tag with no lot_tags row
-- (2025-12-18 tag 4331, 2026-01-05 tag 4379); reported, not fixed.
--
-- Idempotent: CREATE OR REPLACE and DROP TRIGGER IF EXISTS; the backfill
-- is skipped when a prior run already retired 'Died' rows via this file
-- (it looks for the marker in lot_tags.notes).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Deaths
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lot_tags_retire_on_death()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    old_tag integer;
    new_tag integer;
BEGIN
    IF TG_OP IN ('UPDATE','DELETE') AND OLD.event_type = 'death'
       AND OLD.tag_number ~ '^\s*\d{1,9}\s*$' THEN
        old_tag := btrim(OLD.tag_number)::integer;
    END IF;
    IF TG_OP IN ('INSERT','UPDATE') AND NEW.event_type = 'death'
       AND NEW.tag_number ~ '^\s*\d{1,9}\s*$' THEN
        new_tag := btrim(NEW.tag_number)::integer;
    END IF;

    -- An update that changes nothing this trigger cares about is a no-op.
    IF TG_OP = 'UPDATE'
       AND old_tag IS NOT DISTINCT FROM new_tag
       AND OLD.lot_id = NEW.lot_id
       AND OLD.event_date = NEW.event_date THEN
        RETURN NULL;
    END IF;

    -- Undo the old retire.
    IF old_tag IS NOT NULL THEN
        UPDATE public.lot_tags t
           SET status = 'active', retired_at = NULL, retired_reason = NULL
         WHERE t.lot_id = OLD.lot_id
           AND t.tag_number = old_tag
           AND t.status = 'retired'
           AND t.retired_reason LIKE 'Died%'
           AND NOT EXISTS (
                 SELECT 1 FROM public.lot_events e
                  WHERE e.id <> OLD.id
                    AND e.lot_id = OLD.lot_id
                    AND e.event_type = 'death'
                    AND e.tag_number ~ '^\s*\d{1,9}\s*$'
                    AND btrim(e.tag_number)::integer = old_tag);
    END IF;

    -- Apply the new one.
    IF new_tag IS NOT NULL THEN
        UPDATE public.lot_tags t
           SET status = 'retired', retired_at = now(),
               retired_reason = 'Died ' || NEW.event_date::text
         WHERE t.lot_id = NEW.lot_id
           AND t.tag_number = new_tag
           AND t.status = 'active';
    END IF;

    RETURN NULL;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lot_tags_retire_on_death() FROM PUBLIC, anon;

DROP TRIGGER IF EXISTS lot_tags_retire_on_death ON public.lot_events;
CREATE TRIGGER lot_tags_retire_on_death
    AFTER INSERT OR UPDATE OR DELETE ON public.lot_events
    FOR EACH ROW EXECUTE FUNCTION public.lot_tags_retire_on_death();

-- ---------------------------------------------------------------------
-- Sales
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lot_tags_retire_on_sale()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
    old_has boolean := false;
    new_has boolean := false;
BEGIN
    IF TG_OP IN ('UPDATE','DELETE') THEN
        old_has := OLD.tag_start IS NOT NULL AND OLD.tag_end IS NOT NULL;
    END IF;
    IF TG_OP IN ('INSERT','UPDATE') THEN
        new_has := NEW.tag_start IS NOT NULL AND NEW.tag_end IS NOT NULL;
    END IF;

    IF TG_OP = 'UPDATE'
       AND OLD.lot_id = NEW.lot_id
       AND OLD.sale_date = NEW.sale_date
       AND OLD.tag_start IS NOT DISTINCT FROM NEW.tag_start
       AND OLD.tag_end IS NOT DISTINCT FROM NEW.tag_end
       AND OLD.missing_tags IS NOT DISTINCT FROM NEW.missing_tags THEN
        RETURN NULL;
    END IF;

    -- Undo the old retire.
    IF old_has THEN
        UPDATE public.lot_tags t
           SET status = 'active', retired_at = NULL, retired_reason = NULL
         WHERE t.lot_id = OLD.lot_id
           AND t.tag_number BETWEEN OLD.tag_start AND OLD.tag_end
           AND NOT (t.tag_number = ANY (COALESCE(OLD.missing_tags, '{}')))
           AND t.status = 'retired'
           AND t.retired_reason LIKE 'Sold%'
           AND NOT EXISTS (
                 SELECT 1 FROM public.sales s
                  WHERE s.id <> OLD.id
                    AND s.lot_id = OLD.lot_id
                    AND s.tag_start IS NOT NULL AND s.tag_end IS NOT NULL
                    AND t.tag_number BETWEEN s.tag_start AND s.tag_end
                    AND NOT (t.tag_number = ANY (COALESCE(s.missing_tags, '{}'))));
    END IF;

    -- Apply the new one.
    IF new_has THEN
        UPDATE public.lot_tags t
           SET status = 'retired', retired_at = now(),
               retired_reason = 'Sold ' || NEW.sale_date::text
         WHERE t.lot_id = NEW.lot_id
           AND t.tag_number BETWEEN NEW.tag_start AND NEW.tag_end
           AND NOT (t.tag_number = ANY (COALESCE(NEW.missing_tags, '{}')))
           AND t.status = 'active';
    END IF;

    RETURN NULL;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lot_tags_retire_on_sale() FROM PUBLIC, anon;

DROP TRIGGER IF EXISTS lot_tags_retire_on_sale ON public.sales;
CREATE TRIGGER lot_tags_retire_on_sale
    AFTER INSERT OR UPDATE OR DELETE ON public.sales
    FOR EACH ROW EXECUTE FUNCTION public.lot_tags_retire_on_sale();

-- ---------------------------------------------------------------------
-- Backfill: active tags matching a recorded death in the same lot.
-- Expected exactly 27 (counted 2026-09-27). Anything else raises.
-- ---------------------------------------------------------------------
DO $bf$
DECLARE
    n integer;
BEGIN
    IF EXISTS (SELECT 1 FROM public.lot_tags
                WHERE notes LIKE '%[tag retirement backfill 2026-09-27]%') THEN
        RAISE NOTICE 'tag retirement backfill already applied - skipped';
        RETURN;
    END IF;

    UPDATE public.lot_tags t
       SET status = 'retired', retired_at = now(),
           retired_reason = 'Died ' || e.event_date::text,
           notes = concat_ws(E'\n', NULLIF(t.notes, ''),
               '[tag retirement backfill 2026-09-27] retired: matches death event '
               || e.id::text || ' dated ' || e.event_date::text)
      FROM public.lot_events e
     WHERE e.event_type = 'death'
       AND e.tag_number ~ '^\s*\d{1,9}\s*$'
       AND e.lot_id = t.lot_id
       AND btrim(e.tag_number)::integer = t.tag_number
       AND t.status = 'active';
    GET DIAGNOSTICS n = ROW_COUNT;

    IF n <> 27 THEN
        RAISE EXCEPTION 'tag retirement backfill: expected 27 rows, got %. Rolled back.', n;
    END IF;
    RAISE NOTICE 'tag retirement backfill: retired % tags', n;
END;
$bf$;

commit;
