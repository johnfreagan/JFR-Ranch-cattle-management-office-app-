-- =====================================================================
-- med_usage_by_lot: what medicine went into which cattle, and when.
-- =====================================================================
-- 2026-10-03. John: "We need a medication usage report in the inventory
-- section for redwing similar to the feed application report for feeds.
-- We will probably run and enter on mondays similar to feeds."
--
-- The feed side already has this shape: a date range, a block a lot, and
-- Copy rows so the posting is paste rather than retype. Medicine had the
-- ledger but nothing that answered "which lot" - med_txns carries a
-- ref_kind and a ref_id and stops there.
--
-- This view resolves that reference to a lot, which is the whole trick:
--
--   ref_kind 'delivery_receipt' -> delivery_receipts.lot_id -> PROCESSING
--   ref_kind 'doctoring_event'  -> doctoring_events.lot_id  -> TREATMENT
--
-- The category comes off the REFERENCE rather than off med_txns.reason,
-- and that is deliberate. A reason is free text somebody typed; the
-- reference is what the row is actually attached to, and the two must not
-- be able to disagree about whether a bottle was processing or doctoring.
--
-- Usage with neither reference resolves to a NULL lot and keeps its own
-- reason as the category. It is real usage and must not vanish from a
-- posting - the report lists it under its own heading so somebody sees it
-- rather than a total that quietly fails to add up.
--
-- direction = -1 and txn_type = 'usage' only. A transfer between pools is
-- an adjustment, not usage: the drug has not gone into cattle yet, and
-- posting it to Redwing as consumption would charge it twice when it is
-- finally used.
--
-- cost_provisional and shortfall_units ride along, because an unpriced
-- draw reads as $0 and the dollars beside it are SHORT. The report has to
-- say so where whoever is typing into Redwing can see it.
-- =====================================================================

begin;

create or replace view public.med_usage_by_lot
with (security_invoker = true) as
select t.id                                   as txn_id,
       t.txn_date,
       t.fiscal_year,
       coalesce(dr.lot_id, de.lot_id)         as lot_id,
       l.lot_number,
       t.ref_kind,
       case t.ref_kind
            when 'delivery_receipt' then 'processing'
            when 'doctoring_event'  then 'treatment'
            else coalesce(t.reason, 'other')
       end                                    as category,
       t.medication_id,
       m.name                                 as medication_name,
       m.generic_category,
       m.redwing_item_code,
       coalesce(m.bottle_size_unit, 'mL')     as unit,
       m.bottle_size,
       t.qty_units,
       t.total_cost,
       t.shortfall_units,
       t.cost_provisional,
       t.location_id,
       loc.name                               as location_name
  from med_txns t
  join medications m             on m.id = t.medication_id
  left join med_stock_locations loc on loc.id = t.location_id
  left join delivery_receipts dr on t.ref_kind = 'delivery_receipt' and dr.id = t.ref_id
  left join doctoring_events de  on t.ref_kind = 'doctoring_event'  and de.id = t.ref_id
  left join lots l               on l.id = coalesce(dr.lot_id, de.lot_id)
 where t.direction = -1
   and t.txn_type = 'usage';

comment on view public.med_usage_by_lot is
 'Medicine consumed, resolved to the lot it went into: a delivery receipt is processing, a doctoring event is treatment. Feeds the weekly Redwing medication application posting. Usage only - transfers and count adjustments are not consumption.';

-- ---- verify ---------------------------------------------------------------
do $verify$
declare n integer; v_view numeric; v_src numeric;
begin
    select count(*) into n
      from pg_class c join pg_namespace nn on nn.oid = c.relnamespace
     where nn.nspname = 'public' and c.relname = 'med_usage_by_lot'
       and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=true%';
    if n > 0 then raise exception 'med_usage_by_lot is missing security_invoker = true'; end if;

    if has_table_privilege('anon', 'public.med_usage_by_lot', 'SELECT') then
        raise exception 'anon can read med_usage_by_lot';
    end if;

    -- NOTHING MAY FALL OUT. Every usage row in the ledger has to appear
    -- here exactly once, lot or no lot, or a posting reads light and
    -- nobody can tell by looking.
    select count(*), round(coalesce(sum(total_cost), 0), 2) into n, v_view
      from public.med_usage_by_lot;
    select round(coalesce(sum(total_cost), 0), 2) into v_src
      from public.med_txns where direction = -1 and txn_type = 'usage';
    if v_view <> v_src then
        raise exception 'the view totals % and the ledger totals % - usage is being lost or doubled', v_view, v_src;
    end if;

    select count(*) into n from public.med_txns
     where direction = -1 and txn_type = 'usage'
       and id not in (select txn_id from public.med_usage_by_lot);
    if n > 0 then raise exception '% usage row(s) do not appear in the view', n; end if;

    -- a usage row must not multiply: one ledger row, one view row
    select count(*) into n from (
        select txn_id from public.med_usage_by_lot group by txn_id having count(*) > 1) x;
    if n > 0 then raise exception '% usage row(s) appear more than once', n; end if;

    raise notice 'VERIFIED: med_usage_by_lot carries every usage row once, % in total.', v_src;
end
$verify$;

commit;
