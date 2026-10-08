-- Dry run of docs/sql/2026-10-08_lots_refuse_test.sql. One statement: it installs the trigger,
-- proves it refuses both shapes, then raises DRY_RUN_OK so everything rolls back.
-- Success = an error that starts "DRY_RUN_OK". Any other error names the check that failed.

do $dry$
declare
    v_id  uuid;
    v_hit boolean;
begin
    execute $ddl$
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
$fn$
$ddl$;
    execute 'REVOKE ALL ON FUNCTION public.lots_refuse_test() FROM PUBLIC';
    execute 'DROP TRIGGER IF EXISTS lots_refuse_test ON public.lots';
    execute 'CREATE TRIGGER lots_refuse_test BEFORE INSERT OR UPDATE OF is_test, lot_number ON public.lots FOR EACH ROW EXECUTE FUNCTION public.lots_refuse_test()';

    if exists (select 1 from public.lots where is_test or lot_number ~* '^test') then
        raise exception 'A lot already breaks the rule. Purge it first.';
    end if;

    select id into v_id from public.lots order by created_at limit 1;

    v_hit := false;
    begin
        update public.lots set is_test = true where id = v_id;
    exception when check_violation then v_hit := true;
    end;
    if not v_hit then raise exception 'Trigger did not refuse is_test = true.'; end if;

    v_hit := false;
    begin
        update public.lots set lot_number = 'TEST_PROBE' where id = v_id;
    exception when check_violation then v_hit := true;
    end;
    if not v_hit then raise exception 'Trigger did not refuse a TEST lot number.'; end if;

    -- A normal edit of a real lot still works.
    update public.lots set lot_number = lot_number where id = v_id;

    raise exception 'DRY_RUN_OK trigger refuses is_test and TEST lot numbers, normal edits pass; rolling back on purpose.';
end
$dry$;
