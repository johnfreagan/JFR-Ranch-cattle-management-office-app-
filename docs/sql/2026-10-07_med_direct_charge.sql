-- =====================================================================
-- Direct medicine charges: medicine charged straight to a lot (no
-- doctoring event) or to a cost centre (non-lot production details, WIP).
-- =====================================================================
-- 2026-10-07. John: "We need to add the ability to charge medicine
-- directly to a production center detail or WIP account. Similar to feed."
-- Spec: docs/med-direct-charge-handoff.md. His decisions:
--
--   * Covers lots with no doctoring event (pour-on, water med on a whole
--     lot), non-lot production details (cows, bulls, horses, feeder month
--     buckets) and WIP accounts.
--   * Cost centres are SHARED with feed: one cost_centers list.
--   * A medicine cost-centre charge always books to 130000 Vet & Medicine -
--     WIP. The cost centre supplies only Profit Center and Production
--     Center; its own redwing_account is feed's and is NOT used here.
--   * Entry is Inventory > Medicine, office only. Not the field app.
--   * A lot charge says Processing, Treatment or Other and lands on that
--     line of the lot's closeout.
--
-- What this builds:
--
-- 1. med_charges, one row a charge. The stock leaves the shelf through
--    med_consume() exactly like a doctoring dose - FIFO per (med, pool),
--    the period-lock bump to the first open day, uncovered usage allowed
--    and flagged - and the ledger row carries ref_kind 'med_charge',
--    ref_id = the charge. The charge keeps txn_id so its dollars are
--    always the ledger's dollars; nothing is priced twice.
--
-- 2. post_med_charge() posts one; delete_med_charge() is the entry-
--    mistake undo: it puts the units back on the exact layers they came
--    off (med_reverse_txn) and removes the charge.
--
--    THE UNDO IS OWNER ONLY. med_reverse_txn() is INVOKER and the
--    med_txns delete policy is owner only, so an office login running it
--    would restore the layers and then have its DELETE of the ledger row
--    filtered to nothing by RLS - the units back on the shelf AND still
--    counted as used. Rather than make this function SECURITY DEFINER (a
--    change to who may delete ledger rows, which is John's call), it
--    refuses anyone but an owner up front and asserts afterwards that the
--    ledger row is really gone. It also refuses a charge whose posted day
--    is in a counted, closed month: putting units back into a closed month
--    would change a count that has already booked its shrink.
--
-- 3. lot_med_costs_by_category: lot charges join the doctoring rows under
--    the category chosen. Same columns, same order, so CREATE OR REPLACE
--    works with no DROP; still one row per (lot, category), because the
--    lot page does find(r => r.category === cat) and would miss a second.
--    Lots with no charge read exactly as before - that is asserted below.
--
-- 4. med_usage_by_lot: a lot charge resolves to its lot and category; a
--    cost-centre charge has no lot and category 'cost_center', and four
--    columns are APPENDED (cost_center_id, cost_center_name, profit_center,
--    redwing_production_center) for the Redwing report's cost-centre
--    section. Existing columns unchanged and in order.
--
-- RLS: select through can_read_books(); insert and update owner + office;
-- delete owner, matching med_txns. Crew is named nowhere. Nothing is
-- SECURITY DEFINER.
--
-- No data changes. Idempotent: no DROP anywhere (the Supabase connector
-- stalls on DROP and DELETE, docs/feed-pb-import.md 2026-10-03), policies
-- created only when missing. delete_med_charge's body and the delete
-- policy still contain DELETE; if apply_migration stalls on them, run this
-- file in the Supabase SQL editor as it stands.
--
-- Tests: docs/sql/tests/2026-10-07_med_direct_charge_fixture.sql and
-- _tests.sql, on a throwaway PostgreSQL 16 (docs/sql/tests/README.md).
-- Afterwards run supabase/migrations/20260821000300_rls_verify.sql.
--
-- APPLIED live 2026-10-08 by John in the Supabase SQL editor, after
-- apply_migration stalled (60 s timeout, nothing applied) as expected on
-- the DELETE. The text run was this file with the comment lines removed,
-- so md5(prosrc) live equals this file's bodies with comment-only lines
-- stripped (regexp_replace(prosrc, E'\n[ ]*--[^\n]*', '', 'g')):
--   post_med_charge   14fc238d2c71bca1230d306bd7c411aa
--   delete_med_charge 96d1cf1df0c9e406c239687c80d4452c
-- pg_get_viewdef md5, live = this file applied locally:
--   lot_med_costs_by_category f94223ae6820b594182667e964a0f31f
--   med_usage_by_lot          6dd912e07d4e7d3f8333acf40557c9a4
-- Before/after: lot_med_costs_by_category 13 rows, $23,166.64, row hash
-- f83e2430... unchanged; med_usage_by_lot 92 rows, $2,958.54, old-column
-- hash 92c842d9... unchanged. rls_verify assertions 1-8 all hold (run as
-- separate selects). Live tests ran inside a DO block that ended in RAISE,
-- so nothing stayed: 0 charges, 0 med_charge ledger rows afterwards.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------
create table if not exists public.med_charges (
    id              uuid primary key default gen_random_uuid(),
    -- The day it was GIVEN. The ledger row's txn_date is the day it was
    -- POSTED, which is later when that month was already counted.
    charge_date     date not null,
    medication_id   uuid not null references public.medications(id) on delete restrict,
    location_id     uuid not null references public.med_stock_locations(id) on delete restrict,
    qty_units       numeric not null check (qty_units > 0),
    destination     text not null check (destination in ('lot', 'cost_center')),
    lot_id          uuid references public.lots(id) on delete restrict,
    cost_center_id  uuid references public.cost_centers(id) on delete restrict,
    category        text check (category in ('processing', 'treatment', 'other')),
    -- RESTRICT: the ledger row is the charge's dollars. Removing one
    -- without the other is exactly the drift this table exists to prevent;
    -- delete_med_charge() removes the charge first, then the ledger row.
    txn_id          uuid not null unique references public.med_txns(id) on delete restrict,
    notes           text,
    created_by      uuid default auth.uid(),
    created_at      timestamptz not null default now(),
    -- Same shape rule as feed_usage: a lot charge names a lot and a
    -- category and no cost centre; a cost-centre charge names a cost
    -- centre and nothing else.
    constraint med_charges_shape_ck check (
        (destination = 'lot'
            and lot_id is not null and category is not null and cost_center_id is null)
     or (destination = 'cost_center'
            and cost_center_id is not null and lot_id is null and category is null)
    )
);

create index if not exists med_charges_lot_idx
    on public.med_charges (lot_id) where lot_id is not null;
create index if not exists med_charges_cost_center_idx
    on public.med_charges (cost_center_id) where cost_center_id is not null;
create index if not exists med_charges_date_idx
    on public.med_charges (charge_date);

comment on table public.med_charges is
 'Medicine charged straight to a lot (no doctoring event) or to a cost centre. The stock leaves through med_consume (ref_kind med_charge, ref_id = id); txn_id is that ledger row and carries the dollars. Lot charges feed lot_med_costs_by_category under their category; cost-centre charges book to 130000 Vet & Medicine - WIP with the cost centre''s Profit Center / Production Center.';

alter table public.med_charges enable row level security;

do $policies$
begin
    if not exists (select 1 from pg_policies where schemaname = 'public'
                     and tablename = 'med_charges' and policyname = 'med_charges_select') then
        create policy med_charges_select on public.med_charges
            for select using (public.can_read_books());
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'public'
                     and tablename = 'med_charges' and policyname = 'med_charges_insert') then
        create policy med_charges_insert on public.med_charges
            for insert with check (public.current_user_role() = any (array['owner','office']));
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'public'
                     and tablename = 'med_charges' and policyname = 'med_charges_update') then
        create policy med_charges_update on public.med_charges
            for update using (public.current_user_role() = any (array['owner','office']))
            with check (public.current_user_role() = any (array['owner','office']));
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'public'
                     and tablename = 'med_charges' and policyname = 'med_charges_delete') then
        create policy med_charges_delete on public.med_charges
            for delete using (public.current_user_role() = 'owner');
    end if;
