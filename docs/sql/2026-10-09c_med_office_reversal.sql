-- =====================================================================
-- Office can void a treatment, re-save a load out and undo a medicine
-- charge without leaving the ledger row behind.
-- =====================================================================
-- 2026-10-09. John: option A ("1. A  2. Yes same rules as 1 above") from
-- docs/OPEN-ITEMS.md 0m.
--
-- THE BUG. med_reverse_txn() is INVOKER: it puts the units back on the
-- layers, then deletes the med_txns row. The med_txns delete policy is
-- owner only, so for an office login RLS filtered that DELETE to zero rows
-- without an error: the units were back on the shelf AND still booked as
-- used. A void and re-enter then drew the doses a second time, and the next
-- count would have called the difference shrink. It became an everyday
-- path on 2026-10-09, when the office got Void & re-enter on posted
-- doctoring (2026-10-09b). No damage on the books when this was written:
-- all 26 treatment draws matched their doctoring rows, no ledger row
-- pointed at a deleted event, and the office had drawn nothing yet.
--
-- THE FIX. Office never deletes a ledger row directly - the med_txns delete
-- policy stays owner only. It gets three functions that do the PAIRED
-- operation, units back and row gone, in one transaction, and assert the
-- row is gone before they return. They are SECURITY DEFINER for exactly
-- that reason (docs/database.md rule 6): the paired form is the only way a
-- non-owner may remove a ledger row, so a row can never vanish without its
-- units going back, and units can never go back without the row vanishing.
-- Each checks the role gate itself (owner or office), pins search_path,
-- and is revoked from PUBLIC and anon.
--
-- 1. med_void_doctoring(event_ids) - void or delete treatments. Reverses
--    every draw on them and deletes the events and their med lines,
--    so a draw can never be put back while its treatment stays on the
--    books.
--    REFUSES, changing nothing, when any draw is in a counted,
--    closed month: removing it would change a posted count. The owner can
--    still correct such a treatment by editing it in place.
--
-- 2. med_reverse_doctoring_for_edit(event_id) - the owner's edit in place.
--    INVOKER and owner only (only the owner edits posted doctoring,
--    2026-10-09b). Reverses the draws in open months, KEEPS the ones in a
--    closed month and says how many it kept; the app then does not redraw,
--    so the shelf is left as drawn - John's rule for processing, 2026-10-02.
--
-- 3. med_processing_reverse(receipt_id) - same body as before (it already
--    skipped closed months), now DEFINER with the gate and the assertion,
--    so an office re-save of a load out no longer draws twice.
--
-- 4. delete_med_charge(charge_id) - office may undo too, same rules: the
--    gate is owner or office, and the closed-month refusal stays. DEFINER.
--    The med_charges delete policy stays owner only; office removes a
--    charge only through this function, which takes the ledger row with it.
--
-- No table, view or policy changes. No data changes.
--
-- The bodies contain DELETE, so the Supabase connector stalls on this file
-- (docs/feed-pb-import.md 2026-10-03). Run it in the SQL editor as it is.
-- Tests: docs/sql/tests/2026-10-09c_med_office_reversal_tests.sql.
-- Afterwards run supabase/migrations/20260821000300_rls_verify.sql.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Void or delete treatments
-- ---------------------------------------------------------------------
create or replace function public.med_void_doctoring(p_event_ids uuid[])
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare
    v_ids       uuid[];
    v_locked_n  integer;
    v_locked_to date;
    v_rev       integer := 0;
    v_units     numeric := 0;
    v_events    integer;
    v_res       jsonb;
    row_rec     record;
begin
    if coalesce(public.current_user_role(), '') not in ('owner', 'office') then
        raise exception 'med_void_doctoring: only an owner or office login can void a treatment'
            using errcode = 'insufficient_privilege';
    end if;

    select coalesce(array_agg(distinct x), '{}') into v_ids
      from unnest(coalesce(p_event_ids, '{}')) x where x is not null;
    if cardinality(v_ids) = 0 then
        return jsonb_build_object('events_removed', 0, 'draws_reversed', 0, 'restored_units', 0);
    end if;

    -- Refuse first, before anything changes.
    select count(*), max(public.med_locked_through(t.location_id))
      into v_locked_n, v_locked_to
      from public.med_txns t
     where t.ref_kind = 'doctoring_event' and t.ref_id = any (v_ids)
       and t.direction = -1
       and t.txn_date <= public.med_locked_through(t.location_id);
    if v_locked_n > 0 then
        raise exception 'This treatment''s medicine (% draw(s)) is in a month that is counted and closed through %. Voiding or deleting it would change a posted count. The owner can correct it by editing it instead.',
            v_locked_n, v_locked_to using errcode = 'check_violation';
    end if;

    for row_rec in
        select t.id from public.med_txns t
         where t.ref_kind = 'doctoring_event' and t.ref_id = any (v_ids)
           and t.direction = -1
         order by t.created_at desc
         for update
    loop
        v_res := public.med_reverse_txn(row_rec.id);
        if exists (select 1 from public.med_txns where id = row_rec.id) then
            raise exception 'med_void_doctoring: ledger row % was not removed - nothing changed', row_rec.id;
        end if;
        v_rev   := v_rev + 1;
        v_units := v_units + coalesce((v_res->>'restored_units')::numeric, 0);
    end loop;

    -- The treatments go with their draws. Med lines first, explicitly: the
    -- live foreign key cascades, but this must not depend on it.
    delete from public.doctoring_event_meds where doctoring_event_id = any (v_ids);
    delete from public.doctoring_events where id = any (v_ids);
    get diagnostics v_events = row_count;

    return jsonb_build_object(
        'events_removed', v_events,
        'draws_reversed', v_rev,
        'restored_units', v_units
    );
