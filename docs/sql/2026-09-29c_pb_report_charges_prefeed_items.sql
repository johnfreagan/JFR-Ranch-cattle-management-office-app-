CREATE OR REPLACE FUNCTION public.pb_report_charges(p_date date) RETURNS jsonb
LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $$
  WITH r AS (SELECT * FROM pb_daily_reports WHERE report_date = p_date),
  rows AS (
    SELECT p.lot_id, p.item_id, p.qty_lb FROM r, LATERAL pb_plan(r.id) p WHERE r.status = 'pending' AND p.lot_id IS NOT NULL
    UNION ALL
    SELECT u.lot_id, u.item_id, u.qty_lb FROM r JOIN feed_usage u ON u.pb_row_key LIKE format('pbmail:%s:%%', r.report_date)
     WHERE r.status = 'approved' AND u.destination_type = 'lot'),
  per_lot AS (
    SELECT lo.lot_number, SUM(x.qty_lb) lb,
           jsonb_agg(jsonb_build_object('item', i.name, 'lb', x.qty_lb) ORDER BY i.name) items
      FROM (SELECT lot_id, item_id, SUM(qty_lb) qty_lb FROM rows GROUP BY 1,2) x
      JOIN lots lo ON lo.id = x.lot_id JOIN feed_items i ON i.id = x.item_id
     GROUP BY lo.lot_number),
  pre AS (
    SELECT p.prefeed_pasture_id AS pasture_id, p.item_id, p.qty_lb, 'will hold'::text AS state, NULL::date AS charged_on, NULL::text AS err
      FROM r, LATERAL pb_plan(r.id) p WHERE r.status = 'pending' AND p.prefeed_pasture_id IS NOT NULL
    UNION ALL
    SELECT h.pasture_id, h.item_id, h.qty_lb, h.status, h.charged_on, h.last_error
      FROM r JOIN feed_prefeed_holds h ON h.report_id = r.id),
  pre_items AS (
    SELECT pasture_id, state, charged_on, item_id, SUM(qty_lb) qty_lb, max(err) err FROM pre GROUP BY 1,2,3,4),
  per_pre AS (
    SELECT rn.name || ' ' || pa.name AS pasture, x.state, x.charged_on, SUM(x.qty_lb) lb,
           jsonb_agg(jsonb_build_object('item', i.name, 'lb', x.qty_lb) ORDER BY i.name) items,
           max(x.err) AS error
      FROM pre_items x JOIN pastures pa ON pa.id = x.pasture_id JOIN ranches rn ON rn.id = pa.ranch_id JOIN feed_items i ON i.id = x.item_id
     GROUP BY 1,2,3)
  SELECT jsonb_build_object(
    'basis', (SELECT CASE WHEN status = 'approved' THEN 'posted' ELSE 'plan' END FROM r),
    'total_lb', COALESCE((SELECT SUM(lb) FROM per_lot), 0) + COALESCE((SELECT SUM(lb) FROM per_pre), 0),
    'lots', COALESCE((SELECT jsonb_agg(jsonb_build_object('lot', lot_number, 'lb', lb, 'items', items) ORDER BY lb DESC) FROM per_lot), '[]'),
    'prefeed', COALESCE((SELECT jsonb_agg(jsonb_build_object('pasture', pasture, 'state', state, 'charged_on', charged_on, 'lb', lb, 'items', items, 'error', error)) FROM per_pre), '[]'))
$$;
REVOKE EXECUTE ON FUNCTION public.pb_report_charges(date) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.pb_report_charges(date) TO authenticated;