// Approvals > Meds end-to-end against an IN-MEMORY stand-in for Supabase:
// the real index.html in headless Chromium, every from()/rpc() answered here
// from fixtures shaped like stage_med_invoice()'s output for Bar J #6654.
// Never points at Supabase, so "Post" here writes nothing real.
//   NODE_PATH=$(npm root -g) node scripts/med-intake-harness/run.js [shots-dir]
// Set FLATPICKR_JS to a local copy of flatpickr 4.6.13's dist/flatpickr.min.js
// (npm pack flatpickr@4.6.13) to run the date checks against the real
// calendar widget; without it flatpickr is stubbed and those checks are skipped.
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');
const FLATPICKR = process.env.FLATPICKR_JS ? fs.readFileSync(process.env.FLATPICKR_JS, 'utf8') : null;
const SHOTS = process.argv[2] || '/tmp';
const OWNER = 'ff89f282-7c9d-40e5-abe7-e4899dce7122';

const LOC = [
  { id: 'loc-ranch', name: 'Ranch', kind: 'ranch', is_test: false, is_active: true },
  { id: 'loc-truck', name: "Jake's truck", kind: 'truck', is_test: false, is_active: true }
];
const MEDS = [
  { id: 'med-macro', name: 'Macrosyn(Draxxin)', generic_category: 'Antibiotic', bottle_size: 500, bottle_size_unit: 'mL', is_active: true },
  { id: 'med-exc', name: 'Excede', generic_category: 'Antibiotic', bottle_size: 100, bottle_size_unit: 'mL', is_active: true },
  { id: 'med-vitk', name: 'Vitamin K', generic_category: 'Vitamin', bottle_size: 100, bottle_size_unit: 'mL', is_active: true }
];
const INTAKE = {
  id: 'intake-6654', vendor: 'Bar J Vet Supply', invoice_number: '6654', invoice_date: '2026-10-02',
  invoice_total: 237.69, item_count: 2, problems: [], status: 'pending', staged_at: '2026-10-02T16:10:00Z',
  reviewed_at: null, review_notes: null,
  lines: [
    { qty: 1, name: 'Macrosyn 250 ml - Prestige', unit: 'mL', line_total: 211.88, unit_price: 211.88, bottle_size: 250 },
    { qty: 1, name: 'Vitamin K1 Injection 100ml VetOne', unit: 'mL', line_total: 25.81, unit_price: 25.81, bottle_size: 100 }
  ]
};

