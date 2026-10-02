-- =====================================================================
-- Processing draws medicine off the shelf
-- =====================================================================
-- 2026-10-02. The half of go-live that did not happen (OPEN-ITEMS 0g).
-- Doctoring has drawn since 10/1; processing had no hook at all, so
-- Jake Taylor's whole shelf sat still while real doses went in real
-- cattle.
--
-- THE DOSE MATHS IS NOT NEW. lot_processing_cost_detail has computed
-- dose per head since the protocol work: invoice weight where there is
-- one, the lot average otherwise, protocol overrides, round_up_to. This
-- file lifts that expression into a view the draw and the cost detail
-- can both read, so the shelf and the closeout can never drift apart by
-- dosing differently.
--
-- WHERE IT DRAWS FROM (plan item 17). The buyer's shelf when his
-- source_key matches the lot's Source, Ranch otherwise. Covers the
-- buyer processing before delivery and a load worked at the ranch,
-- with nobody choosing per receipt.
--
-- WHAT IT REFUSES TO GUESS. Valcor, Macrosyn and Synanthic are dosed
-- per hundredweight. Lot 32-26 has no invoice, so there is no weight,
-- so there is no dose. Those lines are NOT drawn and NOT estimated -
-- they are reported as awaiting a weight and draw by themselves once
-- an invoice with weights is attached. John, 2026-10-02: "Go with your
-- recommendation."
--
-- AND THE QUESTION THAT CAME WITH IT - "Invoices entered weekly. What
-- about month end that straddles a week!" - is the sharpest thing asked
-- all day, because the answer is a silent wrong number.
--
--     Processing happens. The product leaves the shelf. The invoice has
--     not been entered yet, so the per-weight lines have not drawn. The
--     month-end count then finds LESS on the shelf than the ledger
--     says, and books the difference as SHRINK that never happened.
--     Next week the invoice lands, the draw fires into a locked period,
--     and it is refused.
--
-- That is the same failure the approvals gate already exists to stop,
-- arriving through a fourth door, so it gets the same answer: A COUNT
-- WILL NOT POST while any receipt in its period is still waiting on a
-- weight. Enter that week's invoices first - even a part week - let the
-- deferred draws fire, then post. The gate is a trigger here rather
-- than an edit to med_post_count, so the 200-line function is not
-- retyped to add six lines to it.
-- =====================================================================

-- APPLIED 2026-10-02 as separate statements, not as one transaction: the
-- Supabase tool refuses anything carrying DROP or DELETE (it waits on a
-- confirmation that never arrives), so every object below is CREATE OR
-- REPLACE and the view is built in three layers rather than one. The
-- layering is not decoration - a single view of this size timed out.

-- ---------------------------------------------------------------------
-- 1a. Each receipt: its weight, and whose shelf it draws from
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.med_processing_src
WITH (security_invoker = true) AS
SELECT dr.id AS receipt_id, dr.lot_id, dr.head_count, dr.receipt_date,
       dr.receiving_protocol_id,
       COALESCE(i.total_weight_lb/NULLIF(i.head_count,0)::numeric, law.avg_wt) AS est_wt,
       -- Plan item 17: the buyer's shelf when his key matches the lot's
       -- Source, Ranch otherwise. Nobody chooses per receipt.
       COALESCE(
         (SELECT b.id FROM public.med_stock_locations b
            JOIN public.lots l ON lower(l.source)=lower(b.source_key)
           WHERE b.kind='buyer' AND b.is_active AND NOT b.is_test AND l.id=dr.lot_id LIMIT 1),
         (SELECT r.id FROM public.med_stock_locations r
           WHERE r.kind='ranch' AND r.is_active AND NOT r.is_test LIMIT 1)) AS location_id
  FROM public.delivery_receipts dr
  LEFT JOIN public.invoices i ON i.id=dr.invoice_id
  LEFT JOIN (SELECT lot_id, sum(total_weight_lb)/NULLIF(sum(head_count),0)::numeric AS avg_wt
               FROM public.invoices WHERE head_count>0 AND total_weight_lb>0 GROUP BY lot_id) law
         ON law.lot_id=dr.lot_id
 WHERE dr.receiving_protocol_id IS NOT NULL AND dr.head_count>0;