end
$policies$;

revoke all on public.med_charges from public;
revoke all on public.med_charges from anon;
grant select, insert, update, delete on public.med_charges to authenticated;

-- ---------------------------------------------------------------------
-- 2. Post one
-- ---------------------------------------------------------------------
create or replace function public.post_med_charge(
    p_date            date,
    p_medication_id   uuid,
    p_location_id     uuid,
    p_qty_units       numeric,
    p_destination     text,
    p_lot_id          uuid default null,
    p_cost_center_id  uuid default null,
    p_category        text default null,
    p_notes           text default null
) returns jsonb
language plpgsql security invoker set search_path = public, pg_temp as $fn$
declare
    v_id        uuid := gen_random_uuid();
    v_date      date := coalesce(p_date, public.ranch_today());
    v_med       text;
    v_loc       text;
    v_from      date;
    v_lot_no    text;
    v_closed    timestamptz;
    v_cc        text;
    v_cc_active boolean;
    v_label     text;
    v_res       jsonb;
    v_txn       uuid;
    v_prov      boolean;
    v_posted    date;
begin
    if coalesce(public.current_user_role(), '') not in ('owner', 'office') then
        raise exception 'post_med_charge: only an owner or office login can charge medicine'
            using errcode = 'insufficient_privilege';
    end if;
    if p_qty_units is null or p_qty_units <= 0 then
        raise exception 'post_med_charge: quantity must be more than zero (got %)', p_qty_units;
    end if;

    select name into v_med from public.medications where id = p_medication_id;
    if v_med is null then
        raise exception 'post_med_charge: no such medication';
    end if;

    select name, usage_from into v_loc, v_from
      from public.med_stock_locations where id = p_location_id and is_active;
    if v_loc is null then
        raise exception 'post_med_charge: no active shelf with that id';
    end if;
    if v_from is null then
        raise exception 'post_med_charge: % is not live in the ledger yet (no usage start date), so nothing can be charged out of it', v_loc;
    end if;

    if p_destination = 'lot' then
        if p_cost_center_id is not null then
            raise exception 'post_med_charge: a lot charge cannot also name a cost centre';
        end if;
        if p_category is null or p_category not in ('processing', 'treatment', 'other') then
            raise exception 'post_med_charge: a lot charge needs a category - processing, treatment or other (got %)',
                coalesce(p_category, 'none');
        end if;
        select lot_number, closed_at into v_lot_no, v_closed from public.lots where id = p_lot_id;
        if v_lot_no is null then
            raise exception 'post_med_charge: no such lot';
        end if;
        if v_closed is not null then
            raise exception 'post_med_charge: lot % is closed - its closeout is final', v_lot_no;
        end if;
        v_label := 'Charged to lot ' || v_lot_no || ' (' || p_category || ')';
    elsif p_destination = 'cost_center' then
        if p_lot_id is not null or p_category is not null then
            raise exception 'post_med_charge: a cost-centre charge names no lot and no category';
        end if;
        select name, is_active into v_cc, v_cc_active from public.cost_centers where id = p_cost_center_id;
        if v_cc is null then
            raise exception 'post_med_charge: no such cost centre';
        end if;
        if not v_cc_active then
            raise exception 'post_med_charge: cost centre % is inactive', v_cc;
        end if;
        v_label := 'Charged to cost centre ' || v_cc;
    else
        raise exception 'post_med_charge: destination must be lot or cost_center (got %)',
            coalesce(p_destination, 'none');
    end if;

    -- The draw. Same function as every doctoring dose: FIFO, the closed-
    -- month bump with its note, and short stock saved and flagged rather
    -- than refused.
    v_res := public.med_consume(
        p_medication_id, p_location_id, p_qty_units,
        'usage',
        case p_destination when 'lot' then 'lot_charge' else 'cost_center' end,
        'med_charge', v_id, v_date,
        v_label || '.' || coalesce(' ' || nullif(btrim(p_notes), ''), ''),
        null);
    v_txn    := (v_res->>'txn_id')::uuid;
    v_posted := (v_res->>'posted_date')::date;

    insert into public.med_charges (
        id, charge_date, medication_id, location_id, qty_units, destination,
        lot_id, cost_center_id, category, txn_id, notes, created_by
    ) values (
        v_id, v_date, p_medication_id, p_location_id, p_qty_units, p_destination,
        case when p_destination = 'lot' then p_lot_id end,
        case when p_destination = 'cost_center' then p_cost_center_id end,
        case when p_destination = 'lot' then p_category end,
        v_txn, nullif(btrim(p_notes), ''), auth.uid()
    );

    select cost_provisional into v_prov from public.med_txns where id = v_txn;

    return jsonb_build_object(
        'charge_id',        v_id,
        'txn_id',           v_txn,
        'total_cost',       (v_res->>'total_cost')::numeric,
        'shortfall_units',  (v_res->>'shortfall_units')::numeric,
        'cost_provisional', coalesce(v_prov, false),
        'charge_date',      v_date,
        'posted_date',      v_posted
    );
