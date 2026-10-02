-- =====================================================================
-- A draw that knows no price must not wipe out the one we have.
-- =====================================================================
-- APPLIED 2026-10-02. Found while checking Synovex Primer, which John
-- had just set aside: "No primer on hand so cost and size will be
-- updated if we buy more, ignore for now."
--
-- FIRST, A CORRECTION TO THE RECORD. Primer was described in this chain
-- as drawing at $0 and leaving holes on 61 receipts. That was wrong.
-- Primer carries **cost_per_head = $2.02** and the lots are charged it:
--
--   37X    369 hd   $745.38        59X    241 hd   $486.82
--   37X-1  274 hd   $553.48        60X    251 hd   $507.02
--   37X-F  316 hd   $638.32        47-26  187 hd   $377.74
--
-- $3,308.76 across the six live lots, none of it unpriced. What Primer
-- is actually missing is **bottle_size**, which is a SHELF problem and
-- not a cost problem: with no container size it cannot be counted in
-- bottles and med_on_hand flags needs_container_size. Setting it aside
-- until the next purchase is therefore fine, and that is where it is.
--
-- THE BUG THAT FELL OUT OF LOOKING. 2026-10-02d made a lot's processing
-- cost prefer the ACTUAL FIFO draw over the catalog, which is right. But
-- it preferred ANY draw, and med_consume writes a draw even when nothing
-- on the shelf and nothing in the catalog can price it - that is the
-- deliberate fail-soft: a treatment that happened must not be lost to a
-- bookkeeping gap, so it books at zero and raises cost_provisional.
--
-- Put those two together on Primer, with no stock and no per-UNIT price,
-- and the next load out on either of its two active protocols would have
-- written a provisional draw of $0 - and the costing would have
-- PREFERRED that zero over the $2.02 a head the catalog holds. A real
-- charge silently replaced by nothing, on every lot processed from here.
-- drawn_cost would be 0, which is not NULL, so the first branch wins.
--
-- The fix is one condition: the lateral ignores provisional draws.
--
--     and not t.cost_provisional
--
-- A draw that knows what it cost still wins, including an uncovered one
-- priced off the last layer we knew - that figure is real. Only a draw
-- carrying NO price at all falls back to the catalog, which is the whole
-- point of the catalog.
--
-- PROVED, with a test that rolled itself back: a provisional, uncovered
-- 10-unit Primer draw inserted against 37X's receipt left its Primer at
-- **$2.0200 a head before and $2.0200 after**. Without this condition it
-- would have read $0.0000.
--
-- Nothing on the place is affected today - zero provisional draws exist -
-- so this is a trap closed before it sprang. Item 16 gate: $99,530.31
-- before and after, lot 32-26 $778.17 before and after.
-- =====================================================================

begin;

-- The body is restated in full because CREATE OR REPLACE VIEW takes
-- nothing less; the only change from 2026-10-02d is the one condition in
-- the act lateral, marked below.
create or replace view public.lot_processing_cost_detail
with (security_invoker = true) as
with lot_avg_wt as (
    select l.id as lot_id,
           coalesce(
               (select sum(iv.total_weight_lb) / nullif(sum(iv.head_count), 0)::numeric
                  from invoices iv
                 where iv.lot_id = l.id and iv.head_count > 0 and iv.total_weight_lb > 0),
               l.est_purchase_weight_lb) as avg_wt
      from lots l
), head_sources as (
    select dr.id as source_id, dr.lot_id, dr.head_count, dr.receiving_protocol_id,
           coalesce(i.total_weight_lb / nullif(i.head_count, 0)::numeric, law.avg_wt) as est_wt
      from delivery_receipts dr
      left join invoices i on i.id = dr.invoice_id
      left join lot_avg_wt law on law.lot_id = dr.lot_id
     where dr.receiving_protocol_id is not null and dr.head_count > 0
    union all
    select i.id, i.lot_id,
           (i.head_count - coalesce(rh.head, 0))::integer,   -- keep the column integer; sum() must stay bigint
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
           m.cost_per_unit, m.cost_per_head, m.bottle_size_unit,
           act.drawn_cost, act.drawn_units
      from head_sources hs
      join protocol_meds pm on pm.protocol_id = hs.receiving_protocol_id
      join medications m on m.id = pm.medication_id
      left join lateral (
          select sum(t.total_cost) as drawn_cost, sum(t.qty_units) as drawn_units
            from med_txns t
           where t.ref_kind = 'delivery_receipt'
             and t.ref_id = hs.source_id
             and t.medication_id = pm.medication_id
             and t.direction = -1
             -- THE FIX. A provisional draw is one med_consume could not
             -- price at all: no layer, no catalog figure. It books at
             -- zero so the treatment is not lost, and zero is a number
             -- people believe. Preferring it would replace a real
             -- cost_per_head with nothing.
             and not t.cost_provisional) act on true
), priced as (
    select lot_id, head_count, medication_id, med_name, sort_order,
           -- the dose follows the money, so the two cannot disagree
           coalesce(drawn_units / nullif(head_count, 0)::numeric, dose_per_head) as dose_per_head,
           cost_per_unit, cost_per_head, bottle_size_unit,
           case
               -- 1. the drug that was really used, at what it really cost
               when drawn_cost is not null and head_count > 0 then drawn_cost / head_count::numeric
               -- 2. implied, off the catalog, where nothing priced was drawn
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
do $verify$
declare
    n       integer;
    v_prim  numeric;
begin
    select count(*) into n
      from pg_class c join pg_namespace nn on nn.oid = c.relnamespace
     where nn.nspname = 'public' and c.relname = 'lot_processing_cost_detail'
       and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=true%';
    if n > 0 then raise exception 'lot_processing_cost_detail is missing security_invoker = true'; end if;

    -- the condition is really in the deployed body
    if position('cost_provisional' in pg_get_viewdef('public.lot_processing_cost_detail'::regclass, true)) = 0 then
        raise exception 'the deployed view does not exclude provisional draws';
    end if;

    -- the card and the report still agree, lot by lot
    select count(*) into n
      from public.lot_processing_costs c
      full join (select lot_id, sum(total_cost) as total_cost
                   from public.lot_processing_cost_detail group by lot_id) d on d.lot_id = c.lot_id
     where round(coalesce(c.total_cost, -1), 6) <> round(coalesce(d.total_cost, -1), 6);
    if n > 0 then raise exception '% lot(s) read a different total on the card than in the report', n; end if;

    -- Primer still charges what the catalog says
    select round(avg_cost_per_head, 4) into v_prim
      from public.lot_processing_cost_detail d join public.lots l on l.id = d.lot_id
     where l.lot_number = '37X' and d.med_name = 'Synovex Primer';
    if v_prim <> 2.02 then
        raise exception '37X reads % a head for Primer, not the catalog 2.02', v_prim;
    end if;

    raise notice 'VERIFIED: an unpriced draw no longer overrides the catalog. Primer still charges $2.02 a head.';
end
$verify$;

commit;
