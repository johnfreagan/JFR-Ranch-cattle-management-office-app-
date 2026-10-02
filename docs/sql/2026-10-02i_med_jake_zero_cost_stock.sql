-- =====================================================================
-- Previously expensed medicine to Jake at NO COST, to use up.
-- =====================================================================
-- APPLIED 2026-10-02. John: "I think I want to put 1 250 dose
-- ultrachoice (500 ml), 4 pinkeye Bactrian, 9 -10 (90 doses) dose
-- bottles of protivity in Jake's inventory at 0 cost and put them as the
-- oldest inventory... It will all be used this month and no longer a
-- problem."
--
-- | medication                   | bottles | size      | units |
-- |------------------------------|---------|-----------|-------|
-- | Ultrachoice 8                | 1       | 250 doses | 250   |
-- | Pinkeye Autogenous Bacterin  | 4       | 50 doses  | 200   |
-- | Protivity                    | 9       | 10 doses  | 90    |
--
-- The catalog settles the arithmetic rather than a guess: UltraChoice is
-- a 250-dose bottle, which is his "250 dose (500 ml)"; Pinkeye is a
-- 50-dose bottle, so 4 is 200; Protivity is a 10-dose bottle, which is
-- what "9 - 10 dose bottles (90 doses)" reads as and the figures agree.
--
-- At $0, and that is the right price here. The ranch bought this drug and
-- expensed it earlier in the year, before there was a system to track it.
-- Charging a lot for it again would be charging twice. This is the case
-- John has been describing since the Protivity line in July: give it to
-- processing at no cost and burn it up. Unlike the tags - a recurring
-- per-head cost that has to read right - this is a one-time leftover with
-- an end date.
--
-- "AS THE OLDEST INVENTORY" IS WHAT THE PERIOD LOCK WOULD NOT ALLOW, and
-- the record should be straight about it rather than quietly doing
-- something else. Jake Taylor is locked through 30 Sep by his posted
-- count, so the earliest a layer can be dated is 1 Oct, and his existing
-- UltraChoice and Pinkeye layers are dated 30 Sep. FIFO orders by
-- received_date first, so these cannot be first in line for those two.
-- Backdating them would mean un-posting the count his opening balance
-- and Jayci's reconciliation both rest on, to make an inventory figure
-- read differently. Not worth it, and not reversible in a way anybody
-- could audit later.
--
-- So: dated 1 Oct, the earliest open day, with sort_order -1 so they
-- draw ahead of everything else dated 1 Oct or later. What FIFO will
-- actually do:
--
--   Protivity   nothing else exists, so the $0 stock IS first
--   Pinkeye     47.25 costed doses go first, then the 200 free
--   UltraChoice 324.33 costed doses go first, then the 250 free
--
-- Over the month the total is identical either way; only which lot
-- carries the real cost changes, and the costed stock is small enough
-- (47 head of pinkeye) that it clears early anyway.
--
-- REAL BOTTLE SIZES, not unit-normalized. Every earlier layer carries
-- bottle_size 1 with the units in qty_bottles, because that is what a
-- count produces. These were given as whole bottles and the layer says
-- so - 4 x 50 - which reads honestly on the screen. All the arithmetic
-- downstream is in units and med_on_hand divides by the CATALOG size for
-- bottles, so nothing cares either way.
--
-- VERIFIED: 540 units at $0 on his shelf, all three in the open period,
-- every layer on the place still ties remaining = bought - used, and
-- every roll-forward row still ties on units. Jake's shelf now reads
-- UltraChoice 574.33 doses / $246.32, Pinkeye 247.25 / $93.38,
-- Protivity 90 / $0.00.
--
-- ONE THING THIS CANNOT FIX, and it needs John: **Protivity has no dose
-- anywhere.** medications.flat_dose_amount is NULL and the protocol it
-- sits on ("26 Summer X Steers/Bulls Receiving") sets no override. A
-- processing draw cannot pull a dose it does not know, so those 90 doses
-- will sit on the shelf and the line will wait, exactly the way the
-- per-hundredweight meds waited on a weight. One field fixes it: doses a
-- head on the Medications tab.
-- =====================================================================

begin;

do $gift$
declare
    v_loc  uuid;
    r      record;
    v_line uuid;