end
$fn$;

comment on function public.post_med_charge(date, uuid, uuid, numeric, text, uuid, uuid, text, text) is
 'Charge medicine straight to a lot (category processing|treatment|other) or to an active cost centre. Draws FIFO through med_consume; returns charge_id, txn_id, total_cost, shortfall_units, cost_provisional, charge_date, posted_date (later than charge_date when that month was counted and closed). Owner or office.';

-- ---------------------------------------------------------------------
-- 3. Undo one (entry mistakes)
-- ---------------------------------------------------------------------
create or replace function public.delete_med_charge(p_charge_id uuid)
returns jsonb
language plpgsql security invoker set search_path = public, pg_temp as $fn$
declare
    v_txn      uuid;
    v_loc      uuid;
    v_posted   date;
    v_locked   date;
    v_n        integer;
    v_res      jsonb;
begin
    if coalesce(public.current_user_role(), '') <> 'owner' then
        raise exception 'delete_med_charge: only an owner can undo a medicine charge - the ledger row it posted can only be removed by an owner'
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

    -- RLS filters a refused DELETE to zero rows instead of raising. If the
    -- ledger row survived, the layers were restored and the usage is still
    -- booked: stop and roll the lot back.
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
 'Undo a medicine charge: removes the charge and reverses its ledger row, putting the units back on the layers they came off. Owner only (med_txns delete is owner only); refused when the posted day is in a counted, closed month.';

