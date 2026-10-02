-- STATUS 2026-10-02: NOT APPLIED. Tested in a forced-rollback run against the
-- real #6654 email (John: "Test", 14:06 CT) - passed, rolled back clean.
-- John said "Apply" 14:08 CT; the apply_migration approval prompt was
-- cancelled, so nothing is live yet.
-- 2026-10-02, Claude Code session: apply_migration tried four times (whole
-- file, and once tables-only); every call timed out at 60s and nothing
-- reached the database (no tables, no functions, nothing in the migration
-- list, no query running). Still NOT APPLIED. The app's Approvals > Meds is
-- deployed and says so until this runs. Same file passed in a scratch
-- Postgres 16 with the real #6654 text: md5(prosrc) to compare against once
-- live - med_alias_learn 78ffa2932337747169ab2c8073e26cde,
-- med_parse_barj_invoice 25e41e836a3c34518827fcfcb1492fa0,
-- reject_med_invoice bfa3b61c766ff028e2fdbe3640c0a9ea,
-- stage_med_invoice fd058df6e7ba0805e0e8b3242d45cc1d.

-- Bar J vet-med invoices: email -> staged intake -> Approvals > Meds -> purchase.
--
-- John, 2026-10-02: "For medicines the only vendor is Bar J for now. Put into
-- the approvals first. Must-answer box on location in approvals. Ask on new
-- meds but be prepared to build item. 4am triage for now."
--
-- Flow
--   1. The 4am triage run finds Bar J invoice emails (Lightspeed receipts, sent
--      to Lauren and forwarded) and calls stage_med_invoice(message_id, body)
--      with the plain-text body VERBATIM. The database parses it; the model
--      never does the arithmetic (D15).
--   2. Approvals > Meds lists pending intakes. Review opens the existing
--      Purchases grid pre-filled. "Received to" starts blank and must be
--      chosen. Unmatched names stop and ask (pick, or build a new medication).
--      The grid's tie-out to the invoice total still gates posting.
--   3. Posting writes med_purchases with intake_id set. The unique index on
--      intake_id is what stops a second post of the same invoice. Deleting the
--      purchase puts the invoice straight back in the queue.
--   4. Every line John matched by hand is remembered in med_name_aliases, so
--      the next invoice with the same Bar J item name matches on its own. A
--      remembered alias is John's own pick, never a guess.
--
-- Nothing here posts to inventory. Only the app's Post button does.

begin;

CREATE TABLE IF NOT EXISTS public.med_invoice_intake (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor           text NOT NULL,
  invoice_number   text NOT NULL,
  invoice_date     date NOT NULL,
  invoice_total    numeric(12,2) NOT NULL,
  item_count       integer,
  lines            jsonb NOT NULL DEFAULT '[]'::jsonb,
  problems         text[] NOT NULL DEFAULT '{}',
  gmail_message_id text NOT NULL,
  raw_text         text NOT NULL,
  status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','rejected')),
  staged_at        timestamptz NOT NULL DEFAULT now(),
  reviewed_by      uuid,
  reviewed_at      timestamptz,
  review_notes     text,
  CONSTRAINT med_invoice_intake_uniq UNIQUE (vendor, invoice_number)
);
COMMENT ON TABLE public.med_invoice_intake IS
 'Vet-med invoices read off email, waiting in Approvals > Meds. Posted = a med_purchases row carries this id in intake_id; status only records a rejection.';
COMMENT ON COLUMN public.med_invoice_intake.lines IS
 'Parsed lines: [{name, qty, unit_price, line_total, bottle_size, unit}]. bottle_size is read from the item name (e.g. "250 ml") and is NULL when the name does not state one.';

ALTER TABLE public.med_purchases ADD COLUMN IF NOT EXISTS intake_id uuid
  REFERENCES public.med_invoice_intake(id) ON DELETE SET NULL;
CREATE UNIQUE INDEX IF NOT EXISTS med_purchases_intake_uniq
  ON public.med_purchases (intake_id) WHERE intake_id IS NOT NULL;
COMMENT ON COLUMN public.med_purchases.intake_id IS
 'The emailed invoice this purchase was posted from. Unique: one invoice posts once.';

