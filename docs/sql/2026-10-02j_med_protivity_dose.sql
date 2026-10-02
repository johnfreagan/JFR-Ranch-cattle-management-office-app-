-- =====================================================================
-- Protivity gets its dose: 1 a head.
-- =====================================================================
-- APPLIED 2026-10-02. John: "1 dose per hd 10 doses a bottle."
--
-- The bottle was already right - medications.bottle_size is 10 doses, and
-- that is what the 9 bottles given to Jake were counted against. Only the
-- DOSE was missing: flat_dose_amount was NULL and the active protocol it
-- sits on ("26 Summer X Steers/Bulls Receiving") set no override, so a
-- processing draw had no dose to pull. Those 90 doses would have sat on
-- his shelf the same way the per-hundredweight meds sat waiting on a
-- weight, and the line would have read 'to draw' forever.
--
-- One field. flat_dose_amount = 1.
--
-- THE CATALOG PRICE STAYS NULL, deliberately. It would be easy to set
-- bottle_cost to 0 and call the whole thing priced, but that would say
-- Protivity costs nothing in general, which is not true - it says the
-- STOCK Jake was given is free, which is a fact about those 9 bottles and
-- belongs on the layer, where it already is. Receipts that draw off that
-- layer read $0 because the draw really was free. Older receipts keep
-- reading as a hole, which is honest: nobody knows what Protivity cost
-- those lots, and John's note from July says it had already been charged
-- to a lot by other means.
--
-- ITEM 16 GATE: processing across every lot read $99,530.31 before this
-- change and $99,530.31 after, with the same 5 lots carrying unpriced
-- lines. Nothing moved, and the reason it could not is worth writing
-- down: cost_per_head_line needs a PRICE, and Protivity still has none,
-- so giving it a dose cannot change a dollar anywhere. What it changes is
-- that the line can now draw.
--
-- No receipt went to 'to draw' either - every non-drawn processing line
-- on the place is still 'before go-live'. The dose will first bite on the
-- next load out entered against that protocol.
--
-- ONE TRAP TO KNOW ABOUT, for whoever reads this next. When the free 90
-- doses run out, a further draw goes uncovered, and med_consume prices
-- uncovered usage at "the last cost we know" - which for Protivity is now
-- the $0 layer. So it would book free and NOT be flagged unpriced, since
-- the flag only raises when there is no number at all. The units still
-- show as uncovered on the on-hand screen, so it is visible, but the
-- dollars would read zero quietly. If Protivity is ever bought again,
-- price it on the Medications tab before it is used.
-- =====================================================================

begin;

update public.medications
   set flat_dose_amount = 1
 where name = 'Protivity' and flat_dose_amount is null;

-- ---- verify ---------------------------------------------------------------
do $verify$
declare
    v_dose numeric;
    v_size numeric;
    n      integer;
begin
    select flat_dose_amount, bottle_size into v_dose, v_size
      from public.medications where name = 'Protivity';
    if v_dose <> 1 then raise exception 'Protivity doses % a head, not 1', v_dose; end if;
    if v_size <> 10 then raise exception 'Protivity bottle is % doses, not 10', v_size; end if;

    -- it can now reach a draw: a dose on every active protocol it sits on
    select count(*) into n
      from public.protocol_meds pm
      join public.protocols p on p.id = pm.protocol_id
      join public.medications m on m.id = pm.medication_id
     where m.name = 'Protivity' and p.is_active
       and coalesce(pm.override_flat_dose, m.flat_dose_amount) is null;
    if n > 0 then raise exception 'Protivity still has no dose on % active protocol(s)', n; end if;

    -- and the free stock is still free and still there
    select sum(qty_remaining) into v_dose
      from public.med_purchase_lines l
      join public.medications m on m.id = l.medication_id
     where m.name = 'Protivity' and l.unit_cost = 0;
    if coalesce(v_dose, 0) <> 90 then
        raise exception 'the free Protivity reads % doses, not 90', v_dose;
    end if;

    raise notice 'VERIFIED: Protivity doses 1 a head off a 10-dose bottle, and its 90 free doses can draw.';
end
$verify$;

commit;
