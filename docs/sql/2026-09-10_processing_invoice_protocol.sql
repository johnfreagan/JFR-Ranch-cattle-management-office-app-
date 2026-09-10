-- 2026-09-10  Processing cost: the invoice's receiving protocol reaches the books.
--
-- The invoice form has carried a "Receiving protocol" picker, stored on
-- invoices.receiving_protocol_id, that nothing read. Processing cost is
-- derived from delivery_receipts x protocol only, so a lot whose protocol was
-- set on the invoice and not on each load out showed $0 processing (37X,
-- 37X-1, 37X-F on 2026-09-09).
--
-- A. Copy the invoice's protocol onto its receipts that have none. Open lots
--    only: 31-26 (closed 2026-08-13, FY2026) also qualifies for 1,766 head,
--    and re-pricing a closed lot in a closed fiscal year is a separate,
--    deliberate decision - see the commented statement at the end.
-- C. The two processing views price invoice head that never got a receipt
--    at the invoice's protocol. A receipt's own protocol, or its absence,
--    still wins for the head it covers; this only fills the gap (37X: 361 of
--    369 head have invoices and no receipt rows at all).
--
-- Idempotent: the UPDATE is guarded on NULL, the views are CREATE OR REPLACE.
-- Paste into the SQL editor WITHOUT the begin/commit lines.
begin;

-- ---- A. receipts take their invoice's protocol --------------------------
do $$
declare
    n_differ integer;
    n_done   integer;
begin
    select count(*) into n_differ
      from delivery_receipts r
      join invoices i on i.id = r.invoice_id
     where r.receiving_protocol_id is not null
       and i.receiving_protocol_id is not null
       and r.receiving_protocol_id <> i.receiving_protocol_id;
    raise notice 'receipts whose own protocol differs from the invoice (left alone): %', n_differ;

    update delivery_receipts r
       set receiving_protocol_id = i.receiving_protocol_id,
           notes = concat_ws(' ', nullif(r.notes, ''),
                             '[2026-09-10 receiving protocol copied from the invoice; the receipt had none]')
      from invoices i
      join lots l on l.id = i.lot_id
     where i.id = r.invoice_id
       and r.receiving_protocol_id is null
       and i.receiving_protocol_id is not null
       and l.closed_at is null;
    get diagnostics n_done = row_count;
    raise notice 'receipts given their invoice protocol: %', n_done;
end $$;

-- ---- C. the views: receipts first, invoice gap second --------------------
create or replace view public.lot_processing_costs
with (security_invoker = true) as
with lot_avg_wt as (
    select lot_id,
           sum(total_weight_lb) / nullif(sum(head_count), 0)::numeric as avg_wt
      from invoices
     where head_count > 0 and total_weight_lb > 0
     group by lot_id
), head_sources as (
    -- every load out that carries a protocol, as before
    select dr.id as source_id, 'receipt'::text as source_kind, dr.lot_id, dr.head_count,
           dr.receiving_protocol_id,
           coalesce(i.total_weight_lb / nullif(i.head_count, 0)::numeric, law.avg_wt) as est_wt
      from delivery_receipts dr
      left join invoices i on i.id = dr.invoice_id
      left join lot_avg_wt law on law.lot_id = dr.lot_id
     where dr.receiving_protocol_id is not null and dr.head_count > 0
    union all
    -- invoice head no receipt covers, at the invoice's protocol
    select i.id, 'invoice', i.lot_id,
           i.head_count - coalesce(rh.head, 0),
           i.receiving_protocol_id,
           coalesce(i.total_weight_lb / nullif(i.head_count, 0)::numeric, law.avg_wt)
      from invoices i
      left join (select invoice_id, sum(head_count) as head
                   from delivery_receipts group by invoice_id) rh on rh.invoice_id = i.id
      left join lot_avg_wt law on law.lot_id = i.lot_id
     where i.receiving_protocol_id is not null
       and i.head_count - coalesce(rh.head, 0) > 0
), med_lines as (
    select hs.lot_id, hs.source_id, hs.source_kind, hs.head_count, m.name as med_name,
           case coalesce(nullif(pm.override_dose_mode, ''), m.dose_mode)
               when 'flat' then coalesce(pm.override_flat_dose, m.flat_dose_amount)
               when 'per_weight' then
                   case
                       when hs.est_wt is null then null::numeric
                       when coalesce(m.round_up_to, 0) > 0
                           then ceil(hs.est_wt / coalesce(pm.override_per_weight_basis, m.per_weight_basis, 100)
                                     * coalesce(pm.override_per_weight_rate, m.per_weight_rate) / m.round_up_to) * m.round_up_to
                       else hs.est_wt / coalesce(pm.override_per_weight_basis, m.per_weight_basis, 100)
                            * coalesce(pm.override_per_weight_rate, m.per_weight_rate)
                   end
               else null::numeric
           end as dose_per_head,
           m.cost_per_unit, m.cost_per_head
      from head_sources hs
      join protocol_meds pm on pm.protocol_id = hs.receiving_protocol_id
      join medications m on m.id = pm.medication_id
), priced as (
    select lot_id, source_id, source_kind, head_count, med_name, dose_per_head,
           case
               when cost_per_unit is not null and dose_per_head is not null then dose_per_head * cost_per_unit
               when cost_per_head is not null then cost_per_head
               else null::numeric
           end as cost_per_head_line
      from med_lines
)
select p.lot_id,
       sum(p.cost_per_head_line * p.head_count::numeric)                    as total_cost,
       count(distinct p.source_id) filter (where p.source_kind = 'receipt') as receipt_count,
       count(*)                                                             as med_line_count,
       count(*) filter (where p.cost_per_head_line is null)                 as unpriced_line_count,
       (select coalesce(sum(s.head_count), 0) from head_sources s
         where s.lot_id = p.lot_id and s.source_kind = 'invoice')          as invoice_gap_head
  from priced p
 group by p.lot_id;

