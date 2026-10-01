-- =====================================================================
-- Medicine inventory: the seven missing catalog items, and the opening
-- count as a DRAFT
-- =====================================================================
-- 2026-10-01. Source document: Redwing "JFR Ranch / Medicine RM Inventory
-- / 1/1/1900 to 9/30/2026", account 117500 Animal Health RM, printed
-- 9/30/2026 9:12 AM. Scanned, so there is no text layer; the figures below
-- were read off the scan and both of the report's own control totals were
-- reproduced from them before anything here was written:
--
--     quantities  731.00      amounts  $21,896.25
--
-- John's decisions, 2026-10-01:
--   - the Redwing quantities ARE the opening count;
--   - the seven products Redwing carries and the catalog did not are
--     added to the catalog;
--   - Excede 250 ML is held out pending a shelf check;
--   - the twelve catalog medications Redwing does not list are left
--     BLANK, which is "not counted" and not a count of zero.
--
-- NOTHING IS POSTED BY THIS FILE. The count is created as a draft. It
-- books no shrink, creates no layer and moves no stock until somebody
-- presses Post, and the ranch location's usage_from is still NULL, so no
-- treatment is drawing against inventory either.
--
-- WHAT THE REPORT DOES NOT SAY
--
-- The `$ / unit` column is blank on every line, so unit cost here is
-- derived: amount / quantity. And the quantity column is not one unit of
-- measure - Enroflox 21 at $183.57 is bottles, Synovex C 110 at $1.10 is
-- doses. Each line below states which it took.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Preflight.
-- ---------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regclass('public.med_counts') IS NULL THEN
        RAISE EXCEPTION 'The med inventory tables are missing. Apply 2026-10-01_med_inventory.sql first.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.med_stock_locations
                    WHERE kind = 'ranch' AND NOT is_test AND is_active) THEN
        RAISE EXCEPTION 'No active ranch stock location.';
    END IF;
END
$pre$;


-- ---------------------------------------------------------------------
-- 1. The seven products Redwing carries that the catalog did not.
-- ---------------------------------------------------------------------
-- $5,555.49 of the $21,896.25 on the report - a quarter of it - sat in
-- products with no medication row, so a quarter of the inventory could
-- not have been counted at all.
--
-- bottle_size IS LEFT NULL ON PURPOSE. The report gives a container
-- COUNT and an extended amount; it does not say how big the container
-- is, and nothing else here knows either. Guessing it would silently
-- misprice every future dose of these drugs by whatever factor the guess
-- was wrong by. NULL makes med_on_hand flag them "needs a container
-- size" in red, which is the honest state until somebody reads the
-- label. Doctoring is unaffected - dose_cc is already in base units.
--
-- Each row's notes carry what Redwing said, so the derived cost can be
-- checked against the source without the scan to hand.
INSERT INTO public.medications
    (name, generic_category, dose_mode, is_active, track_inventory, notes)
VALUES
    ('Cydectin',   'Anthelmintic (Dewormer)', 'flat', true, true,
     'Added 2026-10-01 from the Redwing Medicine RM Inventory at 9/30/2026, which carried 2.00 at $1,511.96 ($755.98 each) with no counterpart in this catalog. Container size and dose not yet set - read the label before stocking it.'),
    ('Dectomax',   'Anthelmintic (Dewormer)', 'flat', true, true,
     'Added 2026-10-01 from the Redwing Medicine RM Inventory at 9/30/2026, which carried 5.00 at $609.50 ($121.90 each) with no counterpart in this catalog. Container size and dose not yet set - read the label before stocking it.'),
    ('Draxxin KP', 'Antibiotic',              'flat', true, true,
     'Added 2026-10-01 from the Redwing Medicine RM Inventory at 9/30/2026, which carried 1.00 at $441.00 with no counterpart in this catalog. Distinct from Draxxin and from Macrosyn(Draxxin), which are separate rows on the same report. Container size and dose not yet set.'),
    ('Estrumate',  'Other',                   'flat', true, true,
     'Added 2026-10-01 from the Redwing Medicine RM Inventory at 9/30/2026, which carried 1.00 at $105.00 with no counterpart in this catalog. Container size and dose not yet set.'),
    ('Multi Min',  'Vitamin/Mineral',         'flat', true, true,
     'Added 2026-10-01 from the Redwing Medicine RM Inventory at 9/30/2026, which carried 3.00 at $919.03 ($306.34 each) with no counterpart in this catalog. Container size and dose not yet set.'),
    ('One Grass',  'Other',                   'flat', true, true,
     'Added 2026-10-01 from the Redwing Medicine RM Inventory at 9/30/2026, which carried 400.00 at $1,804.00 ($4.51 each) with no counterpart in this catalog. What the product is and what a unit of it means are both unconfirmed, so the category is Other until John says otherwise.'),
    ('Synovex S',  'Implant',                 'flat', true, true,
     'Added 2026-10-01 from the Redwing Medicine RM Inventory at 9/30/2026, which carried 150.00 at $165.00. At $1.10 each that is DOSES, the same unit and the same price as Synovex C on the line above it. Cartridge size not yet set.')
