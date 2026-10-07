// Inventory > Meds > Charge out, and the Medication Application report, end
// to end on a SCRATCH database: the real index.html in headless Chromium,
// every rpc() and read run through psql against a local PostgreSQL 16 built
// from docs/sql/tests (the med fixture, the med migration, the direct-charge
// fixture and docs/sql/2026-10-07_med_direct_charge.sql). Never points at
// Supabase. Each statement runs as a real non-superuser role (office_user,
// crew_user) with test.role set, so RLS applies as it does live.
//
// Build the template once (see docs/sql/tests/README.md for the cluster):
//   sh scripts/med-charge-harness/build-base.sh
// Run:
//   NODE_PATH=$(npm root -g) node scripts/med-charge-harness/run-local.js [shots-dir]
const { chromium } = require('playwright');
const { spawnSync } = require('child_process');
const fs = require('fs'), path = require('path');
const SHOTS = process.argv[2] || '/tmp';
const DB = 'medcharge_ui', BASE = 'medcharge_base', TODAY = '2026-10-07';
const U = { owner: '00000000-0000-0000-0000-0000000000a1', office: '00000000-0000-0000-0000-0000000000b1',
            crew: '00000000-0000-0000-0000-0000000000c1' };
const PGROLE = { owner: 'office_user', office: 'office_user', crew: 'crew_user' };

