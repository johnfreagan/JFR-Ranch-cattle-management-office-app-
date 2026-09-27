-- =====================================================================
-- Withdrawal holds (2026-09-27)
-- =====================================================================
-- One row per (lot, tag) still inside a slaughter withdrawal period from a
-- doctoring treatment:
--     clear_date = treat date + medications.withdrawal_days
-- kept only while clear_date is after today. When a tag got several drugs
-- the row is the drug with the LATEST clear date, which is the one that
-- decides when the animal can ship.
--
-- Source is doctoring only: doctoring_events -> doctoring_event_meds ->
-- medications. Meds with a NULL or 0 withdrawal_days are skipped, and so is
-- a free-text med (no medications row, so no withdrawal on record).
-- Processing meds given at receiving (delivery_receipts -> protocol_meds)
-- are NOT here; that is a separate question.
--
-- doctoring_events.drug_off is NOT withdrawal: it records that a dead
-- animal was dragged out of the field. It is not read here.
--
-- Treat date is the Chicago calendar day of event_datetime, and "today" is
-- public.ranch_today(), not CURRENT_DATE: the database runs UTC, and
-- CURRENT_DATE turns over at 7pm Central (the lot_daily_head trap).
--
-- The app WARNS on a sale or a shipment when a lot has holds clearing after
-- the ship date, lists tag / drug / clear date, and saves on Confirm. It
-- never blocks. Because this view only keeps holds that are still live
-- today, a sale entered after the fact checks the holds live today.
--
-- security_invoker: reads through the base tables' RLS
-- (can_read_operational: crew included; no dollar column here).
-- =====================================================================

begin;

CREATE OR REPLACE VIEW public.withdrawal_holds
WITH (security_invoker = true) AS
WITH treated AS (
    SELECT de.lot_id,
           de.tag_number,
           de.id AS doctoring_event_id,
           m.name AS drug,
           m.withdrawal_days,
           (de.event_datetime AT TIME ZONE 'America/Chicago')::date AS treat_date,
           (de.event_datetime AT TIME ZONE 'America/Chicago')::date + m.withdrawal_days AS clear_date
      FROM public.doctoring_events de
      JOIN public.doctoring_event_meds dem ON dem.doctoring_event_id = de.id
      JOIN public.medications m ON m.id = dem.medication_id
     WHERE COALESCE(m.withdrawal_days, 0) > 0
)
SELECT DISTINCT ON (t.lot_id, t.tag_number)
       t.lot_id,
       l.lot_number,
       t.tag_number,
       t.drug,
       t.treat_date,
       t.withdrawal_days,
       t.clear_date,
       t.doctoring_event_id
  FROM treated t
  JOIN public.lots l ON l.id = t.lot_id
 WHERE t.clear_date > public.ranch_today()
 ORDER BY t.lot_id, t.tag_number, t.clear_date DESC, t.drug;

COMMENT ON VIEW public.withdrawal_holds IS
    'One row per (lot, tag) still in slaughter withdrawal from doctoring: the drug with the latest clear_date (treat date + withdrawal_days) after ranch_today(). Warns on sale; never blocks. drug_off is unrelated (carcass dragged out).';

REVOKE ALL ON public.withdrawal_holds FROM PUBLIC, anon;
GRANT SELECT ON public.withdrawal_holds TO authenticated;

DO $v$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class
                    WHERE oid = 'public.withdrawal_holds'::regclass
                      AND reloptions @> ARRAY['security_invoker=true']) THEN
        RAISE EXCEPTION 'withdrawal_holds is not security_invoker';
    END IF;
    IF has_table_privilege('anon', 'public.withdrawal_holds', 'SELECT') THEN
        RAISE EXCEPTION 'anon can read withdrawal_holds';
    END IF;
END;
$v$;

commit;