ON CONFLICT (name) DO NOTHING;


-- ---------------------------------------------------------------------
-- 2. The opening count, as a draft.
-- ---------------------------------------------------------------------
-- Dated 9/30/2026 to match the report. is_opening = true, so a positive
-- variance against an empty ledger is born as an `opening` layer rather
-- than an `adjustment` - same machinery, different label on the ledger
-- row, which is what keeps the first month's roll-forward readable.
DO $count$
DECLARE
    v_loc   uuid;
    v_count uuid;
BEGIN
    SELECT id INTO v_loc FROM public.med_stock_locations
     WHERE kind = 'ranch' AND NOT is_test AND is_active
     ORDER BY created_at LIMIT 1;

    SELECT id INTO v_count FROM public.med_counts
     WHERE location_id = v_loc AND count_date = DATE '2026-09-30' AND is_opening;

    IF v_count IS NULL THEN
        INSERT INTO public.med_counts
            (count_date, location_id, status, is_opening, counted_by, notes)
        VALUES
            (DATE '2026-09-30', v_loc, 'draft', true, 'Redwing 9/30/2026 inventory',
             'Opening count. Quantities and values from the Redwing Medicine RM '
             'Inventory report for account 117500 at 9/30/2026 (totals 731.00 units / '
             '$21,896.25, both reproduced before entry). Unit cost is derived - the '
             'report prints no $/unit. Lines left BLANK are deliberately not counted: '
             'Excede pending a shelf check on the 250 ML line, Macrosyn because Redwing '
             'shows $373.15 against no quantity at all, the seven newly added products '
             'pending container sizes, and the twelve catalog medications Redwing does '
             'not list.')
        RETURNING id INTO v_count;
    END IF;

    -- -----------------------------------------------------------------
    -- The lines that can be stated exactly.
    --
    -- counted_units is in BASE units, so a bottle line is bottles x
    -- bottle_size and a dose line is doses. unit_cost is the derived
    -- per-base-unit cost, and counted_units x unit_cost reproduces
    -- Redwing's extended amount to the cent on every line.
    -- -----------------------------------------------------------------
    INSERT INTO public.med_count_lines
        (count_id, medication_id, counted_units, unit_cost, bottle_size, barn_full, notes)
    SELECT v_count, m.id, x.units, x.unit_cost, m.bottle_size, x.containers, x.note
      FROM (VALUES
        -- name in this catalog     units       $/unit        containers  note
        ('Biomycin',                 500.0,     0.138880,      1.0,
         'Redwing "Biomycin" 1.00 bottle, $69.44. 1 x 500 mL.'),
        ('Enroflox(Baytril)',      10500.0,     0.367130,     21.0,
         'Redwing "Enroflox 500 ML" 21.00 bottles, $3,854.87. 21 x 500 mL.'),
        ('Resflor',                 5000.0,     0.830762,     10.0,
         'Redwing "Resflor 500 ML" 10.00 bottles, $4,153.81. 10 x 500 mL. Redwing also lists "Resflor 250 ML" at zero.'),
        ('Thiamine',                 200.0,     0.191900,      2.0,
         'Redwing "Thiamine" 2.00 bottles, $38.38. 2 x 100 mL.'),
        ('Synovex C 100 Ds Prestige', 110.0,    1.100000,      1.1,
         'Redwing "Synovex C" 110.00 at $121.00. That is DOSES at $1.10 each, not bottles - our cartridge is 100 doses, so 110 doses is 1.1 cartridges.'),

        -- Counted and found EMPTY. Zero is a real count and not the same
        -- as a blank: it says somebody looked. Variance against an empty
        -- ledger is nil, so these create no layer and need no cost.
        ('Brute',                      0.0,     NULL,          0.0,
         'Redwing "Brute" zero on hand at 9/30/2026.'),
        ('Draxxin',                    0.0,     NULL,          0.0,
         'Redwing "Draxxin 250 ML" zero on hand at 9/30/2026. Redwing carries no 500 mL Draxxin line.'),
        ('Protivity',                  0.0,     NULL,          0.0,
         'Redwing "Mycroplasm Vaccine 50 Dose" and "Mycroplasma Vaccine 10 Dose" both zero on hand at 9/30/2026.'),
        ('Ultrachoice 8',              0.0,     NULL,          0.0,
         'Redwing "Ultrachoice" zero on hand at 9/30/2026.'),
        ('Vitamin K',                  0.0,     NULL,          0.0,
         'Redwing "Vitamin K" zero on hand at 9/30/2026.')
      ) AS x(med_name, units, unit_cost, containers, note)
      JOIN public.medications m ON m.name = x.med_name
     WHERE NOT EXISTS (
        SELECT 1 FROM public.med_count_lines cl
         WHERE cl.count_id = v_count AND cl.medication_id = m.id
     );

    RAISE NOTICE 'Opening count draft % at location %, % line(s).',
        v_count, v_loc, (SELECT count(*) FROM public.med_count_lines WHERE count_id = v_count);
