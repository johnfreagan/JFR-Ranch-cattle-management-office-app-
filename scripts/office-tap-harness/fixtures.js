// A made-up ranch: one ranch, two pastures, one open lot with 50 head in North.
window.__uid = 'u-office';
const L = 'lot-1', P1 = 'pas-1', P2 = 'pas-2', R = 'ranch-1';
window.__db = {
  user_profiles: [{ id: 'u-office', full_name: 'Test Office', role: 'office', is_active: true }],
  ranches: [{ id: R, name: 'Home Place', is_active: true, owner: 'JFR' }],
  pastures: [{ id: P1, ranch_id: R, name: 'North', is_active: true, total_acres: 100, ranches: { name: 'Home Place', is_active: true } },
             { id: P2, ranch_id: R, name: 'South', is_active: true, total_acres: 80, ranches: { name: 'Home Place', is_active: true } }],
  lots: [{ id: L, lot_number: '2627-A', arrival_date: '2026-09-01', fiscal_year: 2027, is_test: false, is_feed_pen: false,
           closed_at: null, est_purchase_weight_lb: 500, cog_mode: 'per_lb', sex_class: 'steers', source: 'Sale barn' }],
  lot_status: [{ lot_id: L, id: L, lot_number: '2627-A', head_current: 50, head_in: 50, dead: 0, sold: 0, arrival_date: '2026-09-01',
                 fiscal_year: 2027, is_test: false, is_feed_pen: false, closed_at: null }],
  lot_pasture_assignments: [{ id: 'asg-1', lot_id: L, pasture_id: P1, head_count: 50, moved_in: '2026-09-01', moved_out: null,
                              pastures: { name: 'North', ranches: { name: 'Home Place', is_active: true } }, lots: { lot_number: '2627-A', closed_at: null } }],
  lot_head_tieout: [{ lot_id: L, lot_number: '2627-A', books_head: 50, pasture_head: 50, head_gap: 0, tags_registered: 50,
                      tags_expected: 50, tag_gap: 0, status: 'TIES', tag_flag: null }],
  pasture_status: [{ pasture_id: P1, id: P1, ranch_id: R, ranch_name: 'Home Place', pasture_name: 'North', is_active: true, current_head_total: 50 },
                   { pasture_id: P2, id: P2, ranch_id: R, ranch_name: 'Home Place', pasture_name: 'South', is_active: true, current_head_total: 0 }],
  field_actions: [{ id: 'act-1', name: 'Pull - BRD', sort_order: 1, requires_meds: false, requires_note: false, is_dead: false, once_per_animal: false, is_active: true },
                  { id: 'act-2', name: 'Dead', sort_order: 9, requires_meds: false, requires_note: false, is_dead: true, once_per_animal: true, is_active: true }],
  medications: [{ id: 'med-1', name: 'Draxxin', generic_category: 'tulathromycin', dose_mode: 'flat', flat_dose_amount: 5, is_active: true,
                  cost_per_unit: 10, slaughter_withdrawal_days: 18 }],
  protocols: [{ id: 'pro-1', name: 'Receiving', protocol_type: 'receiving', is_active: true }],
  lot_tags: Array.from({ length: 50 }, (_, i) => ({ id: 't' + i, tag_number: 101 + i, lot_id: L, status: 'active', fiscal_year: 2027 })),
  invoices: [], delivery_receipts: [], sales: [], lot_events: [], lot_movements: [{ id: '11111111-2222-3333-4444-555555555555', lot_id: L, move_date: '2026-10-02', head_count: 10, notes: null, created_at: '2026-10-02T15:00:00Z', from_pasture_id: P2, to_pasture_id: P1 }], doctoring_events: [],
  pending_field_entries: [], cost_centers: [{ name: 'Cow/Calf Wip', is_active: true }],
};
// ---- Approvals ----
window.__db.pending_field_entries = [
  { id: 'pfe-1', entry_type: 'doctoring', client_id: 'c-1', status: 'pending', event_datetime: '2026-10-02T15:00:00Z',
    submitted_at: '2026-10-02T15:05:00Z', submitted_by: 'u-crew', review_notes: null, resolved_detail: null, resolved_meds: null,
    lot_id: null, pasture_id: null, field_action_id: null, tag_number: '101',
    raw: { tagNumber: '101', lotNumber: '2627-A', location: 'Home Place - North', treatmentType: 'Pull - BRD',
           medication1: 'Draxxin', dosage1: '5', dateTime: '2026-10-02T10:00:00', recordedBy: 'Cody' } },
  { id: 'pfe-2', entry_type: 'doctoring', client_id: 'c-2', status: 'pending', event_datetime: '2026-10-02T16:00:00Z',
    submitted_at: '2026-10-02T16:05:00Z', submitted_by: 'u-crew', review_notes: null, resolved_detail: null, resolved_meds: null,
    lot_id: null, pasture_id: null, field_action_id: null, tag_number: '102',
    raw: { tagNumber: '102', lotNumber: '2627-A', location: 'Home Place - North', treatmentType: 'Pull - BRD',
           medication1: 'Draxxin', dosage1: '5', dateTime: '2026-10-02T11:00:00', recordedBy: 'Cody' } }
];
window.__db.pb_daily_reports = [{ report_date: '2026-10-02', gmail_message_id: 'm1', staged_at: '2026-10-03T09:10:00Z', status: 'pending' }];
window.__db.ranch_settings = [{ pb_email_post_from: '2026-09-01' }];
window.__pbReport = { report_date: '2026-10-02', status: 'pending', problems: [], notes: [], drop_fed_lb: 1000, ingredient_fed_lb: 1000, loads: 3,
  by_pen: [{ pen: 'PEN 4', pasture: 'Home Place / North', target_lb: 1000, fed_lb: 1000 }],
  by_item: [{ pb_name: 'HAY', item: 'Hay', target_lb: 1000, fed_lb: 1000 }],
  charges: { lots: [{ lot: '2627-A', lb: 1000, items: [{ item: 'Hay', lb: 1000 }] }], prefeed: [], cost_centers: [], total_lb: 1000, basis: 'preview' } };
