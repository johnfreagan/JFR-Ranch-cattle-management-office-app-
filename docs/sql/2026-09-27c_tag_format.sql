-- =====================================================================
-- Tag format: one rule, one lookup helper (2026-09-27)
-- =====================================================================
-- lot_tags.tag_number is INTEGER. Four other tables carry the tag as TEXT:
-- doctoring_events, lot_events, pending_field_entries, feed_pen_removals.
-- The TEXT columns stay TEXT (John): an untagged animal is numbered NT1,
-- NT2 ... per lot, and that identifier has to live in the same column.
--
-- The rule, now a CHECK on all four columns:
--     NULL, or plain digits with no leading zero, or NT<n>
--     '^([1-9][0-9]*|NT[0-9]+)$'
-- Refused: 'NT?', 'nt3', ' 123', '0123', '', 'NT'.
-- doctoring_events.tag_number stays NOT NULL (an untagged pull is NT<n>).
--
-- public.tag_to_int(text) is the ONE way a text tag is matched to
-- lot_tags.tag_number. It returns the integer for a digit tag and NULL for
-- anything else, so an NT tag never matches a registered tag -- correct,
-- because NT animals are the untagged ones. The office and field apps carry
-- the same function as tagToInt() in JS.
--
-- Sites moved onto the helper (each was casting its own way before --
-- lt.tag_number::text = x, btrim(x)::int behind a '\s*\d{1,9}\s*' regex):
--   get_doctoring_analytics         tag -> receipt arrival / protocol
--   get_lot_deaths_with_arrival     death tag -> receipt arrival / protocol
--   health_pull_rows                pulls onto the health curves
--   health_death_days (view)        death tag -> head's arrival
--   health_anomalies  (view)        'pull_no_tag' classification
--   lot_tags_retire_on_death        tag retirement trigger (2026-09-27b)
-- Functions and views are rewritten IN PLACE from their live definition
-- (exact substring replacement, count asserted), so nothing else in them
-- is retyped. Re-running finds the new text and skips.
--
-- Data: the one 'NT?' row (37X, 2026-01-05, doctoring 053c71c3...) gets the
-- next free NT<n> on 37X, with the original text kept in notes. Its date is
-- a known placeholder and is deliberately left for John. The two TEST_DOC1
-- rows (NT1, NT2) already pass. No column holds '' (checked 2026-09-27);
-- the guarded conversion below is kept so the file is safe to re-run.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. The helper
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tag_to_int(p_tag text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $fn$
    SELECT CASE WHEN btrim(p_tag) ~ '^[1-9][0-9]{0,8}$'
                THEN btrim(p_tag)::integer END
$fn$;

COMMENT ON FUNCTION public.tag_to_int(text) IS
    'The one way a TEXT tag is matched to lot_tags.tag_number: the integer for a digit tag, NULL for NT<n> or anything else. Mirrored by tagToInt() in index.html and field-app/app.js.';

REVOKE ALL ON FUNCTION public.tag_to_int(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tag_to_int(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. Blank tags -> NULL where the column allows it
-- ---------------------------------------------------------------------
DO $blank$
DECLARE
    n integer;
BEGIN
    IF EXISTS (SELECT 1 FROM public.doctoring_events WHERE btrim(tag_number) = '') THEN
        RAISE EXCEPTION 'doctoring_events holds blank tags and tag_number is NOT NULL - stop and decide';
    END IF;
    UPDATE public.lot_events SET tag_number = NULL WHERE btrim(tag_number) = '';
    GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'lot_events blank -> null: %', n;
    UPDATE public.pending_field_entries SET tag_number = NULL WHERE btrim(tag_number) = '';
    GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'pending_field_entries blank -> null: %', n;
    UPDATE public.feed_pen_removals SET tag_number = NULL WHERE btrim(tag_number) = '';
    GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'feed_pen_removals blank -> null: %', n;
END;
$blank$;

-- ---------------------------------------------------------------------
-- 3. The one 'NT?' row -> next free NT<n> on its lot
-- ---------------------------------------------------------------------
DO $nt$
DECLARE
    v_lot  uuid;
    v_next text;
    n      integer;
BEGIN
    SELECT lot_id INTO v_lot FROM public.doctoring_events
     WHERE id = '053c71c3-bfb5-48e8-acb3-5591750f7616' AND tag_number = 'NT?';
    IF v_lot IS NULL THEN
        RAISE NOTICE 'NT? row already fixed - skipped';
    ELSE
        SELECT 'NT' || (COALESCE(max(substring(tag_number FROM 3)::integer), 0) + 1)
          INTO v_next
          FROM public.doctoring_events
         WHERE lot_id = v_lot AND tag_number ~ '^NT[0-9]+$';

        UPDATE public.doctoring_events
           SET tag_number = v_next,
               no_tag = true,
               notes = concat_ws(E'\n', NULLIF(notes, ''),
                   'Original tag text: NT?',
                   '[2026-09-27 tag format] tag NT? -> ' || v_next
                   || ': next free NT number on the lot; NT? is no longer a valid tag. Date left for John to correct.')
         WHERE id = '053c71c3-bfb5-48e8-acb3-5591750f7616' AND tag_number = 'NT?';
        GET DIAGNOSTICS n = ROW_COUNT;
        IF n <> 1 THEN
            RAISE EXCEPTION 'NT? fix: expected 1 row, got %', n;
        END IF;
        RAISE NOTICE 'NT? -> %', v_next;
    END IF;
END;
$nt$;

-- ---------------------------------------------------------------------
-- 4. The CHECKs
-- ---------------------------------------------------------------------
DO $chk$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['doctoring_events','lot_events','pending_field_entries','feed_pen_removals'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conrelid = ('public.' || t)::regclass
                          AND conname = t || '_tag_number_format_check') THEN
            EXECUTE format(
                'ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (tag_number IS NULL OR tag_number ~ %L)',
                t, t || '_tag_number_format_check', '^([1-9][0-9]*|NT[0-9]+)$');
        END IF;
    END LOOP;
END;
$chk$;

-- ---------------------------------------------------------------------
-- 5. Rewrite the lookup sites onto tag_to_int(), in place
-- ---------------------------------------------------------------------
DO $rw$
DECLARE
    edits  text[][] := ARRAY[
      -- kind, object, old text, new text
      ARRAY['fn',   'get_doctoring_analytics',     'lt.tag_number::text as tag_number',  'lt.tag_number as tag_number'],
      ARRAY['fn',   'get_doctoring_analytics',     'ta.tag_number = a.tag_number',       'ta.tag_number = public.tag_to_int(a.tag_number)'],
      ARRAY['fn',   'get_lot_deaths_with_arrival', 'lt.tag_number::text as tag_number',  'lt.tag_number as tag_number'],
      ARRAY['fn',   'get_lot_deaths_with_arrival', 'ta.tag_number = le.tag_number',      'ta.tag_number = public.tag_to_int(le.tag_number)'],
      ARRAY['fn',   'health_pull_rows',            'btrim(de.tag_number)::int as tag_number', 'public.tag_to_int(de.tag_number) as tag_number'],
      ARRAY['fn',   'health_pull_rows',            'where de.tag_number ~ ''^\s*\d{1,9}\s*$''', 'where public.tag_to_int(de.tag_number) is not null'],
      -- pg_get_viewdef prints this CASE over four lines; matched verbatim.
      ARRAY['view', 'health_death_days',           'CASE
            WHEN (e.tag_number ~ ''^\s*\d{1,9}\s*$''::text) THEN (btrim(e.tag_number))::integer
            ELSE NULL::integer
        END', 'public.tag_to_int(e.tag_number)'],
      ARRAY['view', 'health_anomalies',            '(d.tag_number !~ ''^\s*\d{1,9}\s*$''::text)', '(public.tag_to_int(d.tag_number) IS NULL)']
    ];
    objs   text[] := ARRAY['fn:get_doctoring_analytics','fn:get_lot_deaths_with_arrival',
                               'fn:health_pull_rows','view:health_death_days','view:health_anomalies'];
    ob     text;
    i      integer;
    v_oid  oid;
    def    text;
    k      text; obj text; o text; nw text;
    cnt    integer;
    changed boolean;
BEGIN
    -- All edits to one object are applied to its definition together and
    -- executed ONCE: an object with two edits does not compile half-done.
    FOREACH ob IN ARRAY objs LOOP
        k := split_part(ob, ':', 1); obj := split_part(ob, ':', 2);
        IF k = 'fn' THEN
            SELECT p.oid INTO STRICT v_oid FROM pg_proc p
              JOIN pg_namespace ns ON ns.oid = p.pronamespace
             WHERE ns.nspname = 'public' AND p.proname = obj;
            def := pg_get_functiondef(v_oid);
        ELSE
            v_oid := ('public.' || obj)::regclass;
            def := pg_get_viewdef(v_oid);
        END IF;
        changed := false;

        FOR i IN 1 .. array_length(edits, 1) LOOP
            CONTINUE WHEN edits[i][1] <> k OR edits[i][2] <> obj;
            o := edits[i][3]; nw := edits[i][4];
            cnt := (length(def) - length(replace(def, o, ''))) / length(o);
            IF cnt = 0 AND position(nw IN def) > 0 THEN
                RAISE NOTICE '%: edit already applied - skipped', obj;
                CONTINUE;
            END IF;
            IF cnt <> 1 THEN
                RAISE EXCEPTION '% %: expected the text exactly once, found % times: %', k, obj, cnt, o;
            END IF;
            def := replace(def, o, nw);
            changed := true;
        END LOOP;

        CONTINUE WHEN NOT changed;
        IF k = 'fn' THEN
            EXECUTE def;
        ELSE
            EXECUTE format('CREATE OR REPLACE VIEW public.%I WITH (security_invoker = true) AS %s', obj, def);
            IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v_oid
                            AND reloptions @> ARRAY['security_invoker=true']) THEN
                RAISE EXCEPTION 'view % lost security_invoker', obj;
            END IF;
        END IF;
    END LOOP;
END;
$rw$;

-- The retirement trigger from 2026-09-27b, on the helper.
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
    IF TG_OP IN ('UPDATE','DELETE') AND OLD.event_type = 'death' THEN
        old_tag := public.tag_to_int(OLD.tag_number);
    END IF;
    IF TG_OP IN ('INSERT','UPDATE') AND NEW.event_type = 'death' THEN
        new_tag := public.tag_to_int(NEW.tag_number);
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
                    AND public.tag_to_int(e.tag_number) = old_tag);
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

-- ---------------------------------------------------------------------
-- 6. Verify
-- ---------------------------------------------------------------------
DO $v$
BEGIN
    IF (SELECT count(*) FROM pg_constraint
         WHERE conname IN ('doctoring_events_tag_number_format_check',
                           'lot_events_tag_number_format_check',
                           'pending_field_entries_tag_number_format_check',
                           'feed_pen_removals_tag_number_format_check')) <> 4 THEN
        RAISE EXCEPTION 'tag format CHECKs missing';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
                WHERE ns.nspname = 'public'
                  AND p.proname IN ('get_doctoring_analytics','get_lot_deaths_with_arrival',
                                    'health_pull_rows','lot_tags_retire_on_death')
                  AND p.prosrc NOT LIKE '%tag_to_int(%') THEN
        RAISE EXCEPTION 'a lookup function is not on tag_to_int()';
    END IF;
    IF pg_get_viewdef('public.health_death_days'::regclass) NOT LIKE '%tag_to_int(%'
       OR pg_get_viewdef('public.health_anomalies'::regclass) NOT LIKE '%tag_to_int(%' THEN
        RAISE EXCEPTION 'a lookup view is not on tag_to_int()';
    END IF;
    IF has_function_privilege('anon', 'public.tag_to_int(text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'anon can execute tag_to_int';
    END IF;
END;
$v$;

commit;
