// Field app dead-letter harness (2026-09-27). Loads the real field-app in
// headless Chromium with supabase.min.js swapped for a fake client whose
// staging upsert returns whatever error the test sets, then checks:
//   - a deactivated user's queued entry (42501, the code the live database
//     returns - verified in a rolled-back transaction) leaves the queue for
//     the Failed list WHOLE, with the error in plain words
//   - the red "N failed" badge, the list, Copy (full entry + error)
//   - network errors stay queued and keep retrying
//   - 23xxx and 22xxx also land in Failed
//   - Retry while still refused comes back to Failed, nothing lost
//   - the Failed list survives a reload and is not on either reset list
//   - after reactivation, Retry delivers the original entry verbatim
// Run: NODE_PATH=$(npm root -g) node scripts/field-deadletter-harness/run.js
const { chromium } = require('playwright');
const path = require('path');

const FAKE = `(function(){
  const S = window.__state = JSON.parse(sessionStorage.getItem('__fakeState') || 'null') || { upsertError: null, network: false };
  const sent = window.__sent = [];
  function builder(table){
    const q = { table, op: 'select', single: false, row: null };
    const res = () => {
      if (q.op === 'upsert' || q.op === 'update' || q.op === 'insert') {
        if (S.network) return Promise.reject(new TypeError('Failed to fetch'));
        if (S.upsertError) return Promise.resolve({ data: null, error: S.upsertError });
        sent.push({ table, op: q.op, row: q.row });
        return Promise.resolve({ data: null, error: null });
      }
      if (table === 'user_profiles') return Promise.resolve({ data: { full_name: 'Test Crew', role: 'crew', is_active: true }, error: null });
      return Promise.resolve({ data: q.single ? null : [], error: null, count: 0 });
    };
    const p = new Proxy(function(){}, { get(t, k){
      if (k === 'then') return (a, b) => res().then(a, b);
      if (k === 'maybeSingle' || k === 'single') return () => { q.single = true; return p; };
      if (['upsert','update','insert','delete'].includes(k)) return (row) => { q.op = k; q.row = row; return p; };
      return () => p;
    }});
    return p;
  }
  const client = {
    from: builder,
    rpc: async () => ({ data: null, error: null }),
    auth: {
      getSession: async () => ({ data: { session: { user: { id: 'u-crew', email: 'crew@x' } } } }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
      signOut: async () => ({}), signInWithPassword: async () => ({ data: {}, error: null }),
      getUser: async () => ({ data: { user: { id: 'u-crew' } } })
    }
  };
  window.supabase = { createClient: () => client };
})();`;

const ENTRY = { id: 1790000000001, type: 'doctoring', tagNumber: '4218', lotNumber: '37X',
  treatmentType: '1st Pull', dateTime: '2026-09-26T21:10:00', ranch: 'Corner', location: 'Corner - 1',
  medication1: 'Resflor', dosage1: '10', medication2: '', dosage2: '', notes: 'queued Tuesday', recordedBy: 'Test Crew' };
