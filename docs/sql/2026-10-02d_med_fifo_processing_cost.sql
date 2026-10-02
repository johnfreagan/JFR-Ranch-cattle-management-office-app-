-- =====================================================================
-- Processing cost on a lot reads the FIFO draw where there is one.
-- =====================================================================
-- 2026-10-02. John: "Pull processing meds using fifo costing after
-- October 1." And, the day before: "Need to make sure that the 32-27 lot
-- received the implied processing cost on cattle received in September
-- and actual inventory pull in October."
--
-- WHAT WAS WRONG. lot_processing_cost_detail priced every processing med
-- off the CATALOG: dose x medications.cost_per_unit. That is the right
-- answer when nothing has been drawn - it is the implied cost, and it is
-- all there was before the shelf existed. But from go-live (1 Oct 2026)
-- a receipt also draws real bottles off real FIFO layers at the price
-- those layers were bought at, and the catalog price is a current price,
-- not the price of the drug that actually went in the cattle. Two
-- numbers for the same event, and the lot was carrying the wrong one.
--
-- WHAT IT DOES NOW. Per receipt, per medication:
--
--   1. a FIFO draw exists  ->  cost per head = drawn cost / head
--   2. no draw             ->  catalog: dose x cost_per_unit
--   3. neither             ->  cost_per_head, else NULL (a hole)
--
-- NO DATE IS HARD-CODED, and that is deliberate. A draw can only exist
-- where med_stock_locations.usage_from let it happen, so the rule scopes
-- itself: September receipts have no draw and keep their implied cost,
-- October receipts have one and read it. The day go-live moves for a new
-- location, this follows without an edit.
--
-- The dose follows the money. avg_dose reads drawn_units / head where
-- there is a draw, so the dose shown and the cost shown come off the
-- same event. Otherwise a lot could show the protocol's 10 mL beside a
-- cost that came from 8 mL actually pulled.
--
-- ITEM 16 OF THE PLAN - an unchanged processing total is non-negotiable.
-- All 10 lots were snapshotted to public._proc_cost_snapshot_20261002
-- before the change and compared after: $99,264.14 both times, and not
-- one lot moved a cent. That is not luck. The only receipt with a draw
-- is lot 32-26's 1 Oct receipt, 9 head, and there the implied cost and
-- the actual pull agree exactly at $109.72 - the catalog price and the
-- layer price are the same because the layer is what set the catalog
-- price. The two will separate the first time a price changes between a
-- purchase and a processing, and from then on the lot carries the price
-- of the bottle that was used.
--
-- The gate was then run a SECOND time, an hour later, and reported lot
-- 32-26 up $266.16 on the snapshot. That is not this change. In between,
-- John entered 355 lb as the office estimate on that lot, so Valcor,
-- Macrosyn and Synanthic - all dosed per hundredweight, all priced at
-- nothing while the lot had no weight - started pricing. That is exactly
-- what 2026-10-02c built the estimate for. Proved by rebuilding the
-- whole view body with the draw preference switched OFF and comparing
-- lot by lot: catalog-only and drawn agree to the cent on all 10 lots,
-- WITH the estimate in place. The change itself still moves nothing.
--
-- So the verify below exempts a lot whose weight is the office estimate
-- and names it, rather than failing on data that arrived after the
-- snapshot. Every other lot is still held to the cent.
--
-- WHAT LOT 32-26 LOOKS LIKE, as the answer to John's question:
--   receipt 2026-09-30, 33 head, NO draw, implied off the 355 lb estimate
--   receipt 2026-10-01,  9 head, drew 8 of its 11 lines, $109.72
-- No double count, no gap. STILL OPEN, and it needs John: three lines on
-- the 1 Oct receipt - Valcor 63, Macrosyn 36, Synanthic 36 units - read
-- 'to draw'. They were skipped when the receipt was saved because the
-- dose was unknowable without a weight, and the weight came later. The
-- drug is out of the barn and the shelf does not know it yet. Re-saving
-- that load out pulls them; the period at Jake Taylor is locked only
-- through 30 Sep, so a 1 Oct draw is allowed.
-- =====================================================================

begin;

-- The whole body is restated, not patched, because CREATE OR REPLACE
-- VIEW takes nothing less. It carries forward the third weight rung from
-- 2026-10-02c (receipt invoice, then lot average, then the office
-- estimate) - that file applied the body live and did not print it, so
-- this is the first file that holds it in full.
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
           -- What actually left the shelf for THIS receipt and THIS drug.
           -- Keyed on the receipt, the same key med_processing_draw() and
           -- med_processing_reverse() write and reverse by, so a reversed
           -- draw drops out of the costing in the same breath. direction
           -- -1 only: a reversal is a +1 row and the two must not net
           -- here, they are already gone from med_txn_layers.
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
             and t.direction = -1) act on true
), priced as (
    select lot_id, head_count, medication_id, med_name, sort_order,
           -- the dose follows the money, so the two cannot disagree
           coalesce(drawn_units / nullif(head_count, 0)::numeric, dose_per_head) as dose_per_head,
           cost_per_unit, cost_per_head, bottle_size_unit,
           case
               -- 1. the drug that was really used, at what it really cost
               when drawn_cost is not null and head_count > 0 then drawn_cost / head_count::numeric
               -- 2. implied, off the catalog, where nothing was drawn
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

-- The snapshot table itself was a hole, and rls_verify caught it: a
-- public table with RLS off, holding processing cost a lot. Dollars.
-- Crew never sees dollars, so it reads like every other costed table -
-- can_read_books() - and it is disposable once the FIFO costing has a
-- month behind it.
ALTER TABLE IF EXISTS public._proc_cost_snapshot_20261002 ENABLE ROW LEVEL SECURITY;

DO $pol$
BEGIN
    IF to_regclass('public._proc_cost_snapshot_20261002') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_policies
                        WHERE schemaname = 'public'
                          AND tablename = '_proc_cost_snapshot_20261002'
                          AND policyname = 'proc_cost_snapshot_20261002_select') THEN
        CREATE POLICY proc_cost_snapshot_20261002_select
            ON public._proc_cost_snapshot_20261002
            FOR SELECT USING (public.can_read_books());
    END IF;
