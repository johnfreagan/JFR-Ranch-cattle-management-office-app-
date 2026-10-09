// Approvals > Load outs end-to-end against an IN-MEMORY stand-in for Supabase:
// the real index.html in headless Chromium, every from()/rpc() answered here.
// Never points at Supabase, so Save here writes nothing real.
//   NODE_PATH=$(npm root -g) node scripts/load-out-ticket-harness/run.js [shots-dir]
// Fixture: the Bar T Bar ticket of 2026-10-08 (order #32, 18 hd, tags 157-174,
// weight out 6,390 lb) staged on a TEST lot, plus a second ticket that is
// already entered on the books (the duplicate case).
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');
const FLATPICKR = process.env.FLATPICKR_JS ? fs.readFileSync(process.env.FLATPICKR_JS, 'utf8') : null;
const SHOTS = process.argv[2] || '/tmp';
const OWNER = 'ff89f282-7c9d-40e5-abe7-e4899dce7122';
const LOT = { id: 'lot-t32', lot_number: 'TEST-32', closed_at: null, fiscal_year: 2027, is_test: true, source: 'Jake Taylor', is_feed_pen: false };
// 1x1 JPEG
const PHOTO = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=';
const TICKET = {
  id: 'pfe-lo-1', entry_type: 'load_out', client_id: 'ticket:32:2026-10-08:157-174', status: 'pending',
  raw: { source: 'ticket_photo', seller: 'Bar T Bar Cattle Co', orderNo: '32', orderMapping: 'history', lotNumber: 'TEST-32',
         date: '2026-10-08', headCount: 18, tagStart: 157, tagEnd: 174, missingTags: [], hauledBy: 'Tyler', weightOutLb: 6390 },
  lot_id: LOT.id, head_count: 18, event_datetime: '2026-10-08T17:00:00Z', submitted_at: '2026-10-09T15:00:00Z',
  review_notes: null, resolved_detail: { ticket_photo: PHOTO }
};
const DUP = {
  id: 'pfe-lo-2', entry_type: 'load_out', client_id: 'ticket:32:2026-10-07:103-156', status: 'pending',
  raw: { source: 'ticket_photo', seller: 'Bar T Bar Cattle Co', orderNo: '32', orderMapping: 'history', lotNumber: 'TEST-32',
         date: '2026-10-07', headCount: 54, tagStart: 103, tagEnd: 156, missingTags: [] },
  lot_id: LOT.id, head_count: 54, event_datetime: '2026-10-07T17:00:00Z', submitted_at: '2026-10-09T15:00:00Z',
  review_notes: null, resolved_detail: { ticket_photo: PHOTO }
};
const RECEIPTS = [{ id: 'rc-old', lot_id: LOT.id, receipt_date: '2026-10-07', head_count: 54, tag_start: 103, tag_end: 156 }];

function makeState() {
  return { pfe: [JSON.parse(JSON.stringify(TICKET)), JSON.parse(JSON.stringify(DUP))], rpcs: [], updates: [], inserts: [], pfeQueries: [] };
}
function matches(row, filters) {
  return filters.every(([op, col, val]) => {
    if (op === 'eq') return row[col] === val;
    if (op === 'neq') return row[col] !== val;
    if (op === 'in') return val.includes(row[col]);
    if (op === 'is') return row[col] == val;
    if (op === 'gte') return row[col] >= val;
    if (op === 'lte') return row[col] <= val;
    return true;
  });
}
function from(st, q) {
  const one = rows => q.single ? { data: rows[0] || null, error: null } : { data: rows, error: null };
  switch (q.table) {
    case 'user_profiles': return { data: { id: OWNER, role: 'owner', full_name: 'Test Owner', email: 't@x', is_active: true }, error: null };
    case 'lots': return one([LOT].filter(r => matches(r, q.filters.filter(f => f[1] === 'id'))));
    case 'lot_status': return one([{ lot_id: LOT.id, lot_number: LOT.lot_number, head_in: 0, head_current: 0, dead: 0, sold: 0 }]);
    case 'pasture_status': return { data: [{ pasture_id: 'p-1', id: 'p-1', ranch_name: 'Home', pasture_name: 'Trap', is_active: true }], error: null };
    case 'delivery_receipts': return { data: RECEIPTS.filter(r => matches(r, q.filters)), error: null };
    case 'tag_registry': return { data: [], error: null };
    case 'delivery_receipt_attachments':
      if (q.op === 'insert') st.inserts.push({ table: q.table, row: q.payload });
      return { data: [], error: null };
    case 'pending_field_entries': {
      st.pfeQueries.push({ op: q.op, filters: q.filters, head: q.head });
      if (q.op === 'update') {
        const hit = st.pfe.filter(r => matches(r, q.filters));
        hit.forEach(r => Object.assign(r, q.payload));
        st.updates.push({ filters: q.filters, payload: q.payload });
        return { data: hit.map(r => ({ id: r.id })), error: null };
      }
      const rows = st.pfe.filter(r => matches(r, q.filters));
      return { data: rows, count: rows.length, error: null };
    }
    default: return { data: q.single ? null : [], count: 0, error: null };
  }
}
function rpc(st, fn, args) {
  st.rpcs.push({ fn, args });
  if (fn === 'current_user_role') return { data: 'owner', error: null };
  if (fn === 'record_load_out') return { data: { receipt_id: 'rc-new' }, error: null };
  return { data: null, error: null };
}