begin
    select id into v_loc from public.med_stock_locations where source_key = 'Jake Taylor';
    if v_loc is null then raise exception 'no Jake Taylor location'; end if;

    for r in
        select m.id, m.name, m.bottle_size, coalesce(m.bottle_size_unit, 'doses') as unit, x.bottles
          from (values ('Ultrachoice 8', 1), ('Pinkeye Autogenous Bacterin', 4), ('Protivity', 9))
                 as x(nm, bottles)
          join public.medications m on m.name = x.nm
    loop
        if exists (select 1 from public.med_purchase_lines
                    where medication_id = r.id and location_id = v_loc
                      and mfr_lot_number = 'previously expensed - $0') then
            raise notice 'SKIPPED %: already on his shelf.', r.name;
            continue;
        end if;

        insert into public.med_purchase_lines (
            medication_id, location_id, qty_bottles, bottle_size, unit,
            unit_cost, qty_remaining, received_date, origin, sort_order, mfr_lot_number
        ) values (
            r.id, v_loc, r.bottles, r.bottle_size, r.unit,
            0, r.bottles * r.bottle_size, '2026-10-01'::date, 'adjustment', -1,
            'previously expensed - $0'
        ) returning id into v_line;

        update public.med_txns
           set notes = 'Given to Jake Taylor at NO COST to use up, on John''s instruction '
                    || '2026-10-02: ' || r.bottles || ' x ' || r.bottle_size || ' '
                    || r.unit || ' of ' || r.name || '. Already expensed earlier in the year, '
                    || 'before there was an inventory system, so the ranch has paid for it once '
                    || 'and it is not charged again. Dated 1 Oct - the earliest day his period '
                    || 'lock allows - and sort_order -1 so it draws ahead of anything else '
                    || 'dated 1 Oct or later. Expected to be used up this month.'
         where ref_kind = 'med_purchase_line' and ref_id = v_line;

        raise notice '% : % units at $0 on Jake''s shelf.', r.name, r.bottles * r.bottle_size;
    end loop;
end
$gift$;

-- ---- verify ---------------------------------------------------------------
do $verify$
declare n integer; v numeric;
begin
    select count(*) into n from public.med_purchase_lines l
      join public.med_stock_locations loc on loc.id = l.location_id
     where loc.source_key = 'Jake Taylor' and l.mfr_lot_number = 'previously expensed - $0';
    if n <> 3 then raise exception 'expected 3 gifted layers at Jake, found %', n; end if;

    select sum(l.qty_units) into v from public.med_purchase_lines l
      join public.med_stock_locations loc on loc.id = l.location_id
     where loc.source_key = 'Jake Taylor' and l.mfr_lot_number = 'previously expensed - $0';
    if v <> 540 then raise exception 'gifted units total %, not 540 (250 + 200 + 90)', v; end if;

    -- free means free, and nothing may be dated into a closed period
    select count(*) into n from public.med_purchase_lines l
      join public.med_stock_locations loc on loc.id = l.location_id
     where l.mfr_lot_number = 'previously expensed - $0'
       and (l.unit_cost <> 0 or l.received_date <= public.med_locked_through(loc.id));
    if n > 0 then raise exception '% gifted layer(s) are priced or dated into a closed period', n; end if;

    select count(*) into n from (
      select pl.id from public.med_purchase_lines pl
        left join public.med_txn_layers tl on tl.purchase_line_id = pl.id
       group by pl.id, pl.qty_units, pl.qty_remaining
      having round(pl.qty_units - coalesce(sum(tl.qty_units), 0), 4) <> round(pl.qty_remaining, 4)) x;
    if n > 0 then raise exception '% layer(s) no longer tie', n; end if;

    select count(*) into n from public.med_roll_forward
     where round(beginning_units + opening_units + purchased_units - used_units
                 + adjustment_units + uncovered_units
                 + transferred_in_units - transferred_out_units, 4) <> round(ending_units, 4);
    if n > 0 then raise exception '% roll-forward row(s) do not tie on units', n; end if;

    -- the Protivity hole, reported rather than guessed at
    select count(*) into n from public.medications m
     where m.name = 'Protivity' and m.flat_dose_amount is null
       and not exists (select 1 from public.protocol_meds pm join public.protocols p on p.id = pm.protocol_id
                        where pm.medication_id = m.id and p.is_active
                          and pm.override_flat_dose is not null);
    if n > 0 then
        raise notice 'OPEN: Protivity still has no dose a head, so its 90 doses cannot draw. One field on the Medications tab.';
    end if;

    raise notice 'VERIFIED: 540 units at $0 on Jake''s shelf, open period, everything ties.';
end
$verify$;

commit;