CREATE TABLE IF NOT EXISTS public.med_name_aliases (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor        text NOT NULL,
  alias         text NOT NULL,
  medication_id uuid NOT NULL REFERENCES public.medications(id) ON DELETE CASCADE,
  bottle_size   numeric CHECK (bottle_size IS NULL OR bottle_size > 0),
  created_by    uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS med_name_aliases_uniq
  ON public.med_name_aliases (lower(vendor), lower(alias));
COMMENT ON TABLE public.med_name_aliases IS
 'Vendor item name -> our medication, written only when John matches a line by hand while posting an emailed invoice.';

ALTER TABLE public.med_invoice_intake ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.med_name_aliases   ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['med_invoice_intake','med_name_aliases'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %1$s_select ON public.%1$s', t);
    EXECUTE format('DROP POLICY IF EXISTS %1$s_insert ON public.%1$s', t);
    EXECUTE format('DROP POLICY IF EXISTS %1$s_update ON public.%1$s', t);
    EXECUTE format('DROP POLICY IF EXISTS %1$s_delete ON public.%1$s', t);
    EXECUTE format('CREATE POLICY %1$s_select ON public.%1$s FOR SELECT TO authenticated USING (can_read_books())', t);
    EXECUTE format('CREATE POLICY %1$s_insert ON public.%1$s FOR INSERT TO authenticated WITH CHECK (current_user_role() = ANY (ARRAY[''owner'',''office'']))', t);
    EXECUTE format('CREATE POLICY %1$s_update ON public.%1$s FOR UPDATE TO authenticated USING (current_user_role() = ANY (ARRAY[''owner'',''office''])) WITH CHECK (current_user_role() = ANY (ARRAY[''owner'',''office'']))', t);
    EXECUTE format('CREATE POLICY %1$s_delete ON public.%1$s FOR DELETE TO authenticated USING (current_user_role() = ''owner'')', t);
  END LOOP;
END $$;

REVOKE ALL ON public.med_invoice_intake, public.med_name_aliases FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.med_invoice_intake, public.med_name_aliases TO authenticated;

-- Parse one Bar J (Lightspeed) receipt. Pure: no writes, so it can be tested
-- on any text. Problems are reported, never fixed.
CREATE OR REPLACE FUNCTION public.med_parse_barj_invoice(p_text text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_txt    text := replace(coalesce(p_text, ''), E'\r', '');
  m        text[];
  v_no     text;
  v_date   date;
  v_total  numeric;
  v_items  integer;
  v_lines  jsonb := '[]'::jsonb;
  v_probs  text[] := '{}';
  v_qty    numeric;
  v_price  numeric;
  v_ext    numeric;
  v_name   text;
  v_size   numeric;
  v_sum    numeric := 0;
BEGIN
  IF v_txt !~* 'Bar J Vet Supply' THEN
    RETURN jsonb_build_object('ok', false, 'problems', jsonb_build_array('Not a Bar J Vet Supply invoice.'));
  END IF;

  m := regexp_match(v_txt, 'Invoice #\s*([0-9A-Za-z-]+)\s+([0-9]{1,2} [A-Za-z]{3} [0-9]{4})');
  IF m IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'problems', jsonb_build_array('No invoice number and date found.'));
  END IF;
  v_no   := m[1];
  v_date := to_date(m[2], 'DD Mon YYYY');

  m := regexp_match(v_txt, 'TOTAL[ \t]+([0-9]+)[ \t]+items?[ \t]+\$([0-9,]+\.[0-9]{2})', 'i');
  IF m IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'problems', jsonb_build_array('No TOTAL line found.'));
  END IF;
  v_items := m[1]::int;
  v_total := replace(m[2], ',', '')::numeric;

  -- "1 Macrosyn 250 ml - Prestige @ $211.88" then "$211.88" on the next line.
  FOR m IN
    SELECT regexp_matches(v_txt,
      '^[ \t]*([0-9]+(?:\.[0-9]+)?)[ \t]+(.+)[ \t]+@[ \t]+\$([0-9,]+\.[0-9]{2})[ \t]*\n[ \t]*\$([0-9,]+\.[0-9]{2})',
      'gn')
  LOOP
    v_qty   := m[1]::numeric;
    v_name  := btrim(m[2]);
    v_price := replace(m[3], ',', '')::numeric;
    v_ext   := replace(m[4], ',', '')::numeric;
    v_size  := (regexp_match(v_name, '([0-9]+(?:\.[0-9]+)?)[ \t]*ml\M', 'i'))[1]::numeric;
    IF abs(v_qty * v_price - v_ext) > 0.01 THEN
      v_probs := v_probs || format('%s: %s x $%s is not the line total $%s.', v_name, v_qty, v_price, v_ext);
    END IF;
    v_sum   := v_sum + v_ext;
    v_lines := v_lines || jsonb_build_object(
      'name', v_name, 'qty', v_qty, 'unit_price', v_price, 'line_total', v_ext,
      'bottle_size', v_size, 'unit', CASE WHEN v_size IS NULL THEN NULL ELSE 'mL' END);
  END LOOP;

  IF jsonb_array_length(v_lines) = 0 THEN
    v_probs := v_probs || 'No product lines found.'::text;
  ELSIF jsonb_array_length(v_lines) <> v_items THEN
    v_probs := v_probs || format('Invoice says %s item(s); %s line(s) read.', v_items, jsonb_array_length(v_lines));
  END IF;
  IF abs(v_sum - v_total) > 0.01 THEN
    v_probs := v_probs || format('Lines add to $%s; invoice total is $%s.', v_sum, v_total);
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'vendor', 'Bar J Vet Supply', 'invoice_number', v_no,
    'invoice_date', v_date, 'invoice_total', v_total, 'item_count', v_items,
    'lines', v_lines, 'problems', to_jsonb(v_probs));
