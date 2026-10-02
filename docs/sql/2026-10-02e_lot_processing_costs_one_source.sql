-- =====================================================================
-- The lot card and the processing report read ONE costing. (Proposed.)
-- =====================================================================
-- STATUS: APPLIED 2026-10-02 on John's go-ahead. It moved exactly one
-- lot, which is what was measured beforehand: 32-26 from $512.01 to
-- $778.17 on the lot card and in the closeout. The other nine lots came
-- back identical to the cent. Processing across the place: $99,264.14 ->
-- $99,530.31, all of it that one lot. The file's body was re-applied
-- afterwards and md5s identical to the deployed view, 709b3873.
-- rls_verify: PASS.
--
-- WHAT IS WRONG. There are two views, and each carries its OWN private
-- copy of the whole processing-cost calculation:
--
--   lot_processing_costs        one row a lot    -> the LOT CARD
--                                                   (Proc $/hd) and the
--                                                   closeout
--   lot_processing_cost_detail  one row a med    -> the Processing Cost
--                                                   report and the lot
--                                                   drilldown
--
-- Both were written in 2026-09-10 from the same text. Since then the
-- detail got two changes and the summary got neither:
--
--   2026-10-02c  the office weight estimate as the third weight rung
--   2026-10-02d  the FIFO draw preferred over the catalog price
--
-- So the card has been reading a calculation that is three weeks stale.
-- On lot 32-26 that is the difference between $512.01 and $778.17 -
-- $266.16, which is Valcor, Macrosyn and Synanthic dosed off John's
-- 355 lb estimate. The report shows one number and the card shows the
-- other, on the same screen, and the card is the one the closeout uses.
--
-- WHY IT HAPPENED, and the real fix. Duplicated maths drifts. It is the
-- same lesson as the processing DRAW, which deliberately shares its dose
-- expression with the costing view so the shelf and the closeout cannot
-- disagree. The summary does not need its own copy of anything: it is
-- the detail, added up.
--
-- So lot_processing_costs becomes an aggregate OVER
-- lot_processing_cost_detail. One costing, two shapes. A change to the
-- rungs or to the draw preference now reaches both by construction, and
-- there is no second place to forget.
--
-- BLAST RADIUS, measured before writing this:
--
--   lot      card now    detail now    moves
--   32-26      512.01        778.17   +266.16
--   every other lot (9)  identical to the cent, 0.00
--
-- WHAT CHANGES MEANING. Nothing the app reads. The column list and its
-- order are untouched, because CREATE OR REPLACE takes nothing less.
--   total_cost            same definition, now from one place
--   receipt_count         same: receipts with a protocol and head
--   med_line_count        was one a (source x med), now one a (lot x med)
--                         - 22 becomes 11 on 32-26. NOTHING READS IT.
--   unpriced_line_count   same, counted a (lot x med) for the same
--                         reason. The app uses it as "are there holes",
--                         and it still answers that. 6 becomes 3 on
--                         32-26: the three per-cwt meds, not six
--                         receipt-lines of them.
--   invoice_gap_head      same: invoice head no load out covers
-- =====================================================================

begin;

create or replace view public.lot_processing_costs
with (security_invoker = true) as
select d.lot_id,
       sum(d.total_cost)                                  as total_cost,
       -- Structural, not money: how many load outs on this lot carry a
       -- receiving protocol. Read straight off the receipts, which is
       -- what the old private copy counted.
       (select count(*) from delivery_receipts dr
         where dr.lot_id = d.lot_id
           and dr.receiving_protocol_id is not null
           and dr.head_count > 0)                         as receipt_count,
       count(*)                                           as med_line_count,
       count(*) filter (where d.has_unpriced)             as unpriced_line_count,
       -- Invoice head that no load out covers. Those head are priced off
       -- the INVOICE's protocol, and the tile says so out loud - 37X had
       -- 361 of 369 head on invoices with no receipt rows at all.
       -- The cast is load-bearing: head_count - bigint is bigint, and
       -- sum(bigint) is NUMERIC, which CREATE OR REPLACE refuses because
       -- the column was bigint ("cannot change data type of view
       -- column"). Summing the integer keeps it bigint.
       (select coalesce(sum((i.head_count - coalesce(rh.head, 0))::integer), 0)
          from invoices i
          left join (select invoice_id, sum(head_count) as head
                       from delivery_receipts group by invoice_id) rh
                 on rh.invoice_id = i.id
         where i.lot_id = d.lot_id
           and i.receiving_protocol_id is not null
           and i.head_count - coalesce(rh.head, 0) > 0)   as invoice_gap_head
  from public.lot_processing_cost_detail d
 group by d.lot_id;

-- ---- verify ---------------------------------------------------------------
do $verify$
declare
    n_bad   integer;
    r       record;
    v_sum   numeric;
begin
    -- security_invoker, restated because CREATE OR REPLACE can drop it
    select count(*) into n_bad
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname in ('lot_processing_costs', 'lot_processing_cost_detail')
       and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=true%';
    if n_bad > 0 then
        raise exception 'a processing view is missing security_invoker = true';
    end if;

    -- the whole point: the card and the report cannot disagree any more
    select count(*) into n_bad
      from public.lot_processing_costs c
      full join (select lot_id, sum(total_cost) as total_cost
                   from public.lot_processing_cost_detail group by lot_id) d
             on d.lot_id = c.lot_id
     where round(coalesce(c.total_cost, -1), 6) <> round(coalesce(d.total_cost, -1), 6);
    if n_bad > 0 then
        raise exception '% lot(s) still read a different total on the card than in the report', n_bad;
    end if;

    -- and the move is the one that was measured, on the one lot
    for r in
        select l.lot_number, round(c.total_cost, 2) as total_cost
          from public.lot_processing_costs c join lots l on l.id = c.lot_id
         where l.lot_number = '32-26'
    loop
        raise notice 'lot % now reads % on the card, the same as the report.', r.lot_number, r.total_cost;
    end loop;

    select round(sum(total_cost), 2) into v_sum from public.lot_processing_costs;
    raise notice 'VERIFIED: one costing, two shapes. Processing across every lot: %.', v_sum;
end
$verify$;

commit;
