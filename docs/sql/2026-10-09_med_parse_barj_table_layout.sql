-- STATUS: Applied 2026-10-09 on John's approval ("Apply it"). Verified after
-- apply: md5(prosrc) = 187cff849b7ca8199d4d12e5472327c1, the file's; anon
-- cannot execute; rls_verify passes; #6654 and #6741 re-read to identical
-- lines with no problems. #6758 staged the same day: 3 lines, $883.53, no
-- problems.
-- Tested before apply: scratch Postgres 16 (6654, 6741 unchanged; 6758 reads 3 lines,
-- 17 items, $883.53, no problems; a copy with one table row removed is
-- flagged on count and dollars) and a forced-rollback run on live (6654 and
-- 6741 re-read to identical lines with no problems; staging the real #6758
-- email succeeded inside the rolled-back transaction: 3 lines, $883.53, no
-- problems). md5(prosrc) = 187cff849b7ca8199d4d12e5472327c1.
--
-- Bar J parser: read the table layout as well as the line layout.
--
-- The 5:45 am Routine's first run with the medicine step (2026-10-09, fired
-- by hand as a test) found Bar J #6758 (8 Oct 2026, $883.53, Gmail
-- 1a11c2a6e5bab8df) and stage_med_invoice refused it: "No invoice number and
-- date found." Lauren forwarded that one from her iPhone, the forward has no
-- plain-text part, and the Gmail connector hands back the HTML rendered as
-- markdown tables:
--   | Invoice #6758 | 8 Oct 2026 10:31am |
--   | 15 | Bovi-Shield Gold 1 Shot 10 ds - Prestige | @ $43.48 | $652.20 |
--   | | TOTAL 17 items | $883.53 |
-- #6654 and #6741 came as plain text ("1 Name @ $x" then "$y" on the next
-- line) and still do.
--
-- Change, nothing else:
--   - the invoice-number and TOTAL patterns allow "|" between their parts;
--   - product lines are read from either layout. A table row starts with
--     "|" and a line-layout row cannot, so no line is read twice.
-- Every check stays: qty x price = line total, units = TOTAL n items, lines
-- add to the invoice total.

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

  -- "Invoice #6654 2 Oct 2026", or "| Invoice #6758 | 8 Oct 2026 |" when the
  -- forward reached Gmail as HTML only and the connector rendered it as a table.
  m := regexp_match(v_txt, 'Invoice #\s*([0-9A-Za-z-]+)[\s|]+([0-9]{1,2} [A-Za-z]{3} [0-9]{4})');
  IF m IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'problems', jsonb_build_array('No invoice number and date found.'));
  END IF;
  v_no   := m[1];
  v_date := to_date(m[2], 'DD Mon YYYY');

  m := regexp_match(v_txt, 'TOTAL[ \t]+([0-9]+)[ \t]+items?[ \t|]+\$([0-9,]+\.[0-9]{2})', 'i');
  IF m IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'problems', jsonb_build_array('No TOTAL line found.'));
  END IF;
  v_items := m[1]::int;
  v_total := replace(m[2], ',', '')::numeric;

  -- Line layout: "1 Macrosyn 250 ml - Prestige @ $211.88" then "$211.88" on
  -- the next line. Table layout: "| 15 | Bovi-Shield ... | @ $43.48 | $652.20 |".
  -- A table row starts with "|" and a line-layout row cannot, so no product
  -- line is read twice.
  FOR m IN
    SELECT regexp_matches(v_txt,
      '^[ \t]*([0-9]+(?:\.[0-9]+)?)[ \t]+(.+)[ \t]+@[ \t]+\$([0-9,]+\.[0-9]{2})[ \t]*\n[ \t]*\$([0-9,]+\.[0-9]{2})',
      'gn')
    UNION ALL
    SELECT regexp_matches(v_txt,
      '^[ \t]*\|[ \t]*([0-9]+(?:\.[0-9]+)?)[ \t]*\|[ \t]*([^|\n]+?)[ \t]*\|[ \t]*@[ \t]*\$([0-9,]+\.[0-9]{2})[ \t]*\|[ \t]*\$([0-9,]+\.[0-9]{2})[ \t]*\|',
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

-- CREATE OR REPLACE keeps the grants, but say it again: rule 4.
REVOKE ALL ON FUNCTION public.med_parse_barj_invoice(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.med_parse_barj_invoice(text) TO authenticated;

commit;