END
$function$;

-- Stage one emailed invoice. Idempotent on (vendor, invoice_number): the same
-- invoice arriving twice (direct and forwarded) stages once.
CREATE OR REPLACE FUNCTION public.stage_med_invoice(p_message_id text, p_text text)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v jsonb := med_parse_barj_invoice(p_text);
  r med_invoice_intake%ROWTYPE;
  v_posted boolean;
BEGIN
  IF NOT (v->>'ok')::boolean THEN
    RAISE EXCEPTION 'stage_med_invoice: %', v->'problems'->>0;
  END IF;

  SELECT * INTO r FROM med_invoice_intake
   WHERE vendor = v->>'vendor' AND invoice_number = v->>'invoice_number';
  IF FOUND THEN
    v_posted := EXISTS (SELECT 1 FROM med_purchases WHERE intake_id = r.id);
    RETURN jsonb_build_object('staged', false, 'reason', 'already staged',
      'vendor', r.vendor, 'invoice_number', r.invoice_number,
      'status', CASE WHEN v_posted THEN 'posted' ELSE r.status END);
  END IF;

  INSERT INTO med_invoice_intake (vendor, invoice_number, invoice_date, invoice_total,
       item_count, lines, problems, gmail_message_id, raw_text)
  VALUES (v->>'vendor', v->>'invoice_number', (v->>'invoice_date')::date,
       (v->>'invoice_total')::numeric, (v->>'item_count')::int, v->'lines',
       ARRAY(SELECT jsonb_array_elements_text(v->'problems')), p_message_id, p_text)
  RETURNING * INTO r;

  RETURN jsonb_build_object('staged', true, 'id', r.id, 'vendor', r.vendor,
    'invoice_number', r.invoice_number, 'invoice_date', r.invoice_date,
    'invoice_total', r.invoice_total, 'lines', r.lines, 'problems', to_jsonb(r.problems));
END
$function$;

CREATE OR REPLACE FUNCTION public.reject_med_invoice(p_intake_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF coalesce(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'reject_med_invoice: say why.';
  END IF;
  IF EXISTS (SELECT 1 FROM med_purchases WHERE intake_id = p_intake_id) THEN
    RAISE EXCEPTION 'reject_med_invoice: this invoice is posted. Delete the purchase first.';
  END IF;
  UPDATE med_invoice_intake
     SET status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), review_notes = p_reason
   WHERE id = p_intake_id AND status = 'pending';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reject_med_invoice: no pending invoice with that id (or not allowed).';
  END IF;
  RETURN jsonb_build_object('ok', true);
END
$function$;

-- Remember John's own match. Called by the app after a successful post.
CREATE OR REPLACE FUNCTION public.med_alias_learn(p_vendor text, p_alias text, p_medication_id uuid, p_bottle_size numeric)
RETURNS void
LANGUAGE sql
SET search_path TO 'public', 'pg_temp'
AS $function$
  INSERT INTO med_name_aliases (vendor, alias, medication_id, bottle_size, created_by)
  VALUES (p_vendor, p_alias, p_medication_id, p_bottle_size, auth.uid())
  ON CONFLICT (lower(vendor), lower(alias)) DO UPDATE
     SET medication_id = EXCLUDED.medication_id,
         bottle_size   = EXCLUDED.bottle_size,
         updated_at    = now();
$function$;

REVOKE ALL ON FUNCTION
  public.med_parse_barj_invoice(text),
  public.stage_med_invoice(text, text),
  public.reject_med_invoice(uuid, text),
  public.med_alias_learn(text, text, uuid, numeric)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.med_parse_barj_invoice(text),
  public.stage_med_invoice(text, text),
  public.reject_med_invoice(uuid, text),
  public.med_alias_learn(text, text, uuid, numeric)
TO authenticated;

commit;