window.__db.med_stock_locations = [{ id: 'loc-ranch', name: 'Ranch', kind: 'ranch', is_active: true, usage_from: '2026-10-01', sort_order: 1 },
                                   { id: 'loc-truck', name: 'Truck', kind: 'pool', is_active: true, sort_order: 2 }];
window.__db.medications[0].bottle_size = 100; window.__db.medications[0].bottle_size_unit = 'mL';
window.__db.med_invoice_intake = [{ id: 'int-1', vendor: 'Bar J', invoice_number: '6700', invoice_date: '2026-10-02', invoice_total: 237.69,
  item_count: 1, lines: [{ name: 'DRAXXIN 100ML', qty: 1, line_total: 237.69, bottle_size: 100 }], problems: [], status: 'pending',
  staged_at: '2026-10-03T04:00:00Z', reviewed_at: null, review_notes: null, med_purchases: [] }];
window.__db.med_name_aliases = [{ vendor: 'Bar J', alias: 'DRAXXIN 100ML', medication_id: 'med-1', bottle_size: 100 }];
window.__rpcAnswers = { current_user_role: 'office', pb_report_list: () => [window.__pbReport], prefeed_waiting: [] };
// ---- Feed pen, feed, med inventory ----
window.__db.lots.push({ id: 'pen-1', lot_number: 'FEEDPEN-27', arrival_date: '2026-07-01', fiscal_year: 2027, is_test: false, is_feed_pen: true, closed_at: null });
window.__db.lot_status.push({ lot_id: 'pen-1', id: 'pen-1', lot_number: 'FEEDPEN-27', head_current: 3, head_in: 3, dead: 0, sold: 0, arrival_date: '2026-07-01', fiscal_year: 2027, is_test: false, is_feed_pen: true, closed_at: null });
window.__db.lot_pasture_assignments.push({ id: 'asg-pen', lot_id: 'pen-1', pasture_id: 'pas-2', head_count: 3, moved_in: '2026-09-15', moved_out: null,
  pastures: { name: 'South', ranches: { name: 'Home Place', is_active: true } }, lots: { lot_number: 'FEEDPEN-27', closed_at: null } });
window.__db.feed_items = [{ id: 'it-hay', name: 'Hay', item_type: 'commodity', purchase_unit: 'ton', lb_per_unit: 2000, is_active: true, default_location_id: 'bay-1' }];
window.__db.feed_storage_locations = [{ id: 'bay-1', name: 'Bay 1', kind: 'bay', is_active: true, is_bulk: true }];
window.__db.vendors = [{ id: 'v-1', name: 'Feed Co', is_active: true }];
window.__db.feed_on_hand = [{ item_id: 'it-hay', location_id: 'bay-1', on_hand_lb: 20000, item_name: 'Hay', location_name: 'Bay 1' }];
window.__db.med_crew_members = [{ id: 'crew-1', name: 'Cody', is_active: true }];
window.__db.med_on_hand = [{ medication_id: 'med-1', medication_name: 'Draxxin', generic_category: 'tulathromycin', location_id: 'loc-ranch', units: 500, bottle_size: 100 }];
window.__db.feed_pen_cost_by_source = [{ pen_lot_id: 'pen-1', source_lot_id: 'lot-1', source_lot_number: '2627-A', lot_number: '2627-A', head_on_hand: 3, head_in: 3 }];
window.__db.feed_pen_summary = [{ pen_lot_id: 'pen-1', head_on_hand: 3, fiscal_year: 2027 }];
window.__db.feed_pen_removals = [];
window.__db.shipments = [{ id: 'shp-1', sale_date: '2026-10-01', buyer: 'Buyer A', destination: 'Feedyard', head_count: 10, pay_weight_lb: 8000, net_amount: 19980, gross_amount: 19980 }];
window.__db.sales = [{ id: 's-1', lot_id: 'lot-1', sale_date: '2026-10-01', shipment_id: 'shp-1', head_count: 10, lots: { lot_number: '2627-A' },
  sale_sources: [{ pasture_id: 'pas-1', head_count: 10, pay_weight_lb: 8000, net_amount: 19980, pastures: { name: 'North', ranches: { name: 'Home Place' } } }] }];
window.__db.shipment_loads = [{ shipment_id: 'shp-1', load_date: '2026-10-01' }];
window.__rpcAnswers.feed_book_as_of = [{ item_id: 'it-hay', item_name: 'Hay', book_qty_lb: 20000, current_qty_lb: 20000 }];