function psql(input, db) {
  return spawnSync('su', ['postgres', '-c', `psql -d ${db || DB} -X -q -At -v ON_ERROR_STOP=1`], { encoding: 'utf8', input });
}
function sql(q, role) {
  const r = psql(`begin;\n${role ? `set local role ${PGROLE[role]};\nset local test.role = '${role}';\nset local test.uid = '${U[role]}';\n` : ''}` +
                 `set local test.today = '${TODAY}';\n${q};\ncommit;\n`);
  if (r.status) {
    const m = /ERROR:\s+([\s\S]*?)(?:\n(?:CONTEXT|DETAIL|HINT|LINE|psql:)|\s*$)/.exec(r.stderr);
    throw new Error(m ? m[1].trim() : r.stderr);
  }
  return r.stdout.trim();
}
const lit = v => v == null ? 'NULL' : "'" + String(v).replace(/'/g, "''") + "'";
const J = (q, role) => { const o = sql(q, role); return o === '' ? null : JSON.parse(o); };

function rpc(role, fn, args) {
  if (!/^[a-z_]+$/.test(fn)) return { data: null, error: { message: 'bad fn' } };
  const a = Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}`).join(', ');
  try { return { data: J(`select to_jsonb(public.${fn}(${a}))`, role), error: null }; }
  catch (e) { return { data: null, error: { message: e.message } }; }
}
// Plain reads: eq / gte / lte / is-null / in, order and limit, select *.
const GENERIC = ['med_stock_locations', 'medications', 'lots', 'cost_centers', 'med_usage_by_lot',
                 'med_on_hand', 'med_crew_members'];
function where(q) {
  const w = [], order = []; let lim = '';
  for (const [op, a, b] of q.filters) {
    const col = /^[a-z_]+$/.test(String(a)) ? a : null;
    if (op === 'eq' && col) w.push(`${col} = ${lit(b)}`);
    else if (op === 'gte' && col) w.push(`${col} >= ${lit(b)}`);
    else if (op === 'lte' && col) w.push(`${col} <= ${lit(b)}`);
    else if (op === 'is' && col && b === null) w.push(`${col} is null`);
    else if (op === 'in' && col) w.push(`${col} in (${b.map(lit).join(',')})`);
    else if (op === 'order' && col) order.push(col + (b && b.ascending === false ? ' desc' : '') + (b && b.nullsFirst === false ? ' nulls last' : ''));
    else if (op === 'limit') lim = ` limit ${Number(a)}`;
  }
  return { w: w.length ? ' where ' + w.join(' and ') : '', o: order.length ? ' order by ' + order.join(', ') : '', lim };
}
function from(role, q) {
  try {
    if (q.op !== 'select') return { data: null, error: { message: 'harness: writes go through rpc only' } };
    if (q.table === 'user_profiles') {
      return { data: { id: U[role], role, is_active: true, full_name: role + ' tester', email: role + '@x' }, error: null };
    }
    if (q.table === 'med_charges') {
      // The Recent charges list: the same embeds PostgREST would return.
      const { w, o, lim } = where(q);
      return { data: J(`select coalesce(jsonb_agg(x), '[]') from (select jsonb_build_object(
          'id', c.id, 'charge_date', c.charge_date, 'qty_units', c.qty_units, 'destination', c.destination,
          'category', c.category, 'notes', c.notes, 'lot_id', c.lot_id,
          'medications', (select jsonb_build_object('name', m.name, 'bottle_size_unit', m.bottle_size_unit) from medications m where m.id = c.medication_id),
          'lots', (select jsonb_build_object('lot_number', l.lot_number) from lots l where l.id = c.lot_id),
          'cost_centers', (select jsonb_build_object('name', k.name) from cost_centers k where k.id = c.cost_center_id),
          'med_stock_locations', (select jsonb_build_object('name', s.name) from med_stock_locations s where s.id = c.location_id),
          'med_txns', (select jsonb_build_object('txn_date', t.txn_date, 'total_cost', t.total_cost,
                         'shortfall_units', t.shortfall_units, 'cost_provisional', t.cost_provisional) from med_txns t where t.id = c.txn_id)
        ) x from (select * from med_charges c ${w.replace(/\b(charge_date|lot_id)\b/g, 'c.$1')}${o}${lim}) c) y`, role), error: null };
    }
    if (GENERIC.includes(q.table)) {
      const { w, o, lim } = where(q);
      const d = J(`select coalesce(jsonb_agg(to_jsonb(t)), '[]') from (select * from ${q.table}${w}${o}${lim}) t`, role);
      return { data: q.single ? (d[0] || null) : d, error: null };
    }
    return { data: q.single ? null : [], error: null, count: 0 };
  } catch (e) { return { data: null, error: { message: e.message } }; }
}

const fake = fs.readFileSync(path.resolve(__dirname, '../pb-feed-harness/fake-local.js'), 'utf8');
async function open(b, role) {
  const p = await b.newPage({ viewport: { width: 1200, height: 1400 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  p.on('dialog', d => d.accept());
  await p.addInitScript(uid => { window.__uid = uid; }, U[role]);
  await p.exposeFunction('__rpc', (fn, args) => rpc(role, fn, args));
  await p.exposeFunction('__from', q => from(role, q));
  await p.route('https://cdn.jsdelivr.net/**', r => {
    const u = r.request().url();
    if (u.includes('supabase-js')) return r.fulfill({ contentType: 'text/javascript', body: fake });
    if (u.endsWith('.css')) return r.fulfill({ contentType: 'text/css', body: '' });
    return r.fulfill({ contentType: 'text/javascript', body: 'window.flatpickr=window.flatpickr||function(){return{setDate(){},clear(){},destroy(){}}};window.Chart=window.Chart||function(){return{destroy(){},update(){}}};' });
  });
  await p.route(/^https:\/\/(?!cdn\.jsdelivr).*/, r => r.fulfill({ body: '' }));
  await p.goto('file://' + path.resolve(__dirname, '../../index.html'));
  await p.waitForTimeout(1500);
  return { p, errs };
}
const norm = s => (s || '').replace(/\s+/g, ' ').trim();
const txt = async (p, sel) => norm(await p.innerText(sel));
let fails = 0;
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) fails++; };
const settle = p => p.waitForTimeout(700);

async function toCharge(p) {
  await p.click('#navInventory'); await settle(p);
  await p.click('#invMaterialChip [data-material=med]'); await settle(p);
  await p.click('#feedSubtabs .sub-tab[data-subtab=charge]'); await p.waitForTimeout(1000);
}
async function pick(p, sel, label) {
  await p.selectOption(sel, { label }); await p.waitForTimeout(150);
}

(async () => {
  const r = psql(`select 1`, 'postgres');
  if (r.status) { console.error(r.stderr); process.exit(2); }
  spawnSync('su', ['postgres', '-c', `dropdb --if-exists ${DB} && createdb -T ${BASE} ${DB}`], { encoding: 'utf8' });
  const layers0 = sql(`select string_agg(id || '=' || qty_remaining, ',' order by id) from med_purchase_lines`);
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' }).catch(() => chromium.launch());

  // ---- 1. office: a lot charge ----
  const F = await open(b, 'office'); const p = F.p;
  await toCharge(p);
  ok(await p.isVisible('#invChargeView'), 'office: Charge out screen opens');
  ok((await p.inputValue('#invChDate')) !== '', 'date defaults to today');
  await pick(p, '#invChMed', 'Cydectin Pour-On');
  ok((await p.inputValue('#invChLocation')) === 'e0000000-0000-0000-0000-000000000001', 'shelf defaults to the first ranch pool (Charge Barn)');
  await p.fill('#invChDate', '2026-10-06'); await p.dispatchEvent('#invChDate', 'change');
  await p.fill('#invChQty', '6000');
  ok(/1.20 bottle\(s\) of 5,000 mL/.test(await txt(p, '#invChBottles')), 'bottles shown: ' + await txt(p, '#invChBottles'));
  await pick(p, '#invChDest', 'A lot');
  ok(await p.isVisible('#invChLotRow') && !(await p.isVisible('#invChCcRow')), 'lot row shows, cost centre row hidden');
  const lotOpts = await p.$$eval('#invChLot option', os => os.map(o => o.textContent));
  ok(lotOpts.includes('60X') && !lotOpts.includes('50X'), 'lot picker: open lots only ' + lotOpts.join('/'));
  await pick(p, '#invChLot', '60X');
  ok(/Whole lot 60X in withdrawal until/.test(await txt(p, '#invChWarn')) && /does not stop/.test(await txt(p, '#invChWarn')),
     'withdrawal warns: ' + await txt(p, '#invChWarn'));
  await p.click('#invChSaveBtn'); await settle(p);
  ok(/Pick the closeout line/.test(await txt(p, '#invChAlert')) && sql(`select count(*) from med_charges`) === '0',
     'no category: refused on screen, nothing posted');
  await pick(p, '#invChCategory', 'Other');
  await p.fill('#invChNotes', 'Pour-on whole lot');
  await p.click('#invChSaveBtn'); await p.waitForTimeout(1200);
  const a1 = await txt(p, '#invChAlert');
  ok(/Charged 6,000.00 mL of Cydectin Pour-On to lot 60X \(Other\): \$620.00/.test(a1), 'posted: ' + a1);
  ok(sql(`select count(*) || '/' || sum(qty_units) from med_charges where destination = 'lot'`) === '1/6000', 'DB: one lot charge of 6000');
  ok(sql(`select total_cost from lot_med_costs_by_category where lot_id = 'a0000000-0000-0000-0000-000000000001' and category = 'other'`) === '620.0000',
     'DB: 60X other = 620.0000');
  const list1 = await txt(p, '#invChListContent');
  ok(/Cydectin Pour-On/.test(list1) && /Lot 60X · Other/.test(list1) && /\$620.00/.test(list1) && /Pour-on whole lot/.test(list1), 'recent list: ' + list1.slice(0, 140));
  ok(!(await p.isVisible('[data-inv-ch-undo]')), 'office: no Undo button');
  ok((await p.inputValue('#invChQty')) === '', 'qty cleared after post');

  // ---- 2. office: a cost-centre charge, coding shown / flagged ----
  await pick(p, '#invChDest', 'A cost centre');
  ok(!(await p.isVisible('#invChLotRow')) && await p.isVisible('#invChCcRow'), 'cost centre row shows');
  ok((await txt(p, '#invChWarn')) === '', 'no withdrawal warning for a cost centre');
  const ccOpts = await p.$$eval('#invChCc option', os => os.map(o => o.textContent));
  ok(ccOpts.includes('Bulls') && ccOpts.includes('Cow/Calf Wip') && !ccOpts.includes('Old Horses'), 'active cost centres only ' + ccOpts.join('/'));
  await pick(p, '#invChCc', 'Cow/Calf Wip');
  ok(/Coding missing/.test(await txt(p, '#invChCcCoding')) && /Profit Center and Production Center/.test(await txt(p, '#invChCcCoding')), 'Cow/Calf Wip: coding missing flagged');
  await pick(p, '#invChCc', 'Bulls');
  ok(/130000 Vet & Medicine – WIP · Profit Center PC-20 · Production Center BULLS/.test(await txt(p, '#invChCcCoding')), 'Bulls coding: ' + await txt(p, '#invChCcCoding'));
  await pick(p, '#invChMed', 'Draxxin');
  await p.fill('#invChQty', '100');
  await p.click('#invChSaveBtn'); await p.waitForTimeout(1200);
  ok(/to cost centre Bulls: \$200.00/.test(await txt(p, '#invChAlert')), 'cc posted: ' + await txt(p, '#invChAlert'));

  // ---- 3. short stock and a closed month: posted, and said ----
  sql(`insert into med_counts (location_id, count_date, status, is_opening) values ('e0000000-0000-0000-0000-000000000001', '2026-10-05', 'posted', false)`);
  await p.fill('#invChDate', '2026-10-03'); await p.dispatchEvent('#invChDate', 'change');
  await p.fill('#invChQty', '1000');
  await p.click('#invChSaveBtn'); await p.waitForTimeout(1200);
  const a3 = await txt(p, '#invChAlert');
  // 400 mL of Draxxin left after the 100 to Bulls.
  ok(/600.00 mL were not on that shelf/.test(a3) && /Given Oct 3, 2026, .* it posted Oct 6, 2026/.test(a3), 'short + date bump said: ' + a3);
  const list3 = await txt(p, '#invChListContent');
  ok(/600.00 uncovered/.test(list3) && /posted/.test(list3), 'list flags uncovered and posted date');

  // ---- 4. the Monday report ----
  await p.click('#feedSubtabs .group-btn:visible'); await settle(p);
  await p.click('#feedSubtabs .sub-tab[data-subtab=reports]'); await p.waitForTimeout(800);
  await p.selectOption('#invRepWhich', 'application'); await settle(p);
  await p.fill('#invRepFrom', '2026-10-01'); await p.dispatchEvent('#invRepFrom', 'change');
  await p.fill('#invRepTo', '2026-10-07'); await p.dispatchEvent('#invRepTo', 'change'); await p.waitForTimeout(1200);
  const rep = await txt(p, '#invReportsContent');
  ok(/Production Center 60X/.test(rep) && /Other \$620.00/.test(rep), 'report: 60X block, Other $620.00');
  // Headings are text-transform: uppercase, which innerText reports.
  const ccPart = rep.slice(rep.search(/cost centres —/i));
  ok(/^cost centres — 130000 Vet & Medicine - WIP/i.test(ccPart) && /Cost centre Bulls/.test(ccPart) && /PC-20/.test(ccPart)
     && /BULLS/.test(ccPart) && /Total medicine — Bulls \$2200.00/.test(ccPart),
     'report: Bulls block at 130000 with its coding: ' + ccPart.slice(0, 260));
  const usage = Number(sql(`select round(sum(total_cost), 2) from med_txns where direction = -1 and txn_type = 'usage' and txn_date between '2026-10-01' and '2026-10-07'`));
  const m = /All medicine used in the range \$([\d,]+\.\d\d)/.exec(rep);
  ok(m && Number(m[1].replace(/,/g, '')) === usage, `report total ${m && m[1]} = ledger usage ${usage}`);
  ok(/No lot, no cost centre/.test(rep), 'orphan (reference-less usage in the fixture) listed loudly, not dropped');
  ok(!/Do not post this week/.test(rep), 'blocks tie to the rows');
  await p.click('#invRepCopyBtn').catch(() => {});
  const rows = await p.evaluate(() => invReportRows);
  ok(rows.some(r => r[0] === 'Bulls' && r[7] === '130000 Vet & Medicine - WIP' && r[8] === 'PC-20' && r[9] === 'BULLS'), 'Copy rows carry the cost-centre account and coding');
  await p.screenshot({ path: `${SHOTS}/med-charge-report.png`, fullPage: true });

  // ---- 5. owner: undo ----
  const O = await open(b, 'owner');
  await toCharge(O.p);
  ok(await O.p.isVisible('[data-inv-ch-undo]'), 'owner: Undo buttons shown');
  await O.p.screenshot({ path: `${SHOTS}/med-charge-owner.png`, fullPage: true });
  const lotCharge = sql(`select id from med_charges where destination = 'lot' and qty_units = 6000`);
  await O.p.click(`[data-inv-ch-undo="${lotCharge}"]`); await O.p.waitForTimeout(1200);
  ok(/Charge undone. 6,000.00 unit\(s\) back on the shelf/.test(await txt(O.p, '#invChAlert')), 'undo: ' + await txt(O.p, '#invChAlert'));
  ok(sql(`select count(*) from lot_med_costs_by_category where lot_id = 'a0000000-0000-0000-0000-000000000001' and category = 'other'`) === '0', 'DB: 60X other row gone after undo');
  const lay = sql(`select qty_remaining || '/' || (select qty_remaining from med_purchase_lines where id = '90000000-0000-0000-0000-000000000002') from med_purchase_lines where id = '90000000-0000-0000-0000-000000000001'`);
  ok(/^5000(\.0+)?\/5000(\.0+)?$/.test(lay), 'DB: both Cydectin layers back to 5000 / 5000: ' + lay);
  // The 1,000 mL dated 10/3 posted 10/6, after the 10/5 count: still open.
  // The 100 mL to Bulls posted 10/6 too. Neither is in a closed month, so
  // close one: a count on 10/6 locks both.
  sql(`insert into med_counts (location_id, count_date, status, is_opening) values ('e0000000-0000-0000-0000-000000000001', '2026-10-06', 'posted', false)`);
  const ccCharge = sql(`select id from med_charges where cost_center_id is not null order by qty_units limit 1`);
  await O.p.click(`[data-inv-ch-undo="${ccCharge}"]`); await O.p.waitForTimeout(1200);
  ok(/Not undone: .*counted and closed/.test(await txt(O.p, '#invChAlert')) && sql(`select count(*) from med_charges where id = '${ccCharge}'`) === '1',
     'undo in a closed month refused and shown: ' + (await txt(O.p, '#invChAlert')).slice(0, 90));

  // ---- 6. crew: no tab at all ----
  const W = await open(b, 'crew');
  ok(!(await W.p.isVisible('#navInventory')) && !(await W.p.isVisible('#invChargeView')), 'crew: no Inventory, no Charge out');

  // ---- 7. phone width ----
  await p.setViewportSize({ width: 390, height: 844 });
  await toCharge(p);
  const wide = await p.evaluate(() => [...document.querySelectorAll('#invChargeView .form-grid *, #invChargeView .card-header *')]
    .filter(e => e.offsetParent && e.getBoundingClientRect().right > window.innerWidth + 1).map(e => e.tagName + '#' + e.id));
  ok(!wide.length, 'iphone: Charge out form fits ' + wide.join(' '));
  await p.screenshot({ path: `${SHOTS}/med-charge-iphone.png`, fullPage: true });

  for (const [n, e] of [['office', F.errs], ['owner', O.errs], ['crew', W.errs]]) ok(!e.length, `no page errors (${n}) ${e.join(' / ')}`);
  await b.close();
  console.log(fails ? `\n${fails} FAILED` : '\nALL PASS');
  process.exit(fails ? 1 : 0);
})();
