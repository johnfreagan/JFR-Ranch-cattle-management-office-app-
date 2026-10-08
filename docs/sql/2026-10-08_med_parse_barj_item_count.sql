-- STATUS: Applied 2026-10-08 on John's approval ("Fix parser."). Tested
-- first in a scratch Postgres 16 (6654 clean, 6741 clean, a dropped-line copy
-- still flagged on count and dollars) and in a forced-rollback run on live.
-- Verified after apply: md5(prosrc) = 05b62d7267e2a366f8f633b3fc80eddb, the
-- file's; anon cannot execute; rls_verify passes; #6741's problems now {}.
--
-- Bar J parser: "TOTAL n items" is a count of units, not of lines.
--
-- Bar J #6741 (7 Oct 2026) staged with a false problem: "Invoice says 8
-- item(s); 6 line(s) read." It has 6 lines whose quantities are
-- 1 + 2 + 2 + 1 + 1 + 1 = 8, and the lines add to the $1,668.33 total to the
-- cent. Lightspeed counts units. med_parse_barj_invoice compared the count
-- to the number of lines, so any invoice with a quantity above 1 was flagged.
-- #6654 (1 + 1, two lines) could not show it.
--
-- John, 2026-10-08: "Fix parser."
--
-- Change: compare "TOTAL n items" with the sum of the quantities read. A
-- real miss (a line the pattern did not read) still shows, because a dropped
-- line also drops its quantity, and the dollar check still runs beside it.
-- Nothing else in the function changes.
--
-- Also re-reads the problems of every staged invoice that is still waiting
-- (pending, no purchase) from its own raw_text, so #6741 loses the false
-- flag. Lines, totals and everything else on those rows are left alone; a
-- posted or rejected invoice is not touched.

begin;

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
  v_bottles numeric := 0;
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
    v_bottles := v_bottles + v_qty;
    v_lines := v_lines || jsonb_build_object(
      'name', v_name, 'qty', v_qty, 'unit_price', v_price, 'line_total', v_ext,
      'bottle_size', v_size, 'unit', CASE WHEN v_size IS NULL THEN NULL ELSE 'mL' END);
  END LOOP;

  IF jsonb_array_length(v_lines) = 0 THEN
    v_probs := v_probs || 'No product lines found.'::text;
  ELSIF v_bottles <> v_items THEN
    -- Lightspeed's "TOTAL n items" counts units (2 Macrosyn = 2 items), not
    -- lines, so it is checked against the quantities read.
    v_probs := v_probs || format('Invoice says %s item(s); the lines read add to %s.', v_items, v_bottles);
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

-- Re-read problems on waiting invoices only.
UPDATE public.med_invoice_intake i
   SET problems = ARRAY(SELECT jsonb_array_elements_text(
                    public.med_parse_barj_invoice(i.raw_text)->'problems'))
 WHERE i.status = 'pending'
   AND i.vendor = 'Bar J Vet Supply'
   AND NOT EXISTS (SELECT 1 FROM public.med_purchases p WHERE p.intake_id = i.id);

-- CREATE OR REPLACE keeps the grants, but say it again: rule 4.
REVOKE ALL ON FUNCTION public.med_parse_barj_invoice(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.med_parse_barj_invoice(text) TO authenticated;

commit;