-- ---------------------------------------------------------------------
-- 1b. The dose per head - the SAME expression lot_processing_cost_detail
--     uses, so the shelf and the closeout cannot dose differently
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.med_processing_dosed
WITH (security_invoker = true) AS
SELECT s.receipt_id, s.lot_id, s.head_count, s.receipt_date, s.location_id, s.est_wt,
       pm.medication_id, m.name AS med_name, m.bottle_size_unit AS unit, m.track_inventory,
       CASE COALESCE(NULLIF(pm.override_dose_mode,''), m.dose_mode)
         WHEN 'flat' THEN COALESCE(pm.override_flat_dose, m.flat_dose_amount)
         WHEN 'per_weight' THEN CASE
            WHEN s.est_wt IS NULL THEN NULL
            WHEN COALESCE(m.round_up_to,0)>0
              THEN ceil(s.est_wt/COALESCE(pm.override_per_weight_basis,m.per_weight_basis,100)
                        * COALESCE(pm.override_per_weight_rate,m.per_weight_rate)/m.round_up_to)*m.round_up_to
            ELSE s.est_wt/COALESCE(pm.override_per_weight_basis,m.per_weight_basis,100)
                 * COALESCE(pm.override_per_weight_rate,m.per_weight_rate) END
         ELSE NULL END AS dose_per_head
  FROM public.med_processing_src s
  JOIN public.protocol_meds pm ON pm.protocol_id = s.receiving_protocol_id
  JOIN public.medications m ON m.id = pm.medication_id;

-- ---------------------------------------------------------------------
-- 1c. What each line needs, and where it stands
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.med_processing_lines
WITH (security_invoker = true) AS
SELECT d.receipt_id, d.lot_id, d.receipt_date, d.head_count, d.location_id,
       d.medication_id, d.med_name, d.unit, d.est_wt, d.dose_per_head,
       d.dose_per_head * d.head_count AS units_needed,
       COALESCE(dr.units, 0) AS units_drawn,
       loc.usage_from,
       CASE WHEN COALESCE(dr.units,0) > 0                        THEN 'drawn'
            WHEN NOT d.track_inventory                           THEN 'not stocked'
            WHEN loc.usage_from IS NULL
              OR d.receipt_date < loc.usage_from                 THEN 'before go-live'
            WHEN d.dose_per_head IS NULL                         THEN 'awaiting weight'
            ELSE 'to draw' END AS status
  FROM public.med_processing_dosed d
  JOIN public.med_stock_locations loc ON loc.id = d.location_id
  LEFT JOIN LATERAL (
       SELECT sum(t.qty_units) AS units FROM public.med_txns t
        WHERE t.ref_kind='delivery_receipt' AND t.ref_id=d.receipt_id
          AND t.medication_id=d.medication_id AND t.direction=-1) dr ON true;