revoke all on function public.post_med_charge(date, uuid, uuid, numeric, text, uuid, uuid, text, text) from public;
revoke all on function public.post_med_charge(date, uuid, uuid, numeric, text, uuid, uuid, text, text) from anon;
grant execute on function public.post_med_charge(date, uuid, uuid, numeric, text, uuid, uuid, text, text) to authenticated;
revoke all on function public.delete_med_charge(uuid) from public;
revoke all on function public.delete_med_charge(uuid) from anon;
grant execute on function public.delete_med_charge(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. The lot's medicine cost, by category
-- ---------------------------------------------------------------------
-- Same four-plus-two columns in the same order and types. For a lot with
-- no charges every figure is what the old view returned: sum() of the one
-- source row is that row, a NULL total stays NULL.
create or replace view public.lot_med_costs_by_category
with (security_invoker = true) as
with src as (
    select de.lot_id,
           coalesce(fa.category, 'treatment'::text)          as category,
           sum(dem.cost)                                     as total_cost,
           count(distinct de.id)                             as event_count,
           count(dem.id)                                     as med_row_count,
           count(dem.id) filter (where dem.cost is null)     as unpriced_row_count
      from public.doctoring_event_meds dem
      join public.doctoring_events de on de.id = dem.doctoring_event_id
      left join public.field_actions fa on fa.id = de.field_action_id
     group by de.lot_id, coalesce(fa.category, 'treatment'::text)
    union all
    -- Direct charges. A charge is its own "event" and its own med row; an
    -- unpriced draw (booked at $0, cost_provisional) counts as unpriced.
    select c.lot_id,
           c.category,
           sum(t.total_cost),
           count(*),
           count(*),
           count(*) filter (where t.cost_provisional)
      from public.med_charges c
      join public.med_txns t on t.id = c.txn_id
     where c.destination = 'lot'
     group by c.lot_id, c.category
)
select lot_id,
       category,
       sum(total_cost)                   as total_cost,
       sum(event_count)::bigint          as event_count,
       sum(med_row_count)::bigint        as med_row_count,
       sum(unpriced_row_count)::bigint   as unpriced_row_count
  from src
 group by lot_id, category;

comment on view public.lot_med_costs_by_category is
 'A lot''s medicine cost by category: doctoring_event_meds by field_actions.category (default treatment), plus direct med_charges to the lot under the category chosen at entry. One row per (lot, category).';

-- ---------------------------------------------------------------------
-- 5. Usage resolved to a lot, or to a cost centre
-- ---------------------------------------------------------------------
create or replace view public.med_usage_by_lot
with (security_invoker = true) as
select t.id                                          as txn_id,
       t.txn_date,
       t.fiscal_year,
       coalesce(dr.lot_id, de.lot_id, mc.lot_id)     as lot_id,
       l.lot_number,
       t.ref_kind,
       case t.ref_kind
            when 'delivery_receipt' then 'processing'::text
            when 'doctoring_event'  then 'treatment'::text
            when 'med_charge'       then coalesce(mc.category,
                                            case when mc.destination = 'cost_center' then 'cost_center' end,
                                            t.reason, 'other')
            else coalesce(t.reason, 'other'::text)
       end                                           as category,
       t.medication_id,
       m.name                                        as medication_name,
       m.generic_category,
       m.redwing_item_code,
       coalesce(m.bottle_size_unit, 'mL'::text)      as unit,
       m.bottle_size,
       t.qty_units,
       t.total_cost,
       t.shortfall_units,
       t.cost_provisional,
       t.location_id,
       loc.name                                      as location_name,
       mc.cost_center_id,
       cc.name                                       as cost_center_name,
       cc.profit_center,
       cc.redwing_production_center
  from public.med_txns t
  join public.medications m                on m.id = t.medication_id
  left join public.med_stock_locations loc on loc.id = t.location_id
  left join public.delivery_receipts dr    on t.ref_kind = 'delivery_receipt' and dr.id = t.ref_id
  left join public.doctoring_events de     on t.ref_kind = 'doctoring_event'  and de.id = t.ref_id
  left join public.med_charges mc          on t.ref_kind = 'med_charge'       and mc.id = t.ref_id
  left join public.cost_centers cc         on cc.id = mc.cost_center_id
  left join public.lots l                  on l.id = coalesce(dr.lot_id, de.lot_id, mc.lot_id)
 where t.direction = '-1'::integer
   and t.txn_type = 'usage'::text;

comment on view public.med_usage_by_lot is
 'Medicine consumed, resolved to the lot it went into: a delivery receipt is processing, a doctoring event is treatment, a direct lot charge is the category chosen. A direct cost-centre charge has no lot, category cost_center, and carries the cost centre''s Profit Center / Production Center (account is always 130000 Vet & Medicine - WIP). Feeds the weekly Redwing medication application posting. Usage only.';

revoke all on public.lot_med_costs_by_category from anon;
revoke all on public.med_usage_by_lot from anon;
grant select on public.lot_med_costs_by_category to authenticated;
grant select on public.med_usage_by_lot to authenticated;

-- ---------------------------------------------------------------------
-- 6. Verify. Raises inside the transaction, so a failure leaves the
--    database as it was.
-- ---------------------------------------------------------------------
do $verify$
declare
    n       integer;
    bad     integer;
    v_view  numeric;
    v_src   numeric;
begin
    -- RLS on, four policies, none naming crew or a read predicate on a write.
    if not exists (select 1 from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
                    where ns.nspname = 'public' and c.relname = 'med_charges' and c.relrowsecurity) then
        raise exception 'RLS is not enabled on public.med_charges';
    end if;
    select count(*) into n from pg_policies where schemaname = 'public' and tablename = 'med_charges';
    if n <> 4 then
        raise exception 'public.med_charges has % policies, expected 4', n;
    end if;
    select count(*) into bad from pg_policies where schemaname = 'public' and tablename = 'med_charges'
       and (coalesce(qual, '') like '%crew%' or coalesce(with_check, '') like '%crew%');
    if bad > 0 then raise exception 'crew is named in a med_charges policy'; end if;
    select count(*) into bad from pg_policies where schemaname = 'public' and tablename = 'med_charges'
       and cmd <> 'SELECT'
       and (coalesce(qual, '') ~ 'accountant|can_read_' or coalesce(with_check, '') ~ 'accountant|can_read_');
    if bad > 0 then raise exception 'a read predicate reached a med_charges write policy'; end if;

    -- anon reaches nothing.
    if has_table_privilege('anon', 'public.med_charges', 'SELECT,INSERT,UPDATE,DELETE') then
        raise exception 'anon has a privilege on med_charges';
    end if;
    if has_table_privilege('anon', 'public.med_usage_by_lot', 'SELECT')
       or has_table_privilege('anon', 'public.lot_med_costs_by_category', 'SELECT') then
        raise exception 'anon can read a med cost view';
    end if;
    if has_function_privilege('anon', 'public.post_med_charge(date, uuid, uuid, numeric, text, uuid, uuid, text, text)', 'EXECUTE')
       or has_function_privilege('anon', 'public.delete_med_charge(uuid)', 'EXECUTE') then
        raise exception 'anon can execute a med charge function';
    end if;

    -- INVOKER, pinned search_path.
    select count(*) into bad from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('post_med_charge', 'delete_med_charge')
       and (p.prosecdef or p.proconfig is null or not (p.proconfig::text like '%search_path=%'));
    if bad > 0 then raise exception 'a med charge function is SECURITY DEFINER or lacks a pinned search_path'; end if;

    -- security_invoker on both views (CREATE OR REPLACE clears it silently
    -- when WITH is left off).
    select count(*) into bad from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'public' and c.relname in ('lot_med_costs_by_category', 'med_usage_by_lot')
       and not coalesce('security_invoker=true' = any (c.reloptions), false);
    if bad > 0 then raise exception 'a med cost view lacks security_invoker = true'; end if;

    -- One row per (lot, category), or the lot page reads half of it.
    select count(*) into bad from (
        select 1 from public.lot_med_costs_by_category group by lot_id, category having count(*) > 1) x;
    if bad > 0 then raise exception 'lot_med_costs_by_category has % duplicated (lot, category) row(s)', bad; end if;

    -- NOTHING MAY FALL OUT of the usage view, and nothing may double.
    select round(coalesce(sum(total_cost), 0), 2) into v_view from public.med_usage_by_lot;
    select round(coalesce(sum(total_cost), 0), 2) into v_src
      from public.med_txns where direction = -1 and txn_type = 'usage';
    if v_view <> v_src then
        raise exception 'med_usage_by_lot totals % and the ledger totals %', v_view, v_src;
    end if;
    select count(*) into bad from (
        select txn_id from public.med_usage_by_lot group by txn_id having count(*) > 1) x;
    if bad > 0 then raise exception '% usage row(s) appear more than once', bad; end if;

    raise notice 'VERIFIED: med_charges (RLS + 4 policies), post_med_charge / delete_med_charge INVOKER, both views security_invoker, usage view ties to the ledger at %.', v_src;
end
$verify$;

commit;
