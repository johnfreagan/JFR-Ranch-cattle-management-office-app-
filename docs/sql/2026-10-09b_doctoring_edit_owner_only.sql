-- 2026-10-09b  Posted doctoring: owner edits, office voids and re-enters.
--
-- John, 2026-10-09: "office void and reenter, owner edit entries." A posted
-- doctoring event is the books' record of what was given to which animal and
-- what it cost. The office keeps the ability to remove one (Void & re-enter
-- in the doctoring modal) and to post new ones; changing one in place is the
-- owner's call.
--
-- 1. UPDATE on doctoring_events and doctoring_event_meds narrows from
--    {owner, office} to {owner}. INSERT and DELETE are unchanged: office
--    still posts approvals, rolls a failed batch back, voids, and re-enters.
--    Nothing in the database updates these tables as office (checked: no
--    function body updates them; the only client UPDATE is the modal save).
-- 2. doctoring_event_audit keeps what was there before every edit and every
--    removal, so a void is not a disappearance. Written only by triggers
--    (SECURITY DEFINER: the table has no INSERT policy for anyone, which is
--    the point - nobody can write or forge an audit row from the client).
--    Readable by books readers only: med rows carry cost.
--
-- Limit worth knowing: an office user can still delete a posted event's med
-- lines and insert new ones (both verbs are needed for void and for posting).
-- The app does not offer that path to office; the audit records it if it
-- ever happens (every removed med line is logged).

begin;

create table if not exists public.doctoring_event_audit (
    id                 bigserial primary key,
    doctoring_event_id uuid        not null,
    op                 text        not null check (op in ('edit', 'void', 'med_removed')),
    old_row            jsonb       not null,
    new_row            jsonb,
    changed_by         uuid,
    changed_role       text,
    changed_at         timestamptz not null default now()
);
comment on table public.doctoring_event_audit is
    'Before-images of posted doctoring. edit = owner changed the event (old_row/new_row); void = event removed; med_removed = one med line removed (also fires on an owner edit, which deletes and re-inserts meds). Trigger-written only; no client INSERT.';
create index if not exists doctoring_event_audit_event_idx
    on public.doctoring_event_audit (doctoring_event_id, changed_at);

alter table public.doctoring_event_audit enable row level security;
revoke all on public.doctoring_event_audit from public, anon;
grant select on public.doctoring_event_audit to authenticated;
revoke all on sequence public.doctoring_event_audit_id_seq from public, anon;

drop policy if exists doctoring_event_audit_select on public.doctoring_event_audit;
create policy doctoring_event_audit_select on public.doctoring_event_audit
    for select to authenticated
    using (public.can_read_books());

-- SECURITY DEFINER: the audit table grants no INSERT, so the trigger must
-- run as the owner to write it. search_path pinned.
create or replace function public.doctoring_audit_capture()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $fn$
declare
    v_role text := public.current_user_role();
begin
    if tg_table_name = 'doctoring_events' then
        if tg_op = 'UPDATE' then
            -- touch_updated_at alone is not an edit.
            if (to_jsonb(old) - 'updated_at') = (to_jsonb(new) - 'updated_at') then
                return new;
            end if;
            insert into public.doctoring_event_audit
                (doctoring_event_id, op, old_row, new_row, changed_by, changed_role)
            values (old.id, 'edit', to_jsonb(old), to_jsonb(new), auth.uid(), v_role);
            return new;
        else
            insert into public.doctoring_event_audit
                (doctoring_event_id, op, old_row, changed_by, changed_role)
            values (old.id, 'void', to_jsonb(old), auth.uid(), v_role);
            return old;
        end if;
    else  -- doctoring_event_meds, DELETE
        insert into public.doctoring_event_audit
            (doctoring_event_id, op, old_row, changed_by, changed_role)
        values (old.doctoring_event_id, 'med_removed', to_jsonb(old), auth.uid(), v_role);
        return old;
    end if;
end;
$fn$;
revoke all on function public.doctoring_audit_capture() from public, anon;

drop trigger if exists doctoring_events_audit on public.doctoring_events;
create trigger doctoring_events_audit
    after update or delete on public.doctoring_events
    for each row execute function public.doctoring_audit_capture();

drop trigger if exists doctoring_event_meds_audit on public.doctoring_event_meds;
create trigger doctoring_event_meds_audit
    after delete on public.doctoring_event_meds
    for each row execute function public.doctoring_audit_capture();

drop policy if exists doctoring_events_update on public.doctoring_events;
create policy doctoring_events_update on public.doctoring_events
    for update to public
    using (current_user_role() = 'owner')
    with check (current_user_role() = 'owner');

drop policy if exists doctoring_event_meds_update on public.doctoring_event_meds;
create policy doctoring_event_meds_update on public.doctoring_event_meds
    for update to public
    using (current_user_role() = 'owner')
    with check (current_user_role() = 'owner');

commit;
