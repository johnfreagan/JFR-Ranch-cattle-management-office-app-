-- =====================================================================
-- Opening count: the last two sizes, and Protivity put back to NOT
-- COUNTED
-- =====================================================================
-- 2026-10-01. John: "estrumate 100 ml, multi min 500 ml, protivity not
-- sure on price will add later."
--
-- ESTRUMATE. 100 mL, Redwing 1 container at $105.00, so $1.05/mL. Ties
-- to Redwing exactly.
--
-- MULTI MIN. 500 mL, and the sheet found FOUR bottles where Redwing
-- carries three. Redwing's three at $919.03 is $306.343333 a bottle and
-- $0.612687/mL; four bottles is 2,000 mL and $1,225.37. That is $306.34
-- MORE than Redwing carries, so this line runs the other way from every
-- difference before it - Redwing is understated, not overstated. The
-- fourth bottle is priced at the same rate as the other three, which is
-- the only rate anybody knows for it.
--
-- PROTIVITY IS A CORRECTION, and the reason this file exists rather than
-- being folded into the one before it. Its count line said a counted
-- ZERO, taken from Redwing, which showed both Mycoplasma vaccine lines
-- at zero. The medicine-room sheet then found EIGHT 10-dose boxes on the
-- shelf. Zero was wrong, and a counted zero is not a harmless wrong
-- number: posting it would have booked a real count of nothing against
-- 80 doses of real stock. It goes back to NULL, which is "not counted",
-- until there is a price - med_post_count refuses a positive variance it
-- cannot price rather than booking it at zero, and that refusal is the
-- correct behaviour here.
--
-- THE BRIDGE now closes in both directions:
--     Redwing at 9/30/2026                        $21,896.25
--       less Excede over-valuation                 $2,061.98
--       less Macrosyn 250 mL                         $373.15
--       less One Grass, disposed                   $1,804.00
--       less Synovex S, expired                      $165.00
--       PLUS Multi Min's fourth bottle               $306.34
--                                                 ----------
--                                                 $17,798.46
--     counted in the program                      $17,798.46
--
--     Protivity sits outside it: 80 doses on the shelf, nothing on the
--     Redwing side, no price on either.
--
-- Still a DRAFT. Nothing posts.
-- =====================================================================

begin;

UPDATE public.medications SET bottle_size=100, bottle_size_unit='mL', bottle_cost=105.00
 WHERE name='Estrumate' AND bottle_size IS NULL;

UPDATE public.medications SET bottle_size=500, bottle_size_unit='mL', bottle_cost=306.34
 WHERE name='Multi Min' AND bottle_size IS NULL;

DO $lines$
DECLARE
    v_count uuid;
BEGIN
    SELECT c.id INTO v_count
      FROM public.med_counts c
      JOIN public.med_stock_locations l ON l.id = c.location_id
     WHERE c.count_date = DATE '2026-09-30' AND c.is_opening
       AND l.kind='ranch' AND NOT l.is_test;

    IF v_count IS NULL THEN
        RAISE EXCEPTION 'the opening count draft is missing';
    END IF;
    IF (SELECT status FROM public.med_counts WHERE id=v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the opening count is no longer a draft - refusing to edit a posted count';
    END IF;

    INSERT INTO public.med_count_lines
        (count_id, medication_id, counted_units, unit_cost, bottle_size, barn_full, notes)
    SELECT v_count, m.id, x.units, x.unit_cost, m.bottle_size, x.bottles, x.note
      FROM (VALUES
        ('Estrumate', 100.0,  1.050000, 1.0,
         'Sheet: 100 mL. Redwing 1 container at $105.00. 1 x 100 mL at $1.05/mL.'),
        ('Multi Min', 2000.0, 0.612687, 4.0,
         'Sheet: 500 mL and FOUR bottles on the shelf. Redwing carries THREE at $919.03, so $306.343333 a bottle, $0.612687/mL. Four bottles = 2,000 mL = $1,225.37, which is $306.34 MORE than Redwing carries - the fourth bottle is stock Redwing does not know it has.')
      ) AS x(med_name, units, unit_cost, bottles, note)
      JOIN public.medications m ON m.name = x.med_name
     WHERE NOT EXISTS (
        SELECT 1 FROM public.med_count_lines cl
         WHERE cl.count_id=v_count AND cl.medication_id=m.id);

    -- The correction.
    UPDATE public.med_count_lines cl
       SET counted_units = NULL, barn_full = NULL,
           notes = 'CORRECTED 2026-10-01. This line said a counted ZERO, taken from Redwing, which showed both Mycoplasma vaccine lines at zero. The medicine-room sheet then found EIGHT 10-dose boxes on the shelf, so zero was wrong and leaving it would have posted a false count. Set back to NOT COUNTED: there is 80 doses of real stock here and no cost known for it anywhere - Redwing carries none and the catalog has none - and med_post_count refuses a positive variance it cannot price rather than booking it at nothing. Count it in once John has the price.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Protivity';
END
$lines$;

DO $verify$
DECLARE
    v_count uuid; n integer; v numeric; posted integer;
BEGIN
    SELECT c.id INTO v_count FROM public.med_counts c
      JOIN public.med_stock_locations l ON l.id = c.location_id
     WHERE c.count_date = DATE '2026-09-30' AND c.is_opening
       AND l.kind='ranch' AND NOT l.is_test;

    SELECT count(*) INTO n FROM public.med_count_lines WHERE count_id=v_count;
    IF n <> 21 THEN RAISE EXCEPTION 'expected 21 count lines, found %', n; END IF;

    SELECT round(SUM(counted_units*unit_cost),2) INTO v
      FROM public.med_count_lines WHERE count_id=v_count AND unit_cost IS NOT NULL;
    IF v <> 17798.46 THEN RAISE EXCEPTION 'priced lines come to %, expected 17798.46', v; END IF;

    -- Protivity must be NOT COUNTED, not a counted zero.
    SELECT count(*) INTO n FROM public.med_count_lines cl
      JOIN public.medications m ON m.id=cl.medication_id
     WHERE cl.count_id=v_count AND m.name='Protivity' AND cl.counted_units IS NULL;
    IF n <> 1 THEN RAISE EXCEPTION 'Protivity is not set to NOT COUNTED'; END IF;

    SELECT count(*) INTO posted FROM public.med_purchase_lines;
    IF posted <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% layers)', posted; END IF;
    SELECT count(*) INTO posted FROM public.med_txns;
    IF posted <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% txns)', posted; END IF;
    IF (SELECT status FROM public.med_counts WHERE id=v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the count is not a draft';
    END IF;

    RAISE NOTICE 'VERIFIED: 21 lines, $17,798.46 priced, Protivity not counted, still a draft, nothing posted.';
END
$verify$;

commit;