function makeState() {
  return { meds: MEDS.map(m => ({ ...m })), purchases: [], lines: [], aliases: [], rpcs: [], inserts: [] };
}
function from(st, q) {
  const f = {}; q.filters.forEach(x => { f[x[0] + ':' + x[1]] = x[2]; });
  const one = rows => q.single ? { data: rows[0] || null, error: null } : { data: rows, error: null };
  switch (q.table) {
    case 'user_profiles': return { data: { id: OWNER, role: 'owner', full_name: 'Test Owner', email: 't@x', is_active: true }, error: null };
    case 'med_stock_locations': return { data: LOC, error: null };
    case 'medications':
      if (q.op === 'insert') {
        const row = { id: 'med-new-' + (st.meds.length + 1), ...q.payload };
        st.meds.push(row); st.inserts.push({ table: 'medications', row });
        return one([row]);
      }
      return { data: st.meds.filter(m => m.is_active !== false), error: null };
    case 'med_invoice_intake': {
      const posted = st.purchases.filter(p => p.intake_id === INTAKE.id).map(p => ({ id: p.id, purchase_date: p.purchase_date, location_id: p.location_id }));
      return { data: [{ ...INTAKE, med_purchases: posted }], error: null };
    }
    case 'med_name_aliases': return { data: st.aliases, error: null };
    case 'med_purchases':
      if (q.op === 'insert') {
        if (q.payload.intake_id && st.purchases.some(p => p.intake_id === q.payload.intake_id))
          return { data: null, error: { code: '23505', message: 'duplicate key value violates unique constraint "med_purchases_intake_uniq"' } };
        const row = { id: 'pur-' + (st.purchases.length + 1), ...q.payload };
        st.purchases.push(row); st.inserts.push({ table: 'med_purchases', row });
        return one([row]);
      }
      return { data: [], error: null };
    case 'med_purchase_lines':
      if (q.op === 'insert') { st.lines.push(...q.payload); st.inserts.push({ table: 'med_purchase_lines', rows: q.payload }); }
      return { data: [], error: null };
    case 'pending_field_entries': case 'pb_daily_reports':
      return { data: [], count: 0, error: null };
    default: return { data: q.single ? null : [], count: 0, error: null };
  }
}
function rpc(st, fn, args) {
  st.rpcs.push({ fn, args });
  if (fn === 'current_user_role') return { data: 'owner', error: null };
  if (fn === 'med_alias_learn') { st.aliases.push({ vendor: args.p_vendor, alias: args.p_alias, medication_id: args.p_medication_id, bottle_size: args.p_bottle_size }); return { data: null, error: null }; }
  if (fn === 'settle_med_uncovered') return { data: { units_covered: 0 }, error: null };
  if (fn === 'ranch_today') return { data: '2026-10-02', error: null };
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
  ok(norm(await p.innerText('#apprMedsCount')) === '1', 'Meds badge shows 1 waiting');
  await p.click('[data-appr-pane=meds]'); await settle(p);
  const pane = norm(await p.innerText('#apprMedsPane'));
  ok(pane.includes('Invoice #6654') && pane.includes('$237.69'), '#6654 card shows in Approvals > Meds with $237.69');
  ok(pane.includes('Macrosyn 250 ml - Prestige') && pane.includes('Vitamin K1 Injection 100ml VetOne'), 'card lists both invoice lines');
  await p.screenshot({ path: SHOTS + '/med-intake-1-queue.png', fullPage: false });

  await p.click('[data-mi-review="intake-6654"]'); await settle(p);
  ok(!(await p.isHidden('#invMedPurchaseEntryView')), 'Review & post opens the existing purchase screen');
  ok(norm(await p.innerText('#invPurchaseEntryTitle')).includes('#6654'), 'title names the invoice');
  ok(await p.inputValue('#invPurLocation') === '', 'Received to starts blank');
  ok(norm(await p.innerText('#invPurLocation option:first-child')) === '— choose where it went —', 'blank option says choose');
  if (FLATPICKR) {
    const shown = await p.evaluate(() => { const f = document.getElementById('invPurDate'); return f._flatpickr && f._flatpickr.altInput ? f._flatpickr.altInput.value : null; });
    ok(shown === '10/02/2026', 'visible invoice date shows 10/02/2026 with the real calendar widget: ' + shown);
  } else console.log('SKIP visible-date check (FLATPICKR_JS not set)');
  const groups = await p.$$eval('#invPurLines select[data-field=medication_id]', s => s.map(x =>
    [...x.querySelectorAll('optgroup[label=Likely] option')].map(o => o.textContent)));
  ok(groups[0][0] === 'Macrosyn(Draxxin)' && groups[1][0] === 'Vitamin K', 'Likely list puts the right product first: ' + JSON.stringify(groups));
  ok(await p.inputValue('#invPurDate') === '2026-10-02' && await p.inputValue('#invPurInvoiceNo') === '6654'
     && await p.inputValue('#invPurVendor') === 'Bar J Vet Supply' && await p.inputValue('#invPurTotal') === '237.69', 'header filled from intake');
  const tie = norm(await p.innerText('#invPurTie'));
  ok(tie.includes('$237.69') && tie.includes('ties'), 'tie-out shows $237.69 and ties: ' + tie);
  const sels = await p.$$eval('#invPurLines select[data-field=medication_id]', s => s.map(x => x.value));
  ok(sels.length === 2 && sels.every(v => v === ''), 'Macrosyn and Vitamin K1 both need a pick (no exact name match)');
  const sizes = await p.$$eval('#invPurLines input[data-field=bottle_size]', s => s.map(x => x.value));
  ok(sizes[0] === '250' && sizes[1] === '100', 'bottle sizes 250 / 100 read off the invoice, not the 500 mL catalog: ' + sizes);
  ok((await p.$$('[data-inv-newmed]')).length === 2, 'each unmatched line has a New medication button');
  await p.screenshot({ path: SHOTS + '/med-intake-2-review.png', fullPage: true });

  // Post refuses with no location (lines also unmatched; location is checked first).
  const before = st.inserts.length;
  await p.click('#invPurSaveBtn'); await settle(p);
  ok(norm(await p.innerText('#invPurAlert')).includes('Choose where it was received to'), 'Post refuses with no location');
  ok(st.inserts.length === before, 'nothing written on refused post');

  // New medication pre-filled from the Vitamin K1 line.
  const vk = (await p.$$('[data-inv-newmed]'))[1];
  // (Vitamin K is in the catalog and offered under Likely; New medication is
  // still there for a product the catalog does not have.)
  await vk.click(); await settle(p);
  ok(norm(await p.innerText('#medModalTitle')) === 'New medication', 'med modal says New medication');
  ok(await p.inputValue('#medName') === 'Vitamin K1 Injection 100ml VetOne', 'name pre-filled');
  ok(await p.inputValue('#medBottleSize') === '100' && await p.inputValue('#medBottleSizeUnit') === 'mL'
     && await p.inputValue('#medBottleCost') === '25.81', 'bottle size, unit, cost pre-filled');
  await p.screenshot({ path: SHOTS + '/med-intake-3-newmed.png' });
  await p.click('#medCancelBtn'); await settle(p);
  ok(norm(await p.innerText('#medModalTitle')) === 'New medication' && st.inserts.length === before, 'Cancel saves nothing');

  // Cancel leaves the invoice unposted and returns to Meds.
  await p.click('#invPurCancelBtn'); await settle(p);
  ok(!(await p.isHidden('#apprMedsPane')) && norm(await p.innerText('#apprMedsCount')) === '1', 'Cancel returns to Approvals > Meds, still 1 waiting');
  ok(st.purchases.length === 0, 'no purchase written');

  // Plain New purchase still defaults to Ranch (not intake mode).
  await p.evaluate(() => openInvPurchaseEntry()); await settle(p);
  ok(await p.inputValue('#invPurLocation') === 'loc-ranch' && norm(await p.innerText('#invPurchaseEntryTitle')) === 'New purchase', 'plain New purchase unchanged: defaults to Ranch');

  // ---- Full post, against the FAKE only (not #6654 in the real books). ----
  await p.click('#navApprovals'); await settle(p);
  await p.click('[data-mi-review="intake-6654"]'); await settle(p);
  await p.selectOption('#invPurLines select[data-field=medication_id] >> nth=0', 'med-macro'); await settle(p);
  ok(await p.inputValue('#invPurLines input[data-field=bottle_size] >> nth=0') === '250', 'picking Macrosyn(Draxxin) keeps the invoice 250 mL');
  await p.click('[data-inv-newmed]'); await settle(p);
  await p.fill('#medCategory', 'Vitamin'); await p.fill('#medWithdrawal', '0');
  await p.click('#medSaveBtn'); await settle(p);
  const sels2 = await p.$$eval('#invPurLines select[data-field=medication_id]', s => s.map(x => x.value));
  ok(sels2[0] === 'med-macro' && /^med-new-/.test(sels2[1]), 'new med saved and landed on the Vitamin K1 line');
  await p.selectOption('#invPurLocation', 'loc-ranch');
  await p.click('#invPurSaveBtn'); await p.waitForTimeout(1200);
  const pur = st.purchases[0];
  ok(pur && pur.intake_id === 'intake-6654' && pur.location_id === 'loc-ranch', 'post stamps intake_id and location');
  ok(st.lines.length === 2 && st.lines[0].bottle_size === 250 && Math.abs(st.lines[0].unit_cost - 211.88 / 250) < 1e-6, 'lines posted at 250 mL, landed cost per mL');
  const learned = st.rpcs.filter(r => r.fn === 'med_alias_learn').map(r => r.args);
  ok(learned.length === 2 && learned[0].p_vendor === 'Bar J Vet Supply' && learned[0].p_alias === 'Macrosyn 250 ml - Prestige'
     && learned[0].p_medication_id === 'med-macro' && learned[0].p_bottle_size === 250, 'both hand picks remembered as aliases');
  ok(!(await p.isHidden('#apprMedsPane')) && norm(await p.innerText('#apprMedsCount')) === '0', 'back on Approvals > Meds, badge 0');
  ok(norm(await p.textContent('#apprMedsPane')).includes('Posted to Ranch'), 'invoice shows under recently posted');

  // A second post of the same invoice is refused by the unique index.
  await p.evaluate(() => { medIntakeList.forEach(r => r.med_purchases = []); openMedIntakeReview('intake-6654'); }); await settle(p);
  const sels3 = await p.$$eval('#invPurLines select[data-field=medication_id]', s => s.map(x => x.value));
  ok(sels3[0] === 'med-macro' && /^med-new-/.test(sels3[1]), 'next time both lines match from the remembered aliases');
  await p.selectOption('#invPurLocation', 'loc-ranch');
  await p.click('#invPurSaveBtn'); await settle(p);
  const dup = norm(await p.innerText('#invPurAlert'));
  ok(dup.includes('already posted'), 'double post surfaces the unique-index error plainly: ' + dup);
  ok(st.purchases.length === 1, 'still one purchase');

  ok(errs.length === 0, 'no page errors' + (errs.length ? ': ' + errs.join(' | ') : ''));
  await b.close();
  console.log(fails ? `${fails} FAILED` : 'ALL PASS');
  process.exit(fails ? 1 : 0);
})();