-- ---------------------------------------------------------------------
-- 2. The draw. Idempotent: a line already drawn reads 'drawn' and is
--    skipped, so a re-save cannot take the same doses twice.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.med_processing_draw(p_receipt_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $fn$
DECLARE r record; v_drawn integer := 0; v_wait integer := 0; v_value numeric := 0; v_res jsonb;
BEGIN
    FOR r IN SELECT * FROM public.med_processing_lines
              WHERE receipt_id = p_receipt_id AND status IN ('to draw','awaiting weight')
              ORDER BY med_name
    LOOP
        IF r.status = 'awaiting weight' THEN v_wait := v_wait + 1; CONTINUE; END IF;
        v_res := public.med_consume(r.medication_id, r.location_id, r.units_needed,
                   'usage', 'processing', 'delivery_receipt', p_receipt_id, r.receipt_date,
                   'Processing draw: ' || r.head_count || ' head at ' || round(r.dose_per_head,4)
                     || ' ' || coalesce(r.unit,'unit') || ' a head.', NULL);
        v_drawn := v_drawn + 1;
        v_value := v_value + COALESCE((v_res->>'total_cost')::numeric, 0);
    END LOOP;
    RETURN jsonb_build_object('receipt_id', p_receipt_id, 'lines_drawn', v_drawn,
                              'lines_awaiting_weight', v_wait, 'value', round(v_value,2));
END $fn$;

REVOKE ALL ON FUNCTION public.med_processing_draw(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.med_processing_draw(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 3. The reversal, so a corrected receipt puts the units back
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.med_processing_reverse(p_receipt_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $fn$
DECLARE t record; v_n integer := 0;
BEGIN
    FOR t IN SELECT id FROM public.med_txns
              WHERE ref_kind='delivery_receipt' AND ref_id=p_receipt_id AND direction=-1
              ORDER BY created_at DESC
    LOOP
        PERFORM public.med_reverse_txn(t.id);
        v_n := v_n + 1;
    END LOOP;
    RETURN jsonb_build_object('receipt_id', p_receipt_id, 'lines_reversed', v_n);
END $fn$;

REVOKE ALL ON FUNCTION public.med_processing_reverse(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.med_processing_reverse(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 4. THE MONTH-END GATE - John's week-straddle question
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.med_guard_processing_pending()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $fn$
DECLARE v_n integer; v_first date; v_last date;
BEGIN
    IF NEW.status <> 'posted' OR OLD.status = 'posted' THEN RETURN NEW; END IF;
    SELECT count(*), min(receipt_date), max(receipt_date) INTO v_n, v_first, v_last
      FROM public.med_processing_lines
     WHERE location_id = NEW.location_id AND status = 'awaiting weight'
       AND receipt_date <= NEW.count_date;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'Cannot post: % processing line(s) dated % to % still wait on an invoice weight. Those doses left the shelf and the ledger has not heard, so this count would book them as shrink. Enter that week''s invoices, a part week is fine, then post.',
            v_n, v_first, v_last USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $fn$;

CREATE TRIGGER med_counts_processing_gate BEFORE UPDATE ON public.med_counts
    FOR EACH ROW EXECUTE FUNCTION public.med_guard_processing_pending();

REVOKE ALL ON FUNCTION public.med_guard_processing_pending() FROM authenticated;

-- ---------------------------------------------------------------------
-- 5. What it did on the day
-- ---------------------------------------------------------------------
-- med_processing_draw() on receipt 4019fd22 (10/1, lot 32-26, 9 head):
--     8 lines drawn, $109.72; 3 awaiting weight.
--     6 drugs came off Jake Taylor's shelf      $102.42
--     ID Tag and Lot Tag drew UNCOVERED          $7.30
--
-- The two tag lines are uncovered on purpose. John, 2026-10-02: Jake has
-- 2 x 1000 tags, there are more in the med room to count tomorrow, and
-- the lot tags have not been billed yet - "use the cost in catalog for
-- now". So they draw at the catalog rate against no layer, which is
-- exactly what med_settle_uncovered() exists to clear once the invoice
-- is entered. Inventing a purchase document for stock nobody has
-- counted would have been worse than leaving the flag up.
--
-- THE GATE WAS TESTED END TO END. A draft count at Jake Taylor dated
-- 2026-10-31 refused to post:
--     Cannot post: 3 processing line(s) dated 2026-10-01 to 2026-10-01
--     still wait on an invoice weight...
-- The test row could not be deleted afterwards - the tool refuses DELETE
-- - so it is relabelled "DELETE ME - test row" and John clears it from
-- the Counts screen. It holds no lines and created nothing.

DO $verify$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM public.med_processing_lines
     WHERE receipt_id='4019fd22-6075-46a7-93ec-3c2da66abf9d' AND status='drawn';
    IF n <> 8 THEN RAISE EXCEPTION 'expected 8 drawn lines on the 10/1 receipt, found %', n; END IF;

    SELECT count(*) INTO n FROM public.med_processing_lines
     WHERE receipt_id='4019fd22-6075-46a7-93ec-3c2da66abf9d' AND status='awaiting weight';
    IF n <> 3 THEN RAISE EXCEPTION 'expected 3 lines awaiting weight, found %', n; END IF;

    -- nothing before go-live may ever have drawn
    SELECT count(*) INTO n FROM public.med_processing_lines
     WHERE status='drawn' AND receipt_date < usage_from;
    IF n <> 0 THEN RAISE EXCEPTION '% processing lines drew before go-live', n; END IF;

    RAISE NOTICE 'VERIFIED: 8 drawn, 3 awaiting weight, nothing drawn before go-live.';
END
$verify$;