const FAKE = `(function(){
  function builder(table){
    const q = { table, filters: [], head: false, single: false, op: 'select', payload: null };
    const run = () => window.__from(q);
    const p = new Proxy(function(){}, {
      get(t, k){
        if (k === 'then') return (ok, bad) => run().then(ok, bad);
        if (k === 'single' || k === 'maybeSingle') return () => { q.single = true; return p; };
        if (['insert','update','upsert','delete'].includes(k)) return (v) => { q.op = k; q.payload = v === undefined ? null : JSON.parse(JSON.stringify(v)); return p; };
        if (k === 'select') return (cols, o) => { if (o && o.head) q.head = true; return p; };
        return (...a) => { q.filters.push([k, ...a]); return p; };
      }
    });
    return p;
  }
  const client = {
    from: builder,
    rpc: async (fn, args) => window.__rpc(fn, args || {}),
    auth: {
      getSession: async () => ({ data: { session: { user: { id: window.__uid, email: 't@x' } } } }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
      signOut: async () => ({}), getUser: async () => ({ data: { user: { id: window.__uid } } })
    },
    get storage(){ return { from: () => ({ upload: async()=>({}), remove: async()=>({}), update: async()=>({}), createSignedUrl: async()=>({data:null}) }) }; },
    channel: () => ({ on(){ return this; }, subscribe(){ return this; } }), removeChannel(){}
  };
  window.supabase = { createClient: () => client };
})();`;