const PERM = { code: '42501', message: 'new row violates row-level security policy for table "pending_field_entries"' };
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) process.exitCode = 1; };
const wait = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' }).catch(() => chromium.launch());
  const ctx = await b.newContext({ viewport: { width: 420, height: 900 } });
  await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: 'https://field.test' });
  const p = await ctx.newPage();
  // Registered first so the field.test route below (registered later) wins.
  await p.route(/^https:\/\//, r => r.fulfill({ body: '' }));
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  const dir = path.resolve(__dirname, '../../field-app');
  await p.route('https://field.test/**', r => {
    const u = new URL(r.request().url());
    let f = u.pathname.replace(/^\//, '') || 'index.html';
    if (f.startsWith('supabase.min.js')) return r.fulfill({ contentType: 'text/javascript', body: FAKE });
    if (f === 'sw.js') return r.fulfill({ status: 404, body: '' });
    return r.fulfill({ path: path.join(dir, f) });
  });
  const setState = s => p.evaluate(s => { Object.assign(window.__state, s); sessionStorage.setItem('__fakeState', JSON.stringify(window.__state)); }, s);
  await p.goto('https://field.test/index.html');
  await wait(1500);

  // 1. the deactivated user's queued entry
  await setState({ upsertError: PERM });
  await p.evaluate(e => { enqueueForSync(e); }, ENTRY);
  await wait(600);
  let st = await p.evaluate(() => ({ q: syncQueue.length, f: failedEntries, stored: JSON.parse(localStorage.getItem('betaCattleFailed') || '[]') }));
  ok(st.q === 0, 'refused entry leaves the retry queue');
  ok(st.f.length === 1 && st.f[0].code === '42501', 'lands in Failed with code 42501');
  ok(JSON.stringify(st.f[0].entry) === JSON.stringify(ENTRY), 'the FULL entry is kept, field for field');
  ok(st.stored.length === 1 && JSON.stringify(st.stored[0].entry) === JSON.stringify(ENTRY), 'and persisted to localStorage');
  ok(await p.isVisible('#failedBadge') && (await p.textContent('#failedBadge')).includes('1 failed'), 'red badge reads "1 failed"');
  const bg = await p.$eval('#failedBadge', el => getComputedStyle(el).backgroundColor);
  ok(bg === 'rgb(215, 0, 21)', 'badge is red ' + bg);

  // 2. the list, in plain words, with Retry and Copy
  await p.click('#failedBadge'); await wait(200);
  const listTxt = (await p.textContent('#failedList')).replace(/\s+/g, ' ');
  ok(await p.isVisible('#failedModal') && listTxt.includes('Not authorized') && listTxt.includes('deactivated'), 'list says "Not authorized ... deactivated"');
  ok(listTxt.includes('tag 4218') && listTxt.includes('1st Pull'), 'list names the entry (tag 4218, 1st Pull)');
  ok(!!(await p.$('[data-failed-act=retry]')) && !!(await p.$('[data-failed-act=copy]')), 'Retry and Copy buttons');
  await p.screenshot({ path: path.join(__dirname, 'out', 'failed-list.png') }).catch(async () => {
    require('fs').mkdirSync(path.join(__dirname, 'out'), { recursive: true });
    await p.screenshot({ path: path.join(__dirname, 'out', 'failed-list.png') });
  });
  await p.click('[data-failed-act=copy]'); await wait(200);
  const clip = await p.evaluate(() => navigator.clipboard.readText());
  const parsed = JSON.parse(clip);
  ok(parsed.failed.code === '42501' && JSON.stringify(parsed.entry) === JSON.stringify(ENTRY), 'Copy puts the full entry and the error on the clipboard');

  // 3. network errors keep retrying
  await setState({ upsertError: null, network: true });
  const E2 = Object.assign({}, ENTRY, { id: 1790000000002, tagNumber: '4219' });
  await p.evaluate(e => { enqueueForSync(e); }, E2);
  await wait(500);
  st = await p.evaluate(() => ({ q: syncQueue.map(x => [x.id, x._attempts]), f: failedEntries.length }));
  ok(st.q.length === 1 && st.q[0][0] === E2.id && st.q[0][1] === 1 && st.f === 1, 'network error stays queued (attempt 1), not Failed');
  await p.evaluate(() => processSyncQueue()); await wait(300);
  st = await p.evaluate(() => syncQueue.map(x => x._attempts));
  ok(st[0] === 2, 'and retries (attempt 2)');

  // 4. 23xxx and 22xxx are permanent too
  await setState({ network: false, upsertError: { code: '23514', message: 'new row for relation "pending_field_entries" violates check constraint "pending_field_entries_tag_number_format_check"' } });
  await p.evaluate(() => processSyncQueue()); await wait(400);
  st = await p.evaluate(() => ({ q: syncQueue.length, f: failedEntries.map(f => [f.code, f.entry && f.entry.id, f.plain]) }));
  ok(st.q === 0 && st.f.some(x => x[0] === '23514' && x[1] === E2.id && /Tag not accepted/.test(x[2])), '23514 -> Failed, "Tag not accepted"');
  await setState({ upsertError: { code: '22P02', message: 'invalid input syntax for type timestamp with time zone' } });
  const E3 = Object.assign({}, ENTRY, { id: 1790000000003, dateTime: 'not a date' });
  await p.evaluate(e => { enqueueForSync(e); }, E3); await wait(400);
  st = await p.evaluate(() => failedEntries.find(f => f.code === '22P02'));
  ok(st && /Bad data/.test(st.plain), '22P02 -> Failed, "Bad data"');

  // 5. survives a reload; not on either reset list
  await p.reload(); await wait(1500);
  st = await p.evaluate(() => ({ n: failedEntries.length, badge: document.getElementById('failedBadge').textContent,
    inReset: RESET_KEYS.includes('betaCattleFailed') }));
  const inline = await p.evaluate(() => Array.from(document.scripts).map(s => s.textContent).join('\n'));
  ok(st.n === 3 && st.badge.includes('3 failed'), 'after reload: 3 failed, badge "3 failed"');
  ok(!st.inReset && !/'betaCattleFailed'/.test(inline.split('function hardReset')[1] || ''), 'Failed list is on neither reset list');

  // 6. Retry while still refused: back to Failed, nothing lost
  await setState({ upsertError: PERM, network: false });
  let key = await p.evaluate(id => failedEntries.find(f => f.entry && f.entry.id === id).key, ENTRY.id);
  await p.evaluate(k => retryFailed(k), key); await wait(500);
  st = await p.evaluate(id => ({ q: syncQueue.length, hits: failedEntries.filter(f => f.entry && f.entry.id === id) }), ENTRY.id);
  ok(st.q === 0 && st.hits.length === 1 && JSON.stringify(st.hits[0].entry) === JSON.stringify(ENTRY), 'Retry still refused: back in Failed, entry intact');

  // 7. the office reactivates the account; Retry delivers the original entry
  await setState({ upsertError: null });
  key = await p.evaluate(id => failedEntries.find(f => f.entry && f.entry.id === id).key, ENTRY.id);
  await p.evaluate(k => retryFailed(k), key); await wait(500);
  st = await p.evaluate(id => ({ sent: window.__sent.filter(s => s.table === 'pending_field_entries' && s.row && s.row.client_id === String(id)),
    left: failedEntries.filter(f => f.entry && f.entry.id === id).length }), ENTRY.id);
  ok(st.sent.length === 1 && JSON.stringify(st.sent[0].row.raw) === JSON.stringify(ENTRY) && st.sent[0].row.tag_number === '4218',
     'after reactivation Retry sends the original entry verbatim');
  ok(st.left === 0, 'and it leaves the Failed list only once delivered');

  // 8. Mark handled keeps it stored
  await p.evaluate(() => { window.confirm = () => true; });
  key = await p.evaluate(() => failedEntries.find(f => f.code === '22P02').key);
  await p.evaluate(k => markFailedHandled(k), key);
  st = await p.evaluate(() => ({ n: failedEntries.length, stored: JSON.parse(localStorage.getItem('betaCattleFailed')).length,
    badge: document.getElementById('failedBadge').textContent }));
  ok(st.n === 2 && st.stored === 2 && st.badge.includes('1 failed'), 'Mark handled: off the badge (1 failed), still stored (2)');

  ok(!errs.length, 'no page errors ' + errs.join(' / '));
  await b.close();
})();
