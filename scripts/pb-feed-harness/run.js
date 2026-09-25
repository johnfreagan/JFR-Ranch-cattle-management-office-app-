// Approvals > Feed harness: loads the real index.html in headless Chromium
// with the Supabase CDN swapped for fake.js (canned pb_report_list rows,
// every rpc call recorded in window.__calls). Run from anywhere:
//   NODE_PATH=$(npm root -g) node scripts/pb-feed-harness/run.js
// Needs playwright; Chromium at /opt/pw-browsers/chromium in cloud sessions.
const { chromium } = require('playwright');
const fs = require('fs');
const fake = fs.readFileSync(__dirname + '/fake.js', 'utf8');
async function page(b, role){
  const p = await b.newPage({ viewport:{ width:1000, height:1600 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('https://cdn.jsdelivr.net/**', r => {
    const u = r.request().url();
    if (u.includes('supabase-js')) return r.fulfill({ contentType:'text/javascript', body: fake.replace("role: 'owner'", `role: '${role}'`) });
    if (u.endsWith('.css')) return r.fulfill({ contentType:'text/css', body:'' });
    return r.fulfill({ contentType:'text/javascript', body:'window.flatpickr=window.flatpickr||function(){return{setDate(){},clear(){},destroy(){}}};window.Chart=window.Chart||function(){return{destroy(){},update(){}}};' });
  });
  await p.route(/^https:\/\/(?!cdn\.jsdelivr).*/, r => r.fulfill({ body:'' }));
  await p.goto('file://' + require('path').resolve(__dirname, '../../index.html'));
  await p.waitForTimeout(1200);
  return { p, errs };
}
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) process.exitCode = 1; };
(async () => {
  const b = await chromium.launch({ executablePath:'/opt/pw-browsers/chromium' }).catch(() => chromium.launch());
  const { p, errs } = await page(b, 'owner');
  ok((await p.textContent('#navApprovalsCount')).trim() === '5', 'nav badge = 3 field + 2 feed on sign-in');
  await p.click('#navApprovals'); await p.waitForTimeout(400);
  await p.click('[data-appr-pane=feed]'); await p.waitForTimeout(400);
  ok(await p.isVisible('#apprFeedPane') && !(await p.isVisible('#apprFieldPane')), 'feed pane shows, field pane hides');
  ok((await p.$$('.pb-card')).length === 3, '3 report cards');
  ok((await p.textContent('#apprFeedCount')).trim() === '2', 'feed badge 2');
  const approveBtns = await p.$$('[data-pb=approve]');
  ok(!(await approveBtns[0].isDisabled()) && await approveBtns[1].isDisabled(), 'clean day approvable, blocked day disabled');
  ok((await p.textContent('.pb-card:nth-child(2)')).replace(/\s+/g,' ').includes('Fix the 1 problem above'), 'blocked reason shown');
  ok((await p.textContent('.pb-card:nth-child(3)')).includes('PB shows targets only'), 'zero-fed note');
  ok((await p.getAttribute('.pb-card a', 'href')).includes('#all/19a1b2c3d4'), 'gmail link');
  ok((await p.textContent('#pbReadBar')).includes('Last report staged'), 'read bar');
  // split
  await p.click('[data-pb=split][data-pen="Corner - 1"]'); await p.waitForTimeout(100);
  const rows = await p.$$('.pb-split-row[data-i]');
  await rows[0].$eval('select', s => { s.value = '0'; s.dispatchEvent(new Event('change', { bubbles:true })); });
  await (await rows[0].$('.pb-lb')).fill('5,000');
  await rows[1].$eval('select', s => { s.value = '2'; s.dispatchEvent(new Event('change', { bubbles:true })); });
  await (await rows[1].$('.pb-lb')).fill('1500');
  ok(await p.isDisabled('#pbSplitSave') && (await p.textContent('#pbSplitLeft')).includes('91 lb still to place'), 'split short: save disabled, 91 left');
  await (await rows[1].$('.pb-lb')).fill('1591');
  ok(!(await p.isDisabled('#pbSplitSave')) && (await p.textContent('#pbSplitLeft')).includes('adds to 6,591'), 'split exact: save enabled');
  await p.click('#pbSplitSave'); await p.waitForTimeout(300);
  let c = (await p.evaluate(() => window.__calls)).filter(x => x.fn === 'pb_split_drop').pop();
  ok(c && JSON.stringify(c.args) === JSON.stringify({ p_report_date:'2026-09-30', p_pb_pen:'Corner - 1',
     p_parts:[{ ranch:'Corner', pasture:'1', lb:'5000' }, { ranch:'Corner', pasture:'H1', lb:'1591' }] }), 'split rpc args ' + JSON.stringify(c && c.args));
  // move
  await p.click('[data-pb=move][data-pen="Garrett Hosp"]'); await p.waitForTimeout(100);
  await p.$eval('.pb-card:nth-child(2) .pb-pas', s => { s.value = '3'; });
  await p.click('[data-pb=move-save]'); await p.waitForTimeout(300);
  c = (await p.evaluate(() => window.__calls)).filter(x => x.fn === 'pb_move_drop').pop();
  ok(c && c.args.p_ranch === 'Garrett' && c.args.p_pasture === 'Front' && c.args.p_pb_pen === 'Garrett Hosp', 'move rpc args');
  // approve with error
  await p.evaluate(() => { window.__state.approveError = 'approve_pb_report: 1 problem(s) block posting: X | Y'; });
  await p.fill('#pbNote-2026-09-30', 'looks right');
  await p.click('[data-pb=approve][data-date="2026-09-30"]'); await p.waitForTimeout(300);
  ok((await p.textContent('.pb-card:nth-child(1) .pb-err')).includes('1 problem(s) block posting: X | Y'), 'approve error shown as-is');
  c = (await p.evaluate(() => window.__calls)).filter(x => x.fn === 'approve_pb_report').pop();
  ok(c.args.p_notes === 'looks right', 'approve passes note');
  // reject: reason required
  await p.click('[data-pb=reject][data-date="2026-09-30"]'); await p.waitForTimeout(100);
  await p.click('[data-pb=reject-save]'); await p.waitForTimeout(100);
  ok((await p.textContent('.pb-card:nth-child(1)')).includes('Give a reason for rejecting'), 'reject needs reason');
  ok(!(await p.evaluate(() => window.__calls)).some(x => x.fn === 'reject_pb_report'), 'no reject rpc without reason');
  await p.fill('#pbReason', 'dup email'); await p.click('[data-pb=reject-save]'); await p.waitForTimeout(300);
  c = (await p.evaluate(() => window.__calls)).filter(x => x.fn === 'reject_pb_report').pop();
  ok(c && c.args.p_reason === 'dup email', 'reject rpc with reason');
  ok(await p.isVisible('[data-pb=unpost]'), 'owner sees Unpost');
  
  ok(!errs.length, 'no page errors (owner) ' + errs.join(' / '));
  // office
  const o = await page(b, 'office');
  await o.p.click('#navApprovals'); await o.p.waitForTimeout(400);
  await o.p.click('[data-appr-pane=feed]'); await o.p.waitForTimeout(400);
  ok((await o.p.$$('.pb-card')).length === 3 && !(await o.p.isVisible('[data-pb=unpost]')), 'office: feed visible, Unpost hidden');
  ok(!o.errs.length, 'no page errors (office) ' + o.errs.join(' / '));
  // crew
  const w = await page(b, 'crew');
  ok(!(await w.p.isVisible('#navApprovals')), 'crew: no Approvals tab');
  const crewCalls = (await w.p.evaluate(() => window.__calls)).filter(x => x.table === 'pb_daily_reports');
  ok(!crewCalls.length, 'crew: no PB count query');
  await b.close();
})();