end
$fn$;

comment on function public.med_void_doctoring(uuid[]) is
 'Void or delete treatments: reverses every medicine draw on them (units back on the layers they came off) and deletes the events, in one transaction. Owner or office. Refuses, changing nothing, when a draw is in a counted, closed month. SECURITY DEFINER because the office may remove a ledger row only in this paired form; med_txns delete stays owner only.';

-- ---------------------------------------------------------------------
-- 2. The owner's edit in place
-- ---------------------------------------------------------------------
create or replace function public.med_reverse_doctoring_for_edit(p_event_id uuid)
returns jsonb
language plpgsql security invoker set search_path = public, pg_temp as $fn$
declare
    v_rev    integer := 0;
    v_kept   integer := 0;
    v_lock   date;
    row_rec  record;
begin
    if coalesce(public.current_user_role(), '') <> 'owner' then
        raise exception 'med_reverse_doctoring_for_edit: only an owner edits a posted treatment'
            using errcode = 'insufficient_privilege';
    end if;

    for row_rec in
        select t.id, t.location_id, t.txn_date from public.med_txns t
         where t.ref_kind = 'doctoring_event' and t.ref_id = p_event_id
           and t.direction = -1
         order by t.created_at desc
         for update
    loop
        v_lock := public.med_locked_through(row_rec.location_id);
        if v_lock is not null and row_rec.txn_date <= v_lock then
            v_kept := v_kept + 1;
            continue;
        end if;
        perform public.med_reverse_txn(row_rec.id);
        if exists (select 1 from public.med_txns where id = row_rec.id) then
            raise exception 'med_reverse_doctoring_for_edit: ledger row % was not removed - nothing changed', row_rec.id;
        end if;
        v_rev := v_rev + 1;
    end loop;

    return jsonb_build_object('event_id', p_event_id, 'draws_reversed', v_rev, 'draws_kept_closed_month', v_kept);
end
$fn$;

comment on function public.med_reverse_doctoring_for_edit(uuid) is
 'Owner edit of a posted treatment: reverses its medicine draws in open months and keeps those in a counted, closed month (draws_kept_closed_month). When any is kept the app does not redraw, so the shelf is left as drawn.';

