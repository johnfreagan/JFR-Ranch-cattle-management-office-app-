-- 2026-10-08. Production refuses test lots (D44 reversed by John 2026-10-07; plan in
-- docs/test-lots-cleanup.md, step 5).
--
-- The three test lots were purged on 2026-10-07 (2026-10-07_purge_test_lots.sql). This trigger
-- keeps them from coming back: an INSERT or UPDATE on public.lots fails when is_test is true or
-- the lot number starts with "test" (any case). Testing belongs in a separate database, not in
-- the live books. The is_test column and the existing is_test filters stay; they are harmless
-- and come out over time.
--
-- SECURITY INVOKER: the trigger only reads NEW, it needs no rights of its own.
-- Idempotent: CREATE OR REPLACE plus DROP TRIGGER IF EXISTS.
-- No new table, view or grant, so rls_verify is unaffected; run it anyway per CLAUDE.md.

begin;

CREATE OR REPLACE FUNCTION public.lots_refuse_test()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
BEGIN
    IF NEW.is_test IS TRUE THEN
        RAISE EXCEPTION 'Test lots are not allowed in the live books (lot %). Use a test database.', NEW.lot_number
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.lot_number ~* '^test' THEN
        RAISE EXCEPTION 'Lot numbers starting with "test" are reserved for test data and are not allowed in the live books (lot %).', NEW.lot_number
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lots_refuse_test() FROM PUBLIC;

DROP TRIGGER IF EXISTS lots_refuse_test ON public.lots;
CREATE TRIGGER lots_refuse_test
    BEFORE INSERT OR UPDATE OF is_test, lot_number ON public.lots
    FOR EACH ROW EXECUTE FUNCTION public.lots_refuse_test();

COMMENT ON FUNCTION public.lots_refuse_test() IS
 'Refuses is_test lots and lot numbers starting "test" in production. Test lots were purged 2026-10-07; see docs/test-lots-cleanup.md.';

-- Prove it: no lot breaks the rule today, and the trigger refuses both shapes.
do $$
declare
    v_id  uuid;
    v_hit boolean;
begin
    if exists (select 1 from public.lots where is_test or lot_number ~* '^test') then
        raise exception 'A lot already breaks the rule. Purge it first. Rolled back.';
    end if;

    select id into v_id from public.lots order by created_at limit 1;

    v_hit := false;
    begin
        update public.lots set is_test = true where id = v_id;
    exception when check_violation then v_hit := true;
    end;
    if not v_hit then raise exception 'Trigger did not refuse is_test = true. Rolled back.'; end if;

    v_hit := false;
    begin
        update public.lots set lot_number = 'TEST_PROBE' where id = v_id;
    exception when check_violation then v_hit := true;
    end;
    if not v_hit then raise exception 'Trigger did not refuse a TEST lot number. Rolled back.'; end if;

    raise notice 'lots_refuse_test installed and proven.';
end
$$;

commit;