async function open(b, st) {
  const p = await b.newPage({ viewport: { width: 1100, height: 1400 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  p.on('dialog', d => d.dismiss());
  await p.addInitScript(uid => { window.__uid = uid; }, OWNER);
  await p.exposeFunction('__rpc', (fn, args) => rpc(st, fn, args));
  await p.exposeFunction('__from', q => from(st, q));
  await p.route('https://cdn.jsdelivr.net/**', r => {
    const u = r.request().url();
    if (u.includes('supabase-js')) return r.fulfill({ contentType: 'text/javascript', body: FAKE });
    if (u.endsWith('.css')) return r.fulfill({ contentType: 'text/css', body: '' });
    if (FLATPICKR && u.includes('flatpickr')) return r.fulfill({ contentType: 'text/javascript', body: FLATPICKR });
    return r.fulfill({ contentType: 'text/javascript', body: 'window.flatpickr=window.flatpickr||function(){return{setDate(){},clear(){},destroy(){}}};window.Chart=window.Chart||function(){return{destroy(){},update(){}}};' });
  });
  await p.route(/^https:\/\/(?!cdn\.jsdelivr).*/, r => r.fulfill({ body: '' }));
  await p.goto('file://' + path.resolve(__dirname, '../../index.html'));
  await p.waitForTimeout(1500);
  return { p, errs };
}

const norm = s => (s || '').replace(/\s+/g, ' ').trim();
let fails = 0;
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) fails++; };
const settle = p => p.waitForTimeout(600);

(async () => {
  const b = await chromium.launch();
  const st = makeState();
  const { p, errs } = await open(b, st);

  await p.click('#navApprovals'); await settle(p);
  ok(norm(await p.innerText('#apprLoadCount')) === '2', 'Load outs badge shows 2 waiting');
  ok(await p.isHidden('#apprFieldCount'), 'Field entries badge does not count load-out tickets');
  const listQ = st.pfeQueries.find(x => x.op === 'select' && !x.head && x.filters.some(f => f[0] === 'neq' && f[1] === 'entry_type' && f[2] === 'load_out'));
  ok(!!listQ, 'Field entries list query excludes load_out');
  await p.click('[data-appr-pane=loadouts]'); await settle(p);
  const pane = norm(await p.innerText('#apprLoadPane'));
  ok(pane.includes('Lot TEST-32') && pane.includes('18 head') && pane.includes('157–174'), 'ticket card shows lot, head, tags');
  ok(pane.includes('Hauled by Tyler') && pane.includes('Weight out 6,390 lb'), 'card shows hauler and weight out');
  ok(await p.$('[data-lo-photo="pfe-lo-1"] img') !== null, 'card shows the photo');
  ok(pane.includes('already entered'), 'duplicate ticket says already entered');
  ok(await p.isDisabled('[data-lo-open="pfe-lo-2"]'), 'duplicate ticket cannot be opened');
  ok(!(await p.isDisabled('[data-lo-open="pfe-lo-1"]')), 'good ticket can be opened');
  await p.screenshot({ path: SHOTS + '/load-out-1-queue.png', fullPage: true });

  // Open, then Cancel: back to the queue, nothing written.
  await p.click('[data-lo-open="pfe-lo-1"]'); await p.waitForTimeout(1200);
  ok(await p.evaluate(() => document.getElementById('receiptModal').classList.contains('show')), 'Open load out shows the load-out form');
  ok(norm(await p.innerText('#receiptModalTitle')) === 'New load out from ticket', 'title says from ticket');
  ok(await p.inputValue('#receiptDate') === '2026-10-08' && await p.inputValue('#receiptHead') === '18'
     && await p.inputValue('#receiptTagStart') === '157' && await p.inputValue('#receiptTagEnd') === '174', 'date, head, tags filled');
  const notes = await p.inputValue('#receiptNotes');
  ok(notes === 'Ticket: Bar T Bar Cattle Co · order #32 · hauled by Tyler · weight out 6,390 lb', 'notes carry seller, order, hauler, weight: ' + notes);
  ok(!(await p.isHidden('#receiptTicketBox')), 'ticket photo shown above the form');
  await p.screenshot({ path: SHOTS + '/load-out-2-form.png', fullPage: false });
  await p.click('#receiptCancelBtn'); await settle(p);
  ok(!(await p.isHidden('#apprLoadPane')), 'Cancel returns to Approvals > Load outs');
  ok(!st.rpcs.some(r => r.fn === 'record_load_out') && st.updates.length === 0, 'Cancel writes nothing');

  // A plain New load out afterwards carries no ticket.
  await p.evaluate(async () => { currentLot = currentLot || { id: 'lot-t32', lot_number: 'TEST-32', fiscal_year: 2027 }; await openReceiptModal(null); });
  await settle(p);
  ok(await p.isHidden('#receiptTicketBox') && norm(await p.innerText('#receiptModalTitle')) === 'New load out', 'plain New load out shows no ticket');
  await p.evaluate(() => hideModal('receiptModal'));

  // Open again and save.
  await p.click('#navApprovals'); await settle(p);
  await p.click('[data-appr-pane=loadouts]'); await settle(p);
  await p.click('[data-lo-open="pfe-lo-1"]'); await p.waitForTimeout(1200);
  await p.evaluate(() => { receiptDestinations[0].pasture_id = 'p-1'; });
  await p.click('#receiptSaveBtn'); await p.waitForTimeout(1500);
  const rec = st.rpcs.find(r => r.fn === 'record_load_out');
  ok(rec && rec.args.p_lot_id === 'lot-t32' && rec.args.p_receipt_date === '2026-10-08' && rec.args.p_head_count === 18
     && rec.args.p_tag_start === 157 && rec.args.p_tag_end === 174 && rec.args.p_register_tags.length === 18
     && rec.args.p_destinations[0].pasture_id === 'p-1' && rec.args.p_destinations[0].head_count === 18, 'record_load_out called with the ticket values');
  const att = st.inserts.find(x => x.table === 'delivery_receipt_attachments');
  ok(att && att.row.receipt_id === 'rc-new' && /load-out-ticket\.jpg$/.test(att.row.file_name), 'photo attached to the new load out');
  const t1 = st.pfe.find(r => r.id === 'pfe-lo-1');
  ok(t1.status === 'approved' && t1.approved_ref && t1.approved_ref.id === 'rc-new' && t1.approved_ref.table === 'delivery_receipts', 'ticket approved with approved_ref to the receipt');
  ok(!t1.resolved_detail.ticket_photo, 'photo cleared off the staged row once attached');
  ok(norm(await p.innerText('#apprLoadCount')) === '1', 'badge drops to 1');

  // Reject the duplicate.
  await p.evaluate(() => { window.prompt = () => 'already entered by hand'; });
  await p.click('#navApprovals'); await settle(p);
  await p.click('[data-appr-pane=loadouts]'); await settle(p);
  await p.click('[data-lo-reject="pfe-lo-2"]'); await p.waitForTimeout(1000);
  const t2 = st.pfe.find(r => r.id === 'pfe-lo-2');
  ok(t2.status === 'rejected' && t2.review_notes === 'already entered by hand', 'duplicate rejected with reason');
  const pane2 = norm(await p.innerText('#apprLoadPane'));
  ok(pane2.includes('No load-out tickets waiting') && pane2.includes('Recently saved or rejected'), 'queue empty, outcome listed');
  await p.screenshot({ path: SHOTS + '/load-out-3-done.png', fullPage: true });

  ok(errs.length === 0, 'no page errors' + (errs.length ? ': ' + errs.join(' | ') : ''));
  await b.close();
  console.log(fails ? `${fails} FAILED` : 'ALL PASS');
  process.exit(fails ? 1 : 0);
})();