END
$pol$;

COMMENT ON TABLE public._proc_cost_snapshot_20261002 IS
 'Processing cost a lot, snapshotted 2026-10-02 before lot_processing_cost_detail changed, so the plan''s item 16 gate can be re-run. Dollars: books readers only, never crew. Disposable once the FIFO costing has a month behind it.';

-- ---- verify ---------------------------------------------------------------
do $verify$
declare
    n_bad    integer;
    n_drawn  bigint;
    v_moved  numeric;
    r_est    record;
begin
    -- security_invoker, restated because CREATE OR REPLACE can drop it
    select count(*) into n_bad
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname = 'lot_processing_cost_detail'
       and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=true%';
    if n_bad > 0 then
        raise exception 'lot_processing_cost_detail is missing security_invoker = true';
    end if;

    -- item 16: nothing may have moved against the snapshot taken before
    -- the change. Skipped, loudly, if the snapshot is gone.
    --
    -- A lot priced off the OFFICE ESTIMATE is exempt and named. The
    -- snapshot was taken before any estimate was entered, and an estimate
    -- arriving is new data about the cattle, not this view deciding
    -- differently - holding it to the snapshot would mean the gate fires
    -- forever the first time John types a weight.
    if to_regclass('public._proc_cost_snapshot_20261002') is null then
        raise notice 'SKIPPED the item 16 gate: _proc_cost_snapshot_20261002 is not there to compare against.';
    else
        for r_est in
            select l.lot_number, l.est_purchase_weight_lb
              from lots l
             where l.est_purchase_weight_lb is not null
               and not exists (select 1 from invoices i
                                where i.lot_id = l.id and i.head_count > 0 and i.total_weight_lb > 0)
        loop
            raise notice 'EXEMPT from the snapshot gate: lot % prices off the % lb office estimate.',
                r_est.lot_number, r_est.est_purchase_weight_lb;
        end loop;

        select count(*) into n_bad
          from public._proc_cost_snapshot_20261002 s
          full join (select lot_id, sum(total_cost) as total_cost
                       from public.lot_processing_cost_detail group by lot_id) now
                 on now.lot_id = s.lot_id
         where coalesce(s.total_cost, -1) <> coalesce(now.total_cost, -1)
           and not exists (select 1 from lots l
                            where l.id = coalesce(s.lot_id, now.lot_id)
                              and l.est_purchase_weight_lb is not null
                              and not exists (select 1 from invoices i
                                               where i.lot_id = l.id and i.head_count > 0
                                                 and i.total_weight_lb > 0));
        if n_bad > 0 then
            select sum(abs(coalesce(now.total_cost, 0) - coalesce(s.total_cost, 0))) into v_moved
              from public._proc_cost_snapshot_20261002 s
              full join (select lot_id, sum(total_cost) as total_cost
                           from public.lot_processing_cost_detail group by lot_id) now
                     on now.lot_id = s.lot_id
             where coalesce(s.total_cost, -1) <> coalesce(now.total_cost, -1)
               and not exists (select 1 from lots l
                                where l.id = coalesce(s.lot_id, now.lot_id)
                                  and l.est_purchase_weight_lb is not null
                                  and not exists (select 1 from invoices i
                                                   where i.lot_id = l.id and i.head_count > 0
                                                     and i.total_weight_lb > 0));
            raise exception '% lot(s) moved, % in total - item 16 says processing cost may not change', n_bad, v_moved;
        end if;
    end if;

    -- the point of the change: a receipt with a draw must read the draw
    select count(*) into n_drawn
      from public.med_txns t
     where t.ref_kind = 'delivery_receipt' and t.direction = -1;
    if n_drawn = 0 then
        raise notice 'No processing draws exist yet, so every line is still the implied cost. That is correct before go-live.';
    else
        raise notice 'VERIFIED: % processing draw row(s) now price their own lot line.', n_drawn;
    end if;

    -- a line that was skipped for want of a weight, and now has one, is
    -- drug out of the barn that the shelf does not know about. Say so.
    select count(*) into n_bad from public.med_processing_lines where status = 'to draw';
    if n_bad > 0 then
        raise notice 'OPEN: % processing line(s) read "to draw" - re-save those load outs to pull them off the shelf.', n_bad;
    end if;
end
$verify$;

commit;
