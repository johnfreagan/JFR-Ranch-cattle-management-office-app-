// Withdrawal warning harness (2026-09-27): loads the real index.html in
// headless Chromium with the Supabase CDN swapped for the pb-feed fake
// client, feeds withdrawal_holds the row a rolled-back fake treatment
// produced on the live database (37X tag 4218, Resflor, treated
// 2026-09-26, 38 d, clears 2026-11-03), and checks the warning:
//   - a ship date before the clear date opens the modal listing tag, drug
//     and clear date; Confirm resolves true (save goes ahead), Cancel false
//   - a ship date on/after the clear date shows nothing and resolves true
//   - a failed read is not treated as clear
//   - the approvals clear-date helpers compute the same date as the view
// Run: NODE_PATH=$(npm root -g) node scripts/withdrawal-harness/run.js
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const HOLD = { lot_id: 'a0f3902f-1a33-4e3e-9067-2fe977133e9a', lot_number: '37X', tag_number: '4218',
               drug: 'Resflor', treat_date: '2026-09-26', withdrawal_days: 38, clear_date: '2026-11-03' };
const fake = fs.readFileSync(path.join(__dirname, '../pb-feed-harness/fake.js'), 'utf8')
  .replace("if (table === 'user_profiles')",
    "if (table === 'withdrawal_holds') return S.holdsError ? { data:null, error:{ message:S.holdsError } } : { data: S.holds || [], error:null };\n      if (table === 'user_profiles')");
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) process.exitCode = 1; };
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' }).catch(() => chromium.launch());
  const p = await b.newPage({ viewport: { width: 900, height: 900 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('https://cdn.jsdelivr.net/**', r => {
    const u = r.request().url();
    if (u.includes('supabase-js')) return r.fulfill({ contentType: 'text/javascript', body: fake });
    if (u.endsWith('.css')) return r.fulfill({ contentType: 'text/css', body: '' });
    return r.fulfill({ contentType: 'text/javascript', body: 'window.flatpickr=window.flatpickr||function(){return{setDate(){},clear(){},destroy(){}}};window.Chart=window.Chart||function(){return{destroy(){},update(){}}};' });
  });
  await p.route(/^https:\/\/(?!cdn\.jsdelivr).*/, r => r.fulfill({ body: '' }));
  await p.goto('file://' + path.resolve(__dirname, '../../index.html'));
  await p.waitForTimeout(1200);
  await p.evaluate(h => { window.__state.holds = [h]; }, HOLD);

  // 1. sale dated before the clear date: warning appears
  let pending = p.evaluate(id => withdrawalConfirm([{ lot_id: id, date: '2026-10-15' }], 'this sale').then(v => (window.__wd = v)), HOLD.lot_id);
  await p.waitForTimeout(300);
  ok(await p.isVisible('#withdrawalModal'), 'warning modal opens for a sale dated 2026-10-15');
  const txt = (await p.textContent('#withdrawalModal')).replace(/\s+/g, ' ');
  ok(txt.includes('4218') && txt.includes('Resflor') && /Nov 3|11\/3|2026-11-03/.test(txt), 'lists tag 4218, Resflor, clears Nov 3');
  ok(txt.includes('1 tag') && txt.includes('37X'), 'intro names 1 tag on 37X');
  fs.mkdirSync(path.join(__dirname, 'out'), { recursive: true });
  await p.screenshot({ path: path.join(__dirname, 'out', 'withdrawal-warning.png') });
  await p.click('#withdrawalConfirmBtn'); await pending;
  ok(await p.evaluate(() => window.__wd) === true && !(await p.isVisible('#withdrawalModal')), 'Confirm closes and lets the save go ahead');

  // 2. Cancel goes back
  pending = p.evaluate(id => withdrawalConfirm([{ lot_id: id, date: '2026-10-15' }], 'this sale').then(v => (window.__wd = v)), HOLD.lot_id);
  await p.waitForTimeout(300);
  await p.click('#withdrawalCancelBtn'); await pending;
  ok(await p.evaluate(() => window.__wd) === false, 'Cancel returns to the form');

  // 3. ship date on the clear date: no warning
  const clear = await p.evaluate(id => withdrawalConfirm([{ lot_id: id, date: '2026-11-03' }], 'this sale'), HOLD.lot_id);
  ok(clear === true && !(await p.isVisible('#withdrawalModal')), 'no warning on/after the clear date');

  // 4. shipment across two days: checked at the first
  pending = p.evaluate(id => withdrawalConfirm([{ lot_id: id, date: '2026-11-05' }, { lot_id: id, date: '2026-11-01' }], 'this shipment').then(v => (window.__wd = v)), HOLD.lot_id);
  await p.waitForTimeout(300);
  ok(await p.isVisible('#withdrawalModal'), 'multi-day shipment is checked at its first load day');
  await p.click('#withdrawalConfirmBtn'); await pending;

  // 5. a failed read asks instead of passing silently
  await p.evaluate(() => { window.__state.holdsError = 'permission denied'; });
  let asked = null;
  p.once('dialog', d => { asked = d.message(); d.dismiss(); });
  const r5 = await p.evaluate(id => withdrawalConfirm([{ lot_id: id, date: '2026-10-15' }], 'this sale'), HOLD.lot_id);
  ok(r5 === false && asked && asked.includes('Could not check withdrawal'), 'read error asks, Cancel returns false');
  await p.evaluate(() => { window.__state.holdsError = null; });

  // 6. approvals clear date = Chicago treat day + withdrawal days (the view's rule)
  const d = await p.evaluate(() => [addDaysIso(chicagoDayOf('2026-09-27T03:25:55Z'), 38), chicagoDayOf('2026-09-27T03:25:55Z')]);
  ok(d[1] === '2026-09-26' && d[0] === '2026-11-03', 'approvals: 9:25pm Central on 9/26 treated 9/26, clears 2026-11-03 ' + d);

  ok(!errs.length, 'no page errors ' + errs.join(' / '));
  await b.close();
})();
