-- =====================================================================
-- Opening count: container sizes off the medicine-room sheet, and the
-- lines that can now be stated
-- =====================================================================
-- 2026-10-01. Source: the worksheet printed from
-- docs/worksheets/2026-10-01_medicine-room-container-sizes.html, walked
-- and filled in by John, returned as a scan. Plus his notes the same day
-- on One Grass, Synovex S, Ivomec and the Enroflox rebate.
--
-- WHAT THE SHEET SAID
--   Cydectin        5 Liter, mL, 2 on the shelf   (Redwing: 2)
--   Dectomax        500 mL                        (Redwing: 5)
--   Draxxin KP      250 mL                        (Redwing: 1)
--   Synovex Primer  none on hand, doses
--   Synovex S       none, out of date, doses      (Redwing: 150 @ $1.10)
--   Protivity       10-dose box, EIGHT ON HAND    (Redwing: zero)
--   Dexamethasone   mL, no size given
--   Estrumate       mL, no size given             (Redwing: 1 @ $105.00)
--   One Grass       none, out of date, each       (Redwing: 400 @ $4.51)
--   Multi Min       "4 bottles", mL, no size      (Redwing: 3 @ $306.34)
--
-- Two of those are findings rather than answers, and they point opposite
-- ways from everything so far: Protivity and the fourth Multi Min are
-- stock REDWING DOES NOT KNOW IT HAS. Every other difference to date has
-- been Redwing carrying more than the shelf.
--
-- THE SIZES ARE READ OFF HANDWRITING, so each was checked against price
-- per unit before being written here. Dectomax at 500 mL prices at
-- $0.2438/mL, inside the band set by Valcor ($0.30142) and Synanthic
-- ($0.27495); at 50 mL it would be $2.438/mL, eight times Synanthic, so
-- 500 mL is the reading that holds up. Draxxin KP at $1.764/mL against
-- plain Draxxin's $0.99262 is expected - KP carries ketoprofen as well.
-- Cydectin at $0.151196/mL is the cheapest per mL of the dewormers,
-- which is what a 5 litre pour-on jug should be.
--
-- Still a DRAFT. Nothing posts.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Container sizes and units, where the sheet gave them.
-- ---------------------------------------------------------------------
-- cost_per_unit is NOT set here. It is a GENERATED column on medications -
--     CASE WHEN bottle_size > 0 THEN bottle_cost / bottle_size ELSE NULL END
-- - so writing to it is refused outright ("column can only be updated to
-- DEFAULT"). Setting bottle_size and bottle_cost derives it, and derives
-- it to exactly the figures wanted: $0.151196, $0.243800 and $1.764000.
-- Found 2026-10-01 against the live database; the test fixture had
-- cost_per_unit as a plain column and so accepted what production refuses.
UPDATE public.medications SET
    bottle_size = 5000, bottle_size_unit = 'mL', bottle_cost = 755.98,
    notes = COALESCE(notes || ' | ', '') ||
        '2026-10-01: 5 litre jug off the medicine-room sheet; 2 on the shelf, which matches Redwing. $1,511.96 / 10,000 mL = $0.151196/mL.'
 WHERE name = 'Cydectin' AND bottle_size IS NULL;

UPDATE public.medications SET
    bottle_size = 500, bottle_size_unit = 'mL', bottle_cost = 121.90,
    notes = COALESCE(notes || ' | ', '') ||
        '2026-10-01: 500 mL off the medicine-room sheet. $609.50 / 2,500 mL = $0.2438/mL, which sits inside the band Valcor and Synanthic set, so the reading holds up against price.'
 WHERE name = 'Dectomax' AND bottle_size IS NULL;

UPDATE public.medications SET
    bottle_size = 250, bottle_size_unit = 'mL', bottle_cost = 441.00,
    notes = COALESCE(notes || ' | ', '') ||
        '2026-10-01: 250 mL off the medicine-room sheet. $441.00 / 250 mL = $1.764/mL; dearer than plain Draxxin at $0.99262 because KP carries ketoprofen too.'
 WHERE name = 'Draxxin KP' AND bottle_size IS NULL;

UPDATE public.medications SET
    bottle_size = 10, bottle_size_unit = 'doses',
    notes = COALESCE(notes || ' | ', '') ||
        '2026-10-01: 10-dose box off the medicine-room sheet, EIGHT on the shelf. Redwing carries zero, so this is stock Redwing does not know it has. Cannot be counted in until somebody says what a box cost - a positive variance with no cost is refused rather than booked at zero.'
 WHERE name = 'Protivity' AND bottle_size IS NULL;

-- Unit without a size: the sheet circled the unit but the size box came
-- back empty. Recording the unit is still worth it - it is half the
-- answer and it stops the next sheet asking again.
UPDATE public.medications SET bottle_size_unit = 'mL'
 WHERE name IN ('Dexamethasone','Estrumate','Multi Min')
   AND bottle_size IS NULL AND bottle_size_unit IS NULL;
UPDATE public.medications SET bottle_size_unit = 'doses'
 WHERE name IN ('Synovex Primer','Synovex S')
   AND bottle_size IS NULL AND bottle_size_unit IS NULL;
UPDATE public.medications SET bottle_size_unit = 'each'
 WHERE name = 'One Grass' AND bottle_size IS NULL AND bottle_size_unit IS NULL;


-- ---------------------------------------------------------------------
-- 2. The count lines the sheet now settles.
-- ---------------------------------------------------------------------
DO $lines$
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
        ('Cydectin',   10000.0, 0.151196,  2.0,
         'Sheet: 5 litre jug, 2 on the shelf, which matches Redwing''s 2 at $1,511.96. 2 x 5,000 mL.'),
        ('Dectomax',    2500.0, 0.243800,  5.0,
         'Sheet: 500 mL. Redwing 5 containers at $609.50. 5 x 500 mL.'),
        ('Draxxin KP',   250.0, 1.764000,  1.0,
         'Sheet: 250 mL. Redwing 1 container at $441.00.'),

        -- Counted empty, each for its own stated reason.
        ('Synovex Primer', 0.0, NULL, 0.0,
         'Sheet: none on hand. Redwing does not carry it either.'),
        ('Synovex S',      0.0, NULL, 0.0,
         'Sheet: none, out of date. Redwing carries 150 doses at $165.00, which is a write-off on their side - John, 2026-10-01: "synovex s is expired as well".'),
        ('One Grass',      0.0, NULL, 0.0,
         'Sheet: none, out of date. Disposed of 2026-10-01 and being adjusted out of Redwing the same day, so the $1,804.00 comes off their side.'),
        ('Ivomec Long Range Wormer', 0.0, NULL, 0.0,
         'Two bottles were on the shelf and are going back to the vendor (John, 2026-10-01). Redwing never carried them - no Ivomec line on the 9/30 report at all - so neither side holds them and the opening position is zero. Worth noting that two bottles sat here unrecorded.')
      ) AS x(med_name, units, unit_cost, bottles, note)
      JOIN public.medications m ON m.name = x.med_name
     WHERE NOT EXISTS (
        SELECT 1 FROM public.med_count_lines cl
         WHERE cl.count_id = v_count AND cl.medication_id = m.id);

    RAISE NOTICE 'opening count draft now has % line(s)',
        (SELECT count(*) FROM public.med_count_lines WHERE count_id = v_count);
