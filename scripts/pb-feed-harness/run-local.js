// Approvals > Feed end-to-end on a SCRATCH copy of the database: the real
// index.html in headless Chromium, every rpc() run through psql against a
// local Postgres that holds the live PB functions and a snapshot of the
// ranch (see docs/feed-pb-import.md, "Testing the Feed tab"). Never points
// at Supabase. Needs the scratch server on /tmp:5499 with databases
// feed_base (9/28 staged, untouched) and feed (recreated from it here).
// The cost-centre suite at the end runs on cc_ui (recreated from cc_ui_base:
// feed_base + local/05_cc_seed.sql + the real 10/1 email staged, Nichols Trap
// moved to Nichols Front Trap + docs/sql/2026-10-03_pb_drop_cost_center.sql).
// Set PB_BASE to run the 9/28 suite on another template (e.g. one with the
// 10-03 migration applied).
//   NODE_PATH=$(npm root -g) node scripts/pb-feed-harness/run-local.js [shots-dir]
const { chromium } = require('playwright');
const { spawnSync } = require('child_process');
const fs = require('fs'), path = require('path');
const SHOTS = process.argv[2] || '/tmp';
let DB = 'feed';
let TODAY = '2026-09-29';   // ranch_today() for the 9/28 suite; the 10/1 suite moves it to 10/2
const BASE = process.env.PB_BASE || 'feed_base';
const U = { owner: 'ff89f282-7c9d-40e5-abe7-e4899dce7122', office: '7cf00eec-3786-4316-bf7f-b329478e8e43',
            crew: '24d1b1f0-652c-4c9f-944b-188111f1b1bc' };
const D = '2026-09-28';
const PG = ['-h', '/tmp', '-p', '5499', '-U', 'postgres'];