END
$count$;


-- ---------------------------------------------------------------------
-- 3. Verify. Raises inside the transaction.
-- ---------------------------------------------------------------------
DO $verify$
DECLARE
    v_count  uuid;
    n        integer;
    v_value  numeric;
    v_posted integer;
BEGIN
    SELECT c.id INTO v_count
      FROM public.med_counts c
      JOIN public.med_stock_locations l ON l.id = c.location_id
     WHERE c.count_date = DATE '2026-09-30' AND c.is_opening
       AND l.kind = 'ranch' AND NOT l.is_test;

    IF v_count IS NULL THEN
        RAISE EXCEPTION 'the opening count was not created';
    END IF;

    -- It must still be a DRAFT. This file posts nothing.
    IF (SELECT status FROM public.med_counts WHERE id = v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the opening count is not a draft';
    END IF;

    -- All seven products exist now.
    SELECT count(*) INTO n FROM public.medications
     WHERE name IN ('Cydectin','Dectomax','Draxxin KP','Estrumate','Multi Min','One Grass','Synovex S');
    IF n <> 7 THEN
        RAISE EXCEPTION 'expected the 7 new medications, found %', n;
    END IF;

    -- Ten lines, and the five priced ones reproduce Redwing to the cent.
    SELECT count(*) INTO n FROM public.med_count_lines WHERE count_id = v_count;
    IF n <> 10 THEN
        RAISE EXCEPTION 'expected 10 count lines, found %', n;
    END IF;

    SELECT round(SUM(counted_units * unit_cost), 2) INTO v_value
      FROM public.med_count_lines
     WHERE count_id = v_count AND unit_cost IS NOT NULL;

    -- 69.44 + 3854.87 + 4153.81 + 38.38 + 121.00
    IF v_value <> 8237.50 THEN
        RAISE EXCEPTION 'the priced lines come to %, expected 8237.50 - that is Redwing''s own extended amounts for those five products', v_value;
    END IF;

    -- And nothing has been booked: no layer, no ledger row, nothing live.
    SELECT count(*) INTO v_posted FROM public.med_purchase_lines;
    IF v_posted <> 0 THEN
        RAISE EXCEPTION 'there are already % FIFO layer(s); this file expected an empty ledger', v_posted;
    END IF;
    SELECT count(*) INTO v_posted FROM public.med_txns;
    IF v_posted <> 0 THEN
        RAISE EXCEPTION 'there are already % ledger row(s); this file expected an empty ledger', v_posted;
    END IF;

    RAISE NOTICE 'VERIFIED: 7 medications added, opening count draft with 10 lines, $8,237.50 priced, nothing posted.';
END
$verify$;

commit;
