// Every calendar date box: a value set from code shows on screen.
// Loads the real index.html in headless Chromium with the REAL flatpickr
// 4.6.13 (FLATPICKR_JS = path to dist/flatpickr.min.js, e.g. from
// `npm pack flatpickr@4.6.13`) and a signed-out Supabase stand-in, so no data
// is read or written anywhere.
//   FLATPICKR_JS=... NODE_PATH=$(npm root -g) node scripts/date-sync-harness/run.js
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');
if (!process.env.FLATPICKR_JS) { console.error('Set FLATPICKR_JS'); process.exit(2); }
const FLATPICKR = fs.readFileSync(process.env.FLATPICKR_JS, 'utf8');
const FAKE = `window.supabase = { createClient: () => ({
  auth: { getSession: async () => ({ data: { session: null } }),
          onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }) },
  from: () => { const p = new Proxy(function(){}, { get: (t, k) => k === 'then' ? (ok) => ok({ data: [], error: null }) : () => p }); return p; },
  rpc: async () => ({ data: null, error: null }),
  get storage(){ return { from: () => ({}) }; },
  channel: () => ({ on(){ return this; }, subscribe(){ return this; } }), removeChannel(){} }) };`;
let fails = 0;
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) fails++; };

(async () => {
  const b = await chromium.launch();
  const p = await b.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('https://cdn.jsdelivr.net/**', r => {
    const u = r.request().url();
    if (u.includes('supabase-js')) return r.fulfill({ contentType: 'text/javascript', body: FAKE });
    if (u.includes('flatpickr') && u.endsWith('.js')) return r.fulfill({ contentType: 'text/javascript', body: FLATPICKR });
    if (u.endsWith('.css')) return r.fulfill({ contentType: 'text/css', body: '' });
    return r.fulfill({ contentType: 'text/javascript', body: 'window.Chart=window.Chart||function(){return{destroy(){},update(){}}};' });
  });
  await p.route(/^https:\/\/(?!cdn\.jsdelivr).*/, r => r.fulfill({ body: '' }));
  await p.goto('file://' + path.resolve(__dirname, '../../index.html'));
  await p.waitForTimeout(1500);

  const r = await p.evaluate(() => {
    const out = { total: 0, bad: [], changeEvents: 0 };
    const all = [...document.querySelectorAll('input')].filter(i => i._flatpickr && i._flatpickr.altInput);
    out.total = all.length;
    all.forEach(i => i.addEventListener('change', () => out.changeEvents++));
    all.forEach(i => {
      i.value = '2026-03-04';
      const alt = i._flatpickr.altInput.value;
      if (alt !== '03/04/2026' || i.value !== '2026-03-04') out.bad.push(`${i.id}: alt=${alt} value=${i.value}`);
    });
    const el = document.getElementById('invPurDate');
    el.value = '';
    out.cleared = [el.value, el._flatpickr.altInput.value];
    el.value = '2026-10-07';
    el.value = 'not a date';
    out.odd = [el.value, el._flatpickr.altInput.value];
    out.fromCode = out.changeEvents;
    // A pick from the calendar (flatpickr's own write) still lands once.
    out.changeEvents = 0;
    el._flatpickr.setDate('2026-10-01', true);
    out.picked = [el.value, el._flatpickr.altInput.value, out.changeEvents];
    return out;
  });
  ok(r.total >= 40, `calendar date boxes found: ${r.total}`);
  ok(r.bad.length === 0, 'every box shows a date set from code' + (r.bad.length ? ': ' + r.bad.slice(0, 5).join('; ') : ''));
  ok(r.fromCode === 0, 'setting from code fires no change event (same as before): ' + r.fromCode);
  ok(r.cleared[0] === '' && r.cleared[1] === '', 'setting "" clears the box');
  ok(r.odd[0] === 'not a date' && r.odd[1] === '10/07/2026', 'a non-date string is stored as before and does not wipe the calendar');
  ok(r.picked[0] === '2026-10-01' && r.picked[1] === '10/01/2026' && r.picked[2] === 1, 'a calendar pick still sets the value, one change event: ' + JSON.stringify(r.picked));

  // Typing in the visible box still works.
  const alt = await p.evaluateHandle(() => document.getElementById('invPurDate')._flatpickr.altInput);
  await p.evaluate(() => { document.getElementById('invMedPurchaseEntryView').classList.remove('hidden'); document.getElementById('loginScreen')?.classList.add('hidden'); document.getElementById('appShell')?.classList.remove('hidden'); });
  await alt.asElement().fill('10/05/2026');
  await alt.asElement().press('Enter');
  await p.waitForTimeout(200);
  ok(await p.evaluate(() => document.getElementById('invPurDate').value) === '2026-10-05', 'typing a date in the box still sets it');

  ok(errs.length === 0, 'no page errors' + (errs.length ? ': ' + errs.join(' | ') : ''));
  await b.close();
  console.log(fails ? `${fails} FAILED` : 'ALL PASS');
  process.exit(fails ? 1 : 0);
})();