function sql(q, uid) {
  const r = spawnSync('psql', [...PG, '-d', DB, '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1'], { encoding: 'utf8',
    input: `begin;\nset local request.jwt.claim.sub = '${uid || ''}';\nset local jfr.today = '${TODAY}';\n${q};\ncommit;\n` });
  if (r.status) {
    const m = /ERROR:\s+([\s\S]*?)(?:\n(?:CONTEXT|DETAIL|HINT|LINE|psql:)|\s*$)/.exec(r.stderr);
    throw new Error(m ? m[1].trim() : r.stderr);
  }
  return r.stdout.trim();
}
const lit = v => v == null ? 'NULL' : "'" + (typeof v === 'object' ? JSON.stringify(v) : String(v)).replace(/'/g, "''") + "'";
const J = (q, uid) => { const o = sql(q, uid); return o === '' ? null : JSON.parse(o); };

function rpc(uid, fn, args) {
  if (!/^[a-z_]+$/.test(fn)) return { data: null, error: { message: 'bad fn' } };
  const a = Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}`).join(', ');
  try { return { data: J(`select to_jsonb(public.${fn}(${a}))`, uid), error: null }; }
  catch (e) { return { data: null, error: { message: e.message } }; }
}
function from(uid, q) {
  const f = {}; q.filters.forEach(x => { f[x[0] + ':' + x[1]] = x[2]; });
  try {
    switch (q.table) {
      case 'user_profiles': return { data: J(`select to_jsonb(u) from user_profiles u where id = ${lit(f['eq:id'])}`), error: null };
      case 'pb_daily_reports':
        if (q.head) return { data: null, count: Number(sql(`select count(*) from pb_daily_reports where status = 'pending'`)), error: null };
        return { data: J(`select coalesce(jsonb_agg(jsonb_build_object('report_date', report_date, 'gmail_message_id', gmail_message_id,
          'staged_at', staged_at, 'status', status)), '[]') from pb_daily_reports where report_date >= ${lit(f['gte:report_date'])}`), error: null };
      case 'ranch_settings': return { data: J(`select coalesce(jsonb_agg(jsonb_build_object('pb_email_post_from', pb_email_post_from)), '[]') from ranch_settings`), error: null };
      case 'cost_centers': return { data: J(`select coalesce(jsonb_agg(jsonb_build_object('name', name) order by name), '[]') from cost_centers where is_active`), error: null };
      case 'pastures': return { data: J(`select jsonb_agg(jsonb_build_object('name', p.name, 'ranches', jsonb_build_object('name', r.name)))
          from pastures p join ranches r on r.id = p.ranch_id where p.is_active`), error: null };
      default: return { data: q.single ? null : [], error: null, count: 0 };
    }
  } catch (e) { return { data: null, error: { message: e.message } }; }
}

const fake = fs.readFileSync(__dirname + '/fake-local.js', 'utf8');
async function open(b, role, vp) {
  const p = await b.newPage({ viewport: vp || { width: 1000, height: 1400 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.addInitScript(uid => { window.__uid = uid; }, U[role]);
  await p.exposeFunction('__rpc', (fn, args) => rpc(U[role], fn, args));
  await p.exposeFunction('__from', q => from(U[role], q));
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
async function feed(p) {
  await p.click('#navApprovals'); await p.waitForTimeout(500);
  await p.click('[data-appr-pane=feed]'); await p.waitForTimeout(800);
}
const norm = s => (s || '').replace(/\s+/g, ' ').trim();
const card = `.pb-card[data-date="${D}"]`;
const txt = async (p, sel) => norm(await p.innerText(sel));
let fails = 0;
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) fails++; };
const settle = p => p.waitForTimeout(700);
const invTotal = () => sql(`select sum(qty_lb_remaining) from feed_receipts`);
const inv0 = () => {
  sql(`create table if not exists _inv0 as select id, qty_lb_remaining from feed_receipts`);
};

(async () => {
  const r = spawnSync('bash', ['-c', `dropdb ${PG.join(' ')} --if-exists ${DB} && createdb ${PG.join(' ')} -T ${BASE} ${DB}`], { encoding: 'utf8' });
  if (r.status) { console.error(r.stderr); process.exit(2); }
  inv0();
  const base = invTotal();
  console.log('inventory before: ' + base);
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' }).catch(() => chromium.launch());

  // ---- 1. read path, owner ----
  const O = await open(b, 'owner');
  const p = O.p;
  ok((await txt(p, '#apprFeedCount')) === '1', 'feed tab red count = 1 pending');
  await feed(p);
  ok((await p.$$(`${card} .pb-sec:has(h4:text-is("Pens")) tbody tr:not(.pb-actrow)`)).length === 2, 'pens: 2 rows');
  ok((await p.$$(`${card} .pb-sec:has(h4:text-is("Ingredients")) tbody tr`)).length === 7, 'ingredients: 7 rows');
  const head = await txt(p, `${card} .pb-head`);
  ok(/Mon Sep 28/.test(head) && /pending · blocked/.test(head) && /2 loads · 34,440 lb fed/.test(head), 'header: ' + head);
  const prob = await txt(p, `${card} .pb-problem`);
  ok(/No real lot is standing in Garrett Goat Hill/.test(prob), 'Goat Hill problem: ' + prob.slice(0, 90) + '…');
  ok((await p.$eval(`${card} .pb-problem`, e => getComputedStyle(e).color)) === 'rgb(179, 18, 31)', 'problem is red');
  ok(await p.isDisabled(`${card} [data-pb=approve]`) && /Fix the problem above to approve\./.test(await txt(p, `${card} .pb-acts`)), 'approve disabled + reason');
  const ch = await txt(p, `${card} .pb-sec:has(h4:text-is("Charges to"))`);
  console.log('     charges: ' + ch);
  ok(/37X 3,999.81 lb/.test(ch) && /37X-1 1,882.29 lb/.test(ch) && /37X-F 705.83 lb/.test(ch) && /59X 705.83 lb/.test(ch), 'charges 37X/37X-1/37X-F/59X');
  ok((await p.$$(`${card} .pb-lot:not(.pb-total)`)).length === 4, 'exactly 4 lots charged, no prefeed block yet');
  ok(/Total 7,293.76 lb/.test(ch) && /27,146.24 lb has nowhere to go yet/.test(ch), 'total 7,293.76, 27,146.24 nowhere to go');
  ok(/PB head movements/.test(await txt(p, `${card} .pb-note`)), 'PB head movements note in amber');
  ok(!(await p.$('.pb-waiting')), 'no waiting banner before approve');
  ok((await p.textContent(`${card}`)).includes('Undo prefeed') === false, 'no pen marked prefeed yet');

  // layout on iPhone and iPad
  for (const [name, vp] of [['iphone', { width: 390, height: 844 }], ['ipad', { width: 820, height: 1180 }]]) {
    await p.setViewportSize(vp); await p.waitForTimeout(200);
    // The app header (nav tabs, user badge) is wider than a phone on main already;
    // this checks only the Feed pane: nothing in it may push past the screen edge
    // except inside a table's own scroll box.
    const wide = await p.evaluate(() => [...document.querySelectorAll('#apprFeedPane *')]
      .filter(e => e.offsetParent && !e.closest('.pb-tbl') && e.getBoundingClientRect().right > window.innerWidth + 1)
      .slice(0, 8).map(e => e.tagName + '.' + e.className + ' ' + Math.round(e.getBoundingClientRect().right)));
    const small = await p.$$eval('#apprFeedPane button, #apprFeedPane select, #apprFeedPane input', els => els
      .filter(e => e.offsetParent).filter(e => e.getBoundingClientRect().height < 40).map(e => e.outerHTML.slice(0, 60)));
    ok(!wide.length, `${name}: Feed pane fits the screen, tables scroll in their own box ${wide.join(' | ')}`);
    ok(!small.length, `${name}: tap targets >= 40px ${small.join(' ')}`);
    await p.screenshot({ path: `${SHOTS}/feed-${name}-pending.png`, fullPage: true });
  }
  await p.setViewportSize({ width: 1000, height: 1400 });

  // ---- 2. roles ----
  const W = await open(b, 'crew');
  ok(!(await W.p.isVisible('[data-appr-pane=feed]')) && !(await W.p.isVisible('#navApprovals')), 'crew: no Feed tab (and no Approvals)');
  ok(!(await W.p.evaluate(() => window.__calls)).some(c => c.fn === 'pb_report_list'), 'crew: pb_report_list never called');
  const F = await open(b, 'office');
  await feed(F.p);
  ok(await F.p.isVisible(`${card} [data-pb=prefeed]`) && await F.p.isVisible(`${card} [data-pb=reject]`), 'office: Move/Split/Prefeed/Reject shown');
  ok(!(await F.p.isVisible('[data-pb=unpost]')), 'office: no Unpost');

  // ---- 3a. split: running sum, save shut until it ties (cancelled, not saved) ----
  await p.click(`${card} [data-pb=split][data-pen="Garrett- Goat Hill"]`); await settle(p);
  const rows = await p.$$('.pb-split .pb-row[data-i]');
  await rows[0].$eval('select', s => { s.value = s.options[1].value; s.dispatchEvent(new Event('change', { bubbles: true })); });
  await (await rows[0].$('.pb-lb')).fill('20000');
  await rows[1].$eval('select', s => { s.value = s.options[2].value; s.dispatchEvent(new Event('change', { bubbles: true })); });
  await (await rows[1].$('.pb-lb')).fill('7000');
  ok(await p.isDisabled('#pbSplitSave') && /27,000 of 27,120 lb · 120 lb still to place/.test(await txt(p, '#pbSplitLeft')), 'split short: ' + await txt(p, '#pbSplitLeft'));
  await (await rows[1].$('.pb-lb')).fill('7,120');
  ok(!(await p.isDisabled('#pbSplitSave')) && /27,120 of 27,120 lb ✓/.test(await txt(p, '#pbSplitLeft')), 'split ties: ' + await txt(p, '#pbSplitLeft'));
  await p.click('.pb-split [data-pb=cancel]'); await settle(p);

  // ---- 3b. prefeed on, off, on ----
  await p.click(`${card} [data-pb=prefeed][data-pen="Garrett- Goat Hill"]`); await settle(p);
  let pens = await txt(p, `${card} .pb-sec:has(h4:text-is("Pens"))`);
  ok(/Prefeed - first lot in pays/.test(pens) && /Undo prefeed/.test(pens), 'prefeed chip + Undo prefeed');
  ok(!(await p.$(`${card} .pb-problem`)) && !(await p.isDisabled(`${card} [data-pb=approve]`)), 'problem gone, Approve enabled');
  let c2 = await txt(p, `${card} .pb-sec:has(h4:text-is("Charges to"))`);
  ok(/Prefeed · Garrett Goat Hill 27,146.24 lb Will hold/.test(c2) && /Total 34,440 lb Ties to ingredient pounds fed/.test(c2), 'charges: will hold 27,146.24, total 34,440');
  await p.click(`${card} [data-pb=prefeed][data-pen="Garrett- Goat Hill"]`); await settle(p);
  ok(!!(await p.$(`${card} .pb-problem`)) && (await txt(p, `${card} [data-pb=prefeed][data-pen="Garrett- Goat Hill"]`)) === 'Prefeed', 'Undo prefeed: problem back, button reads Prefeed');
  await p.click(`${card} [data-pb=prefeed][data-pen="Garrett- Goat Hill"]`); await settle(p);
  ok(sql(`select bool_and(prefeed) from pb_report_lines l join pb_daily_reports r on r.id = l.report_id where r.report_date = '${D}' and l.line_kind = 'drop' and l.pb_name = 'Garrett- Goat Hill'`) === 't', 'DB: Goat Hill lines prefeed = true');
  await p.screenshot({ path: `${SHOTS}/feed-desktop-prefeed.png`, fullPage: true });

  // ---- 3c. approve ----
  await p.fill(`#pbNote-${D}`, 'harness test');
  await p.click(`${card} [data-pb=approve]`); await p.waitForTimeout(1500);
  ok(!(await p.$(card)) && /Mon Sep 28 approved 34,440 lb Approved by John@JFR/.test(await txt(p, `.pb-mini[data-date="${D}"]`)), 'approved: collapsed row ' + await txt(p, `.pb-mini[data-date="${D}"]`));
  ok(/“harness test”/.test(await txt(p, `.pb-mini[data-date="${D}"]`)), 'collapsed row shows the note');
  const wait = await txt(p, '.pb-waiting');
  ok(wait === 'Prefeed waiting: Garrett Goat Hill · 27,146 lb since 9/28 (1 day)', 'banner: ' + wait);
  ok((await txt(p, '#apprFeedCount')) === '0', 'feed count 0');
  const lotsDb = sql(`select string_agg(lo.lot_number || '=' || s, ' ' order by lo.lot_number) from (select lot_id, sum(qty_lb) s from feed_usage where pb_row_key like 'pbmail:${D}:%' and destination_type = 'lot' group by 1) x join lots lo on lo.id = x.lot_id`);
  const lotSum = sql(`select sum(qty_lb) from feed_usage where pb_row_key like 'pbmail:${D}:%' and destination_type = 'lot'`);
  const held = sql(`select sum(qty_lb) from feed_prefeed_holds where status = 'held'`);
  const xfer = sql(`select sum(qty_lb) from feed_usage where pb_row_key like 'pbmail:${D}:%' and destination_type = 'transfer'`);
  console.log(`     DB lots ${lotsDb}; lots ${lotSum}; transfer ${xfer}; held ${held}`);
  ok(Number(lotSum) === 7293.76 && Number(held) === 27146.24 && Number(xfer) === 27146.24, 'DB: front lots 7,293.76, Goat Hill holds 27,146.24');
  ok(Math.round((Number(lotSum) + Number(held)) * 100) / 100 === 34440, 'DB: lots + holds = 34,440');
  await p.click(`.pb-mini[data-date="${D}"]`); await settle(p);
  let c3 = await txt(p, `${card} .pb-sec:has(h4:text-is("Charges to"))`);
  ok(/What posted/.test(c3) && /Prefeed · Garrett Goat Hill 27,146.24 lb Held - waiting for cattle/.test(c3) && /Total 34,440 lb/.test(c3), 'expanded: posted basis, held 27,146.24, total 34,440');
  ok(!(await p.$(`${card} [data-pb=prefeed]`)) && !(await p.$(`${card} [data-pb=approve]`)), 'expanded approved card is read-only');
  ok(await p.isVisible(`${card} [data-pb=unpost]`), 'owner sees Unpost');
  await p.screenshot({ path: `${SHOTS}/feed-desktop-approved.png`, fullPage: true });

  // ---- 2b. office on a stale screen: the database refuses and the text shows as-is ----
  await F.p.click(`${card} [data-pb=prefeed][data-pen="Garrett- Goat Hill"]`); await settle(F.p);
  const stale = await txt(F.p, `${card} .pb-err .pb-problem`);
  ok(stale === `pb_mark_prefeed: no pending PB report for ${D}.`, 'office stale click, DB error shown exactly: ' + stale);
  await F.p.click('#approvalsRefreshBtn'); await settle(F.p);
  await F.p.click(`.pb-mini[data-date="${D}"]`); await settle(F.p);
  ok(!(await F.p.isVisible('[data-pb=unpost]')), 'office: approved day has no Unpost');

  // ---- 3d. 36-27 moves one head into Goat Hill the next day ----
  sql(`update lot_pasture_assignments a set head_count = head_count - 1 from lots l, pastures p where l.id = a.lot_id and p.id = a.pasture_id
         and l.lot_number = '36-27' and p.name = '1' and a.moved_out is null;
       insert into lot_pasture_assignments (lot_id, pasture_id, head_count, moved_in, recorded_by)
       select l.id, p.id, 1, '2026-09-29', '${U.owner}' from lots l, pastures p join ranches r on r.id = p.ranch_id
        where l.lot_number = '36-27' and r.name = 'Garrett' and p.name = 'Goat Hill'`, U.owner);
  const pre = sql(`select lo.lot_number || '=' || sum(u.qty_lb)::numeric(14,2) || ' on ' || min(u.usage_date) from feed_usage u join lots lo on lo.id = u.lot_id where u.pb_row_key like 'pbpre:%' group by lo.lot_number`);
  console.log('     prefeed charge: ' + pre);
  ok(pre === '36-27=27146.24 on 2026-09-29', 'DB: 27,146.24 charged to 36-27 on 9/29');
  await p.click('#approvalsRefreshBtn'); await p.waitForTimeout(1200);
  ok(!(await p.$('.pb-waiting')) || (await txt(p, '#pbWaiting')) === '', 'waiting banner gone');
  c3 = await txt(p, `${card} .pb-sec:has(h4:text-is("Charges to"))`);
  ok(/Charged to first lot in on/.test(c3) && /Total 34,440 lb/.test(c3), 'charges: charged to first lot in, total 34,440');
  const drop = Math.round((Number(base) - Number(invTotal())) * 100) / 100;
  ok(drop === 34440, 'DB: inventory down exactly 34,440 (' + drop + ')');

  // ---- 3e. unpost ----
  await p.click(`${card} [data-pb=unpost]`); await settle(p);
  await p.click(`${card} [data-pb=unpost-save]`); await settle(p);
  ok(/Give a reason for unposting\./.test(await txt(p, card)) && !(await p.evaluate(() => window.__calls)).some(c => c.fn === 'unpost_pb_report'), 'unpost needs a reason, no rpc');
  await p.fill('#pbReason', 'harness unpost');
  await p.click(`${card} [data-pb=unpost-save]`); await p.waitForTimeout(1500);
  const after = invTotal();
  const layersOff = sql(`select count(*) from feed_receipts f full join _inv0 i using (id) where f.qty_lb_remaining is distinct from i.qty_lb_remaining`);
  const left = sql(`select (select count(*) from feed_usage where pb_row_key like 'pbmail:%' or pb_row_key like 'pbpre:%') || '/' || (select count(*) from feed_prefeed_holds)`);
  console.log(`     after unpost: inventory ${after}, layers differing ${layersOff}, usage/holds left ${left}`);
  ok(Number(after) === Number(base) && layersOff === '0' && left === '0/0', 'unpost puts every pound back');
  ok(/pending/.test(await txt(p, `${card} .pb-head`)) && /Undo prefeed/.test(await txt(p, card)), 'card pending again, prefeed mark kept');
  ok((await txt(p, '#apprFeedCount')) === '1', 'feed count back to 1');

  for (const [n, e] of [['owner', O.errs], ['office', F.errs], ['crew', W.errs]]) ok(!e.length, `no page errors (${n}) ${e.join(' / ')}`);

  // ---- 4. cost centre: the real 10/1 day, Nichols Trap -> Cow/Calf Wip ----
  DB = 'cc_ui'; TODAY = '2026-10-02';
  const r2 = spawnSync('bash', ['-c', `dropdb ${PG.join(' ')} --if-exists ${DB} && createdb ${PG.join(' ')} -T cc_ui_base ${DB}`], { encoding: 'utf8' });
  if (r2.status) { console.error(r2.stderr); process.exit(2); }
  sql(`drop table if exists _inv0; create table _inv0 as select id, qty_lb_remaining from feed_receipts`);
  const base2 = invTotal();
  const C = await open(b, 'owner');
  const cp = C.p, c1 = `.pb-card[data-date="2026-10-01"]`;
  await feed(cp);
  ok(/No real lot is standing in Nichols Front Trap/.test(await txt(cp, `${c1} .pb-problem`)) && await cp.isDisabled(`${c1} [data-pb=approve]`), '10/1: Front Trap blocked before cost centre');
  await cp.click(`${c1} [data-pb=cc][data-pen="Nichols Trap"]`); await settle(cp);
  ok((await cp.$$eval(`${c1} .pb-ccsel option`, o => o.map(x => x.value))).join('|') === 'Cow/Calf Wip', 'cost centre picker lists Cow/Calf Wip');
  await cp.click(`${c1} [data-pb=cc-save]`); await cp.waitForTimeout(1200);
  const pens2 = await txt(cp, `${c1} .pb-sec:has(h4:text-is("Pens"))`);
  ok(/Cost centre · Cow\/Calf Wip/.test(pens2) && /Undo cost centre/.test(pens2), 'tag + Undo cost centre shown');
  ok(!(await cp.$(`${c1} .pb-problem`)) && !(await cp.isDisabled(`${c1} [data-pb=approve]`)), 'problem gone, Approve enabled');
  let ch2 = await txt(cp, `${c1} .pb-sec:has(h4:text-is("Charges to"))`);
  console.log('     charges: ' + ch2);
  ok(/36-27 4,890 lb/.test(ch2) && /Cost centre · Cow\/Calf Wip 7,970 lb/.test(ch2) && /Total 12,860 lb Ties to ingredient pounds fed/.test(ch2), 'charges: 36-27 4,890 + Cow/Calf Wip 7,970 = 12,860');
  for (const [name, vp] of [['iphone', { width: 390, height: 844 }]]) {
    await cp.setViewportSize(vp); await cp.waitForTimeout(200);
    const wide = await cp.evaluate(() => [...document.querySelectorAll('#apprFeedPane *')]
      .filter(e => e.offsetParent && !e.closest('.pb-tbl') && e.getBoundingClientRect().right > window.innerWidth + 1).length);
    ok(!wide, `${name}: cost-centre card fits the screen`);
    const clipped = await cp.evaluate(() => [...document.querySelectorAll('#apprFeedPane .pb-btnrow button')]
      .filter(e => e.offsetParent && e.getBoundingClientRect().right > e.closest('.pb-tbl').getBoundingClientRect().right + 1).map(e => e.textContent));
    ok(!clipped.length, `${name}: pen buttons all visible ${clipped.join(', ')}`);
    await cp.screenshot({ path: `${SHOTS}/feed-${name}-costcentre.png`, fullPage: true });
  }
  await cp.setViewportSize({ width: 1000, height: 1400 });
  await cp.click(`${c1} [data-pb=approve]`); await cp.waitForTimeout(1500);
  const posted = sql(`select string_agg(destination_type || '=' || s, ' ' order by destination_type) from (select destination_type, sum(qty_lb)::numeric(14,2) s from feed_usage where pb_row_key like 'pbmail:2026-10-01:%' group by 1) x`);
  console.log('     posted: ' + posted);
  ok(posted === 'cost_center=7970.00 lot=4890.00', 'DB: cost_center 7,970 + lot 4,890');
  ok(Math.round((Number(base2) - Number(invTotal())) * 100) / 100 === 12860, 'DB: inventory down exactly 12,860');
  await cp.click(`.pb-mini[data-date="2026-10-01"]`); await settle(cp);
  ch2 = await txt(cp, `${c1} .pb-sec:has(h4:text-is("Charges to"))`);
  ok(/What posted/.test(ch2) && /Cost centre · Cow\/Calf Wip 7,970 lb/.test(ch2), 'approved card: posted to Cow/Calf Wip 7,970');
  await cp.click(`${c1} [data-pb=unpost]`); await settle(cp);
  await cp.fill('#pbReason', 'harness cc unpost');
  await cp.click(`${c1} [data-pb=unpost-save]`); await cp.waitForTimeout(1500);
  const off2 = sql(`select count(*) from feed_receipts f full join _inv0 i using (id) where f.qty_lb_remaining is distinct from i.qty_lb_remaining`);
  ok(off2 === '0' && sql(`select count(*) from feed_usage where pb_row_key like 'pbmail:2026-10-01:%'`) === '0', 'unpost puts every pound back');
  await cp.click(`${c1} [data-pb=cc-undo][data-pen="Nichols Trap"]`); await cp.waitForTimeout(1200);
  ok(/No real lot is standing in Nichols Front Trap/.test(await txt(cp, `${c1} .pb-problem`)) && (await txt(cp, `${c1} [data-pb=cc][data-pen="Nichols Trap"]`)) === 'Cost centre', 'Undo cost centre: problem back, button reads Cost centre');
  ok(!C.errs.length, 'no page errors (cost centre) ' + C.errs.join(' / '));
  await b.close();
  console.log(fails ? `${fails} FAILED` : 'ALL PASS');
  process.exitCode = fails ? 1 : 0;
})();
