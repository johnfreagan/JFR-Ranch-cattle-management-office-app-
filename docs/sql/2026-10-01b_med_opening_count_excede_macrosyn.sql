-- =====================================================================
-- Opening count: Excede priced off Redwing's own 100 mL line, Macrosyn
-- counted empty
-- =====================================================================
-- 2026-10-01, after John checked the shelf. Follows
-- 2026-10-01_med_opening_count.sql. Still a DRAFT - nothing posts.
--
-- EXCEDE. Redwing carries it on two lines:
--     Excede 100 ML   24 bottles   $5,133.40   -> $2.138917/mL
--     Excede 250 ML    1 bottle    $2,596.71   -> $10.386840/mL
-- The second is 4.86x the first and 5.01x this catalog's $2.071120/mL.
-- $2,596.71 / 5 = $519.34 a bottle, which lands within 0.3% of our
-- $517.78, so the line reads like five bottles of money booked against a
-- quantity of one - a case price taken against a single unit at
-- receiving. John checked the shelf and found ONE bottle, so the
-- quantity stands and the money does not.
--
-- All 2,650 mL is therefore counted at $2.138917/mL: Redwing's own rate
-- from its own 100 mL line, corroborated within 3.3% by our last
-- purchase price. $5,668.13 of product against $7,730.11 carried, so
-- $2,061.98 is a Redwing write-off rather than stock.
--
-- MACROSYN. Redwing shows $373.15 against no quantity at all. Nothing on
-- the shelf, so it is counted zero - a real count, which says somebody
-- looked - and the $373.15 comes off the Redwing side.
--
-- THE BRIDGE, which adds back to the report's own total exactly:
--     Redwing at 9/30/2026                        $21,896.25
--       less Excede over-valuation                 $2,061.98
--       less Macrosyn 250 mL                         $373.15
--       less One Grass, out of date, for disposal  $1,804.00
--     Redwing after the write-offs                $17,657.12
--       of which counted here now                 $13,905.63
--       of which still to count                    $3,751.49
-- =====================================================================

begin;

DO $upd$
DECLARE
    v_count uuid;
BEGIN
    SELECT c.id INTO v_count
      FROM public.med_counts c
      JOIN public.med_stock_locations l ON l.id = c.location_id
     WHERE c.count_date = DATE '2026-09-30' AND c.is_opening
       AND l.kind = 'ranch' AND NOT l.is_test;

    IF v_count IS NULL THEN
        RAISE EXCEPTION 'the opening count draft is missing';
    END IF;
    IF (SELECT status FROM public.med_counts WHERE id = v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the opening count is no longer a draft - refusing to edit a posted count';
    END IF;

    INSERT INTO public.med_count_lines
        (count_id, medication_id, counted_units, unit_cost, bottle_size, barn_full, notes)
    SELECT v_count, m.id, x.units, x.unit_cost, m.bottle_size, x.bottles, x.note
      FROM (VALUES
        ('Excede', 2650.0, 2.138917, 10.6,
         'Redwing "Excede 100 ML" 24.00 bottles $5,133.40 plus "Excede 250 ML" 1.00 bottle $2,596.71 = 2,650 mL. Priced at the 100 ML line''s own implied $2.138917/mL, because the 250 ML line''s $10.386840/mL is 4.86x that and 5.01x our last purchase price. John confirmed one bottle on the 250 ML line on 2026-10-01, so the quantity stands and $2,061.98 of Redwing value does not.'),
        ('Macrosyn(Draxxin)', 0.0, NULL, 0.0,
         'Redwing "Macrosyn 250 ML" shows $373.15 against NO quantity. Nothing on the shelf, so counted zero; John''s call 2026-10-01 is to write the $373.15 off in Redwing.')
      ) AS x(med_name, units, unit_cost, bottles, note)
      JOIN public.medications m ON m.name = x.med_name
     WHERE NOT EXISTS (
        SELECT 1 FROM public.med_count_lines cl
         WHERE cl.count_id = v_count AND cl.medication_id = m.id);

    RAISE NOTICE 'opening count draft now has % line(s)',
        (SELECT count(*) FROM public.med_count_lines WHERE count_id = v_count);
END
$upd$;

DO $verify$
DECLARE
    v_count uuid; n integer; v numeric; posted integer;
BEGIN
    SELECT c.id INTO v_count FROM public.med_counts c
      JOIN public.med_stock_locations l ON l.id = c.location_id
     WHERE c.count_date = DATE '2026-09-30' AND c.is_opening
       AND l.kind='ranch' AND NOT l.is_test;

    SELECT count(*) INTO n FROM public.med_count_lines WHERE count_id = v_count;
    IF n <> 12 THEN RAISE EXCEPTION 'expected 12 count lines, found %', n; END IF;

    SELECT round(SUM(counted_units*unit_cost),2) INTO v
      FROM public.med_count_lines WHERE count_id=v_count AND unit_cost IS NOT NULL;
    IF v <> 13905.63 THEN
        RAISE EXCEPTION 'priced lines come to %, expected 13905.63', v;
    END IF;

    SELECT count(*) INTO posted FROM public.med_purchase_lines;
    IF posted <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% layers)', posted; END IF;
    SELECT count(*) INTO posted FROM public.med_txns;
    IF posted <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% txns)', posted; END IF;

    IF (SELECT status FROM public.med_counts WHERE id=v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the count is not a draft';
    END IF;

    RAISE NOTICE 'VERIFIED: 12 lines, $13,905.63 priced, still a draft, nothing posted.';
END
$verify$;

commit;