create or replace view public.lot_processing_cost_detail
with (security_invoker = true) as
with lot_avg_wt as (
    select lot_id,
           sum(total_weight_lb) / nullif(sum(head_count), 0)::numeric as avg_wt
      from invoices
     where head_count > 0 and total_weight_lb > 0
     group by lot_id
), head_sources as (
    select dr.id as source_id, dr.lot_id, dr.head_count, dr.receiving_protocol_id,
           coalesce(i.total_weight_lb / nullif(i.head_count, 0)::numeric, law.avg_wt) as est_wt
      from delivery_receipts dr
      left join invoices i on i.id = dr.invoice_id
      left join lot_avg_wt law on law.lot_id = dr.lot_id
     where dr.receiving_protocol_id is not null and dr.head_count > 0
    union all
    select i.id, i.lot_id,
           i.head_count - coalesce(rh.head, 0),
           i.receiving_protocol_id,
           coalesce(i.total_weight_lb / nullif(i.head_count, 0)::numeric, law.avg_wt)
      from invoices i
      left join (select invoice_id, sum(head_count) as head
                   from delivery_receipts group by invoice_id) rh on rh.invoice_id = i.id
      left join lot_avg_wt law on law.lot_id = i.lot_id
     where i.receiving_protocol_id is not null
       and i.head_count - coalesce(rh.head, 0) > 0
), med_lines as (
    select hs.lot_id, hs.head_count, pm.medication_id, m.name as med_name,
           min(pm.sort_order) over (partition by hs.lot_id, pm.medication_id) as sort_order,
           case coalesce(nullif(pm.override_dose_mode, ''), m.dose_mode)
               when 'flat' then coalesce(pm.override_flat_dose, m.flat_dose_amount)
               when 'per_weight' then
                   case
                       when hs.est_wt is null then null::numeric
                       when coalesce(m.round_up_to, 0) > 0
                           then ceil(hs.est_wt / coalesce(pm.override_per_weight_basis, m.per_weight_basis, 100)
                                     * coalesce(pm.override_per_weight_rate, m.per_weight_rate) / m.round_up_to) * m.round_up_to
                       else hs.est_wt / coalesce(pm.override_per_weight_basis, m.per_weight_basis, 100)
                            * coalesce(pm.override_per_weight_rate, m.per_weight_rate)
                   end
               else null::numeric
           end as dose_per_head,
           m.cost_per_unit, m.cost_per_head, m.bottle_size_unit
      from head_sources hs
      join protocol_meds pm on pm.protocol_id = hs.receiving_protocol_id
      join medications m on m.id = pm.medication_id
), priced as (
    select lot_id, head_count, medication_id, med_name, sort_order, dose_per_head,
           cost_per_unit, cost_per_head, bottle_size_unit,
           case
               when cost_per_unit is not null and dose_per_head is not null then dose_per_head * cost_per_unit
               when cost_per_head is not null then cost_per_head
               else null::numeric
           end as cost_per_head_line
      from med_lines
)
select lot_id, medication_id, med_name,
       min(sort_order)                                   as sort_order,
       sum(head_count)                                   as head_treated,
       sum(dose_per_head * head_count::numeric)
           / nullif(sum(head_count) filter (where dose_per_head is not null), 0)::numeric as avg_dose,
       max(bottle_size_unit)                             as dose_unit,
       max(cost_per_unit)                                as cost_per_unit,
       sum(cost_per_head_line * head_count::numeric)
           / nullif(sum(head_count) filter (where cost_per_head_line is not null), 0)::numeric as avg_cost_per_head,
       sum(cost_per_head_line * head_count::numeric)     as total_cost,
       bool_or(cost_per_head_line is null)               as has_unpriced
  from priced
 group by lot_id, medication_id, med_name;

-- ---- verify ---------------------------------------------------------------
do $$
declare
    n_bad   integer;
    v_total numeric;
    v_gap   bigint;
    v_unpr  bigint;
begin
    select count(*) into n_bad
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname in ('lot_processing_costs', 'lot_processing_cost_detail')
       and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=true%';
    if n_bad > 0 then
        raise exception 'a processing view is missing security_invoker = true';
    end if;

    select p.total_cost, p.invoice_gap_head, p.unpriced_line_count
      into v_total, v_gap, v_unpr
      from lot_processing_costs p join lots l on l.id = p.lot_id
     where l.lot_number = '37X';
    raise notice '37X processing: total % on % invoice-only head, % unpriced lines (Protivity until it is priced)', v_total, v_gap, v_unpr;
    if v_gap is distinct from 361 then
        raise exception '37X invoice-only head expected 361, got %', v_gap;
    end if;
end $$;

commit;

-- 31-26 (closed, FY2026): run ONLY if the decision is to re-price a closed lot.
-- update delivery_receipts r
--    set receiving_protocol_id = i.receiving_protocol_id,
--        notes = concat_ws(' ', nullif(r.notes, ''), '[2026-09-10 receiving protocol copied from the invoice; closed lot, by decision]')
--   from invoices i join lots l on l.id = i.lot_id
--  where i.id = r.invoice_id and r.receiving_protocol_id is null
--    and i.receiving_protocol_id is not null and l.lot_number = '31-26';