END
$lines$;


-- ---------------------------------------------------------------------
-- 3. Verify.
-- ---------------------------------------------------------------------
DO $verify$
DECLARE
    v_count uuid; n integer; v numeric; posted integer;
BEGIN
    SELECT c.id INTO v_count FROM public.med_counts c
      JOIN public.med_stock_locations l ON l.id = c.location_id
     WHERE c.count_date = DATE '2026-09-30' AND c.is_opening
       AND l.kind='ranch' AND NOT l.is_test;

    SELECT count(*) INTO n FROM public.med_count_lines WHERE count_id = v_count;
    IF n <> 19 THEN RAISE EXCEPTION 'expected 19 count lines, found %', n; END IF;

    -- 13,905.63 already there + 1,511.96 + 609.50 + 441.00
    SELECT round(SUM(counted_units*unit_cost),2) INTO v
      FROM public.med_count_lines WHERE count_id=v_count AND unit_cost IS NOT NULL;
    IF v <> 16468.09 THEN
        RAISE EXCEPTION 'priced lines come to %, expected 16468.09', v;
    END IF;

    -- The three new sizes must have landed, or the lines above are
    -- counting units that mean nothing.
    SELECT count(*) INTO n FROM public.medications
     WHERE (name='Cydectin'   AND bottle_size=5000 AND bottle_size_unit='mL')
        OR (name='Dectomax'   AND bottle_size=500  AND bottle_size_unit='mL')
        OR (name='Draxxin KP' AND bottle_size=250  AND bottle_size_unit='mL')
        OR (name='Protivity'  AND bottle_size=10   AND bottle_size_unit='doses');
    IF n <> 4 THEN RAISE EXCEPTION 'expected 4 container sizes set, found %', n; END IF;

    SELECT count(*) INTO posted FROM public.med_purchase_lines;
    IF posted <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% layers)', posted; END IF;
    SELECT count(*) INTO posted FROM public.med_txns;
    IF posted <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% txns)', posted; END IF;
    IF (SELECT status FROM public.med_counts WHERE id=v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the count is not a draft';
    END IF;

    RAISE NOTICE 'VERIFIED: 19 lines, $16,468.09 priced, 4 container sizes set, still a draft, nothing posted.';
END
$verify$;

commit;