-- ---------------------------------------------------------------------
-- 3. Re-saved load outs
-- ---------------------------------------------------------------------
create or replace function public.med_processing_reverse(p_receipt_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare
    t        record;
    v_n      integer := 0;
    v_locked integer := 0;
    v_lock   date;
begin
    if coalesce(public.current_user_role(), '') not in ('owner', 'office') then
        raise exception 'med_processing_reverse: only an owner or office login can re-draw processing medicine'
            using errcode = 'insufficient_privilege';
    end if;

    for t in
        select x.id, x.location_id, x.txn_date from public.med_txns x
         where x.ref_kind = 'delivery_receipt' and x.ref_id = p_receipt_id and x.direction = -1
         order by x.created_at desc
    loop
        v_lock := public.med_locked_through(t.location_id);
        if v_lock is not null and t.txn_date <= v_lock then
            v_locked := v_locked + 1;
            continue;
        end if;
        perform public.med_reverse_txn(t.id);
        if exists (select 1 from public.med_txns where id = t.id) then
            raise exception 'med_processing_reverse: ledger row % was not removed - nothing changed', t.id;
        end if;
        v_n := v_n + 1;
    end loop;

    return jsonb_build_object('receipt_id', p_receipt_id, 'lines_reversed', v_n,
                              'lines_locked', v_locked);
end
$fn$;

comment on function public.med_processing_reverse(uuid) is
 'Puts a load out''s processing draws back on the shelf before it is re-drawn, skipping draws in a counted, closed month (lines_locked). Owner or office. SECURITY DEFINER because the office may remove a ledger row only in this paired form; med_txns delete stays owner only.';

-- ---------------------------------------------------------------------
-- 4. Undo a direct medicine charge - office too, same rules
-- ---------------------------------------------------------------------
create or replace function public.delete_med_charge(p_charge_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare
    v_txn      uuid;
    v_loc      uuid;
    v_posted   date;
    v_locked   date;
    v_n        integer;
    v_res      jsonb;
begin
    if coalesce(public.current_user_role(), '') not in ('owner', 'office') then
        raise exception 'delete_med_charge: only an owner or office login can undo a medicine charge'
            using errcode = 'insufficient_privilege';
    end if;

    select c.txn_id, t.location_id, t.txn_date into v_txn, v_loc, v_posted
      from public.med_charges c
      join public.med_txns t on t.id = c.txn_id
     where c.id = p_charge_id;
    if v_txn is null then
        raise exception 'delete_med_charge: no such charge %', p_charge_id;
    end if;

    v_locked := public.med_locked_through(v_loc);
    if v_locked is not null and v_posted <= v_locked then
        raise exception 'delete_med_charge: this charge posted % and that month is counted and closed through %. Undoing it would change a posted count. Correct it with a new charge or at the next count.',
            v_posted, v_locked using errcode = 'check_violation';
    end if;

    delete from public.med_charges where id = p_charge_id;
    get diagnostics v_n = row_count;
    if v_n <> 1 then
        raise exception 'delete_med_charge: the charge was not removed (% rows) - nothing changed', v_n;
    end if;

    v_res := public.med_reverse_txn(v_txn);

    if exists (select 1 from public.med_txns where id = v_txn) then
        raise exception 'delete_med_charge: the ledger row % was not removed - nothing changed', v_txn;
    end if;

    return jsonb_build_object(
        'charge_id',      p_charge_id,
        'txn_id',         v_txn,
        'restored_units', (v_res->>'restored_units')::numeric
    );
end
$fn$;

comment on function public.delete_med_charge(uuid) is
 'Undo a medicine charge: removes the charge and reverses its ledger row, putting the units back on the layers they came off. Owner or office; refused when the posted day is in a counted, closed month. SECURITY DEFINER because the office may remove a ledger row only in this paired form; med_charges and med_txns delete stay owner only.';

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
revoke all on function public.med_void_doctoring(uuid[]) from public;
revoke all on function public.med_void_doctoring(uuid[]) from anon;
grant execute on function public.med_void_doctoring(uuid[]) to authenticated;
revoke all on function public.med_reverse_doctoring_for_edit(uuid) from public;
revoke all on function public.med_reverse_doctoring_for_edit(uuid) from anon;
grant execute on function public.med_reverse_doctoring_for_edit(uuid) to authenticated;
revoke all on function public.med_processing_reverse(uuid) from public;
revoke all on function public.med_processing_reverse(uuid) from anon;
grant execute on function public.med_processing_reverse(uuid) to authenticated;
revoke all on function public.delete_med_charge(uuid) from public;
revoke all on function public.delete_med_charge(uuid) from anon;
grant execute on function public.delete_med_charge(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Verify
-- ---------------------------------------------------------------------
do $verify$
declare
    bad integer;
begin
    -- The three DEFINER functions: DEFINER, pinned search_path, no anon.
    select count(*) into bad from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('med_void_doctoring', 'med_processing_reverse', 'delete_med_charge')
       and (not p.prosecdef or p.proconfig is null or not (p.proconfig::text like '%search_path=%')
            or has_function_privilege('anon', p.oid, 'EXECUTE'));
    if bad > 0 then
        raise exception '% reversal function(s) are not DEFINER with a pinned search_path, or anon can run them', bad;
    end if;

    -- The edit helper stays INVOKER.
    select count(*) into bad from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = 'med_reverse_doctoring_for_edit'
       and (p.prosecdef or p.proconfig is null or has_function_privilege('anon', p.oid, 'EXECUTE'));
    if bad > 0 then raise exception 'med_reverse_doctoring_for_edit is DEFINER, unpinned or anon-callable'; end if;

    -- Ledger rows stay owner-only to delete directly.
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'med_txns'
                    and cmd = 'DELETE' and qual = '(current_user_role() = ''owner''::text)') then
        raise exception 'the med_txns delete policy is no longer owner only';
    end if;

    raise notice 'VERIFIED: med_void_doctoring, med_processing_reverse, delete_med_charge DEFINER + gated + pinned; edit helper INVOKER; med_txns delete still owner only.';
end
$verify$;

commit;
