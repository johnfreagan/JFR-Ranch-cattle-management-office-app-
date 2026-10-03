const { chromium } = require('playwright');
const path = require('path');
// Office task-card tap test: the real index.html in headless Chromium, signed
// in as OFFICE, against fake.js (an in-memory stand-in for Supabase seeded by
// fixtures.js: one ranch, two pastures, lot 2627-A, a feed pen, one field
// entry, one PB day, one Bar J invoice). No network at all; nothing reaches the
// live database. Each run() walks one card from app open to "saved", counting
// taps and fields, and prints the database calls the save made and the
// message shown. Three batches (they share one Chromium):
//   NODE_PATH=$(npm root -g) node scripts/office-tap-harness/walk.js            # A1-A5, B1-B3, C1, C3, C4, D1, D2, D5
//   BATCH=B NODE_PATH=$(npm root -g) node scripts/office-tap-harness/walk.js    # B4, C2, C5, C6, D3, E1, E3, F1
//   BATCH=C NODE_PATH=$(npm root -g) node scripts/office-tap-harness/walk.js    # D4, D6, E2, E4, E5
// Known stand-in artifacts: B1 ends "Failed to load lot: no rows" (the new lot
// is not in lot_status), D4 says the rows do not tie (fixture totals), E5's
// adjustment count is blank (post_feed_count returns nothing here).
const APP = path.join(__dirname, '..', '..', 'index.html');
const HERE = __dirname;
const SHOTS = process.env.SHOTS || require('os').tmpdir();
const results = [];

async function fresh(browser) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  page.__errors = [];
  page.on('pageerror', e => page.__errors.push(e.message));
  page.on('dialog', d => { page.__dialogs = (page.__dialogs || []).concat(d.message().slice(0, 120)); d.accept(page.__promptAnswer || undefined); });
  await page.route('**/*', r => {
    const u = r.request().url();
    if (u.startsWith('file://')) return r.continue();
    if (u.includes('supabase')) return r.fulfill({ body: '', contentType: 'text/javascript' });
    return r.abort();
  });
  await page.addInitScript({ path: path.join(HERE, 'fixtures.js') });
  await page.addInitScript({ path: path.join(HERE, 'fake.js') });
  await page.goto('file://' + APP);
  await page.waitForTimeout(800);
  return page;
}

function counter(page) {
  const c = { taps: 0, fields: 0, log: [] };
  c.tap = async (loc, label) => { await loc.first().click({ timeout: 5000 }); c.taps++; c.log.push('tap ' + label); await page.waitForTimeout(250); };
  c.type = async (sel, val, label) => { await page.fill(sel, String(val), { timeout: 5000 }); c.fields++; c.log.push('type ' + label); };
  c.pick = async (sel, val, label) => { await page.selectOption(sel, val, { timeout: 5000 }); c.fields++; c.log.push('pick ' + label); };
  return c;
}
const btn = (page, name) => page.getByRole('button', { name, exact: true });
async function calls(page) { return page.evaluate(() => window.__calls.filter(c => c.kind === 'rpc' || c.op !== 'select').map(c => c.kind === 'rpc' ? 'rpc ' + c.fn : c.op + ' ' + c.table)); }
async function alertText(page) { return (await page.textContent('#globalAlert').catch(() => '') || '').trim().slice(0, 140); }
async function pickPasture(page, c, scope, ranch, pasture) {
  const inp = page.locator(scope + ' .past-picker-input, ' + scope + ' .pasture-picker-input').first();
  await inp.click({ timeout: 5000 }); c.taps++;
  await inp.fill(pasture); c.fields++;
  await page.waitForTimeout(200);
  await page.locator(scope + ' .past-dropdown .pasture-picker-item, ' + scope + ' .pasture-picker-item').first().click({ timeout: 5000 }); c.taps++;
  c.log.push('pick pasture ' + pasture);
}

async function run(name, fn, browser) {
  const page = await fresh(browser);
  const c = counter(page);
  let note = '';
  try { note = await fn(page, c) || ''; } catch (e) { note = 'FAILED: ' + e.message.split('\n')[0]; }
  const writes = await calls(page);
  results.push({ name, taps: c.taps, fields: c.fields, writes, alert: await alertText(page), errors: page.__errors.slice(0, 2), dialogs: page.__dialogs || [], note, log: c.log });
  await page.screenshot({ path: path.join(SHOTS, 'shot-' + name.split(' ')[0] + '.png') });
  await page.close();
  const r = results[results.length - 1];
  console.log(`\n== ${r.name}: ${r.taps} taps, ${r.fields} fields ${r.note ? '— ' + r.note : ''}`);
  console.log('   writes:', r.writes.filter(x => !/current_user_role|weight_detail/.test(x)).join(', ') || '(none)');
  console.log('   alert:', r.alert || '(none)');
  if (r.dialogs.length) console.log('   dialogs:', r.dialogs.join(' | '));
  if (r.errors.length) console.log('   errors:', r.errors.join(' | '));
}

(async () => {
  const browser = await chromium.launch({ ...(process.env.CHROME ? { executablePath: process.env.CHROME } : {}), args: ['--no-sandbox'] });

  if (!process.env.BATCH) {
  await run('A1 Approve field entries', async (p, c) => {
    await c.tap(p.locator('#navApprovals'), 'Approvals');
    await p.waitForTimeout(600);
    const sa = p.getByRole('button', { name: 'Select all' });
    if (await sa.count()) await c.tap(sa, 'Select all'); else { await c.tap(p.locator('.appr-check'), 'tick row'); }
    await c.tap(p.locator('#approvalsApproveBtn'), 'Approve selected');
    await p.waitForTimeout(600);
    return 'ready rows: ' + await p.locator('.appr-check').count();
  }, browser);

  await run('A2 Send back', async (p, c) => {
    p.__promptAnswer = 'Wrong tag, redo it';
    await c.tap(p.locator('#navApprovals'), 'Approvals');
    await p.waitForTimeout(600);
    await c.tap(p.locator('.appr-reject'), '✖ Send back'); c.fields++;
    await p.waitForTimeout(400);
  }, browser);

  await run('A2b Fix with pencil', async (p, c) => {
    await c.tap(p.locator('#navApprovals'), 'Approvals');
    await p.waitForTimeout(600);
    await c.tap(p.locator('.appr-edit'), '✎');
    await p.waitForTimeout(300);
    await c.tap(p.locator('#apprEditSaveBtn'), 'Save correction');
    await p.waitForTimeout(400);
  }, browser);

  await run('A3 Approve PB day', async (p, c) => {
    await c.tap(p.locator('#navApprovals'), 'Approvals');
    await c.tap(p.locator('[data-appr-pane="feed"]'), 'Feed');
    await p.waitForTimeout(500);
    await c.tap(p.locator('[data-pb="approve"]'), 'Approve & post');
    await p.waitForTimeout(400);
  }, browser);

  await run('A4 Move a PB pen', async (p, c) => {
    await c.tap(p.locator('#navApprovals'), 'Approvals');
    await c.tap(p.locator('[data-appr-pane="feed"]'), 'Feed');
    await p.waitForTimeout(500);
    await c.tap(p.locator('[data-pb="move"]'), 'Move');
    await p.selectOption('.pb-pas', { index: 2 }); c.fields++;
    await c.tap(p.locator('[data-pb="move-save"]'), 'Move (save)');
    await p.waitForTimeout(400);
  }, browser);

  await run('A5 Post Bar J invoice', async (p, c) => {
    await c.tap(p.locator('#navApprovals'), 'Approvals');
    await c.tap(p.locator('[data-appr-pane="meds"]'), 'Meds');
    await p.waitForTimeout(500);
    await c.tap(p.getByRole('button', { name: 'Review & post' }), 'Review & post');
    await p.waitForTimeout(600);
    await c.pick('#invPurLocation', 'loc-ranch', 'Received to');
    await c.tap(p.locator('#invPurSaveBtn'), 'Post purchase');
    await p.waitForTimeout(600);
  }, browser);

  }
  if (process.env.BATCH === 'B') {
  await run('B4 Receiving sheet', async (p, c) => {
    await c.tap(p.locator('#userMenuBtn'), 'name menu');
    await c.tap(p.locator('#navSettings'), 'Settings');
    await p.waitForTimeout(500);
    await c.tap(p.getByText('Receiving', { exact: false }).locator('xpath=ancestor-or-self::tr').first(), 'protocol row');
    await c.tap(p.locator('#printReceivingSheetBtn'), '🖨 Receiving Sheet');
    await c.type('#receivingSheetWeight', 450, 'Average weight');
    return 'print button present: ' + await p.locator('#receivingSheetPrintBtn').isVisible();
  }, browser);

  await run('C2 Single doctoring', async (p, c) => {
    await c.tap(p.locator('#navAnimalHealth'), 'Health');
    await c.tap(p.locator('[data-subtab="doctoring-single"]'), 'Single Doctoring');
    await p.fill('#docSingleTag', '101'); await p.press('#docSingleTag', 'Enter'); c.fields++;
    await p.waitForTimeout(800);
    await c.pick('#doctoringActionId', 'act-1', 'action');
    await c.tap(p.locator('#doctoringSaveBtn'), 'Save');
    await p.waitForTimeout(800);
    return 'single alert: ' + ((await p.textContent('#doctoringSingleAlert').catch(() => '')) || '').trim();
  }, browser);

  await run('C5 Send to feed pen', async (p, c) => {
    await c.tap(p.locator('tr[data-lot-id="lot-1"]'), 'lot row');
    await c.tap(p.locator('[data-lot-subtab="moves"]'), 'Moves tab');
    await c.tap(p.locator('#sendToFeedPenBtn'), '🩹 Send to feed pen');
    await p.waitForTimeout(500);
    await c.type('#ltLines input[type=number], .lt-head', 2, 'head');
    await c.tap(p.locator('#ltSaveBtn'), 'Save transfer');
    await p.waitForTimeout(500);
  }, browser);

  await run('C6 Feed pen removal', async (p, c) => {
    await c.tap(p.locator('tr[data-lot-id="pen-1"]'), 'pen row');
    await p.waitForTimeout(500);
    const penTab = await p.locator('[data-lot-subtab="feedpen"]').isVisible();
    await c.tap(p.locator('[data-lot-subtab="feedpen"]'), 'Feed pen tab');
    await c.tap(p.locator('#fpNewRemovalBtn'), '+ Record removal');
    await p.waitForTimeout(400);
    await c.type('#fprProceeds', 900, 'Proceeds');
    await c.type('#fprHead', 1, 'How many head');
    await c.tap(p.locator('#fprSaveBtn'), 'Save removal');
    await p.waitForTimeout(600);
    return 'Feed pen tab showed on open: ' + penTab;
  }, browser);

  await run('D3 Ship cattle', async (p, c) => {
    await c.tap(p.locator('#navSales'), 'Moves & Sales');
    await c.tap(p.locator('#salesSubtabs [data-subtab="shipments"]'), 'Shipments');
    await c.tap(p.locator('#newShipmentBtn'), '+ New shipment');
    await p.waitForTimeout(500);
    await c.type('#shpBuyer', 'Buyer A', 'Buyer');
    await c.type('.shp-load-head', 10, 'load head');
    await c.type('.shp-load-gross', 8000, 'gross lb');
    await c.pick('.shp-line-lot', 'lot-1', 'lot');
    await p.waitForTimeout(200);
    const past = await p.inputValue('.shp-line-pasture');
    await c.type('#shpPricePerCwt', 250, '$ per cwt');
    await c.tap(p.locator('#shipmentSaveBtn'), 'Save shipment');
    await p.waitForTimeout(800);
    return 'pasture auto-filled: ' + (past === 'pas-1');
  }, browser);

  await run('E1 Feed delivery', async (p, c) => {
    await c.tap(p.locator('#navInventory'), 'Inventory');
    await c.tap(p.locator('[data-subtab="purchases"]').first(), 'Purchases');
    await c.tap(p.locator('#invPuNewDeliveryBtn'), '+ Delivery');
    await p.waitForTimeout(500);
    await c.pick('#fdRcItem', 'it-hay', 'Item');
    await p.waitForTimeout(200);
    if (!(await p.inputValue('#fdRcLocation'))) await c.pick('#fdRcLocation', 'bay-1', 'Into');
    await c.type('#fdRcQtyLb', 50000, 'Pounds');
    await c.type('#fdRcProductCost', 1500, 'Product total $');
    await c.tap(p.locator('#fdRcSaveBtn'), 'Save delivery');
    await p.waitForTimeout(600);
  }, browser);

  await run('E3 Med checkout', async (p, c) => {
    await c.tap(p.locator('#navInventory'), 'Inventory');
    await c.tap(p.locator('#invMaterialChip [data-material="med"]'), 'Meds chip');
    await c.tap(p.locator('[data-subtab="checkouts"]'), 'Checkouts');
    await p.waitForTimeout(500);
    await p.selectOption('#invCoPerson', { index: 1 }); c.fields++;
    const medSel = p.locator('#invCoLines select').first();
    await medSel.selectOption({ index: 1 }); c.fields++;
    const qty = p.locator('#invCoLines input[type=number]').first();
    await qty.fill('1'); c.fields++;
    await c.tap(p.locator('#invCoSaveBtn'), 'Record checkout');
    await p.waitForTimeout(600);
  }, browser);

  await run('F1 Daily report', async (p, c) => {
    await c.tap(p.locator('#navReports'), 'Reports');
    await c.tap(p.locator('[data-subtab="daily-report"]'), 'Daily Report');
    await p.waitForTimeout(600);
    await c.tap(p.locator('#dfrCopyBtn'), 'Copy text');
    await p.waitForTimeout(400);
  }, browser);
  await browser.close(); return;
  }
  if (process.env.BATCH === 'C') {
  await run('D4 Redwing rows', async (p, c) => {
    await c.tap(p.locator('#navSales'), 'Moves & Sales');
    await c.tap(p.locator('#salesSubtabs [data-subtab="accounting"]'), 'Accounting Report');
    await p.waitForTimeout(700);
    await c.tap(p.locator('#acctCopyBtn'), 'Copy rows (no year yet)');
    const asked = (p.__dialogs || []).some(d => /Production Year/.test(d));
    await c.type('#acctProductionYear', 2027, 'Production Year');
    await c.tap(p.locator('#acctCopyBtn'), 'Copy rows');
    await p.waitForTimeout(400);
    return 'asked for year first: ' + asked + '; status: ' + ((await p.textContent('#acctReportContent, #acctCopyStatus, #acctAlert').catch(() => '')) || '').trim().slice(0, 80);
  }, browser);

  await run('D6 Settle counts', async (p, c) => {
    await c.tap(p.locator('#userMenuBtn'), 'name menu');
    await c.tap(p.locator('#navSettings'), 'Settings');
    await c.tap(p.locator('#settingsSubtabs [data-subtab="locations"]'), 'Locations');
    await p.waitForTimeout(500);
    await c.tap(p.locator('tr[data-ranch-id="ranch-1"]'), 'ranch row');
    await p.waitForTimeout(400);
    await c.tap(p.locator('tr[data-pasture-id="pas-1"]'), 'pasture row');
    await p.waitForTimeout(400);
    await c.tap(p.locator('#settlePastureBtn'), 'Settle counts');
    await p.waitForTimeout(500);
    await c.type('.settle-count', 50, 'Counted');
    await c.tap(p.locator('#settlePastureSaveBtn'), 'Record the count');
    await p.waitForTimeout(500);
  }, browser);

  await run('E2 Feed out by hand', async (p, c) => {
    await c.tap(p.locator('#navInventory'), 'Inventory');
    await c.tap(p.locator('#feedSubtabs [data-subtab="usage"]'), 'Feed Out');
    await p.waitForTimeout(600);
    await c.pick('#fdUsMode', 'rows', 'mode Single rows');
    await p.waitForTimeout(300);
    if (!(await p.locator('[data-fd-us="item_id"]').count())) await c.tap(p.locator('#fdUsAddRowBtn'), '+ Row');
    await c.pick('[data-fd-us="item_id"]', 'it-hay', 'Item');
    await p.waitForTimeout(200);
    const from = await p.inputValue('[data-fd-us="from_location_id"]');
    if (!from) await c.pick('[data-fd-us="from_location_id"]', 'bay-1', 'Out of');
    await c.pick('[data-fd-us="lot_id"]', 'lot-1', 'Lot');
    await c.type('[data-fd-us-qty]', 500, 'Pounds fed');
    await c.tap(p.locator('#fdUsSaveBtn'), 'Save feed-out');
    await p.waitForTimeout(600);
    return 'Out of filled from item: ' + !!from;
  }, browser);

  await run('E4 Med count', async (p, c) => {
    await c.tap(p.locator('#navInventory'), 'Inventory');
    await c.tap(p.locator('#invMaterialChip [data-material="med"]'), 'Meds chip');
    await c.tap(p.locator('#feedSubtabs [data-subtab="counts"][data-material="med"]'), 'Counts');
    await p.waitForTimeout(400);
    await c.tap(p.locator('#invNewCountBtn'), '+ New count');
    await p.waitForTimeout(600);
    await c.type('[data-field="direct_units"]', 480, 'Counted units');
    await c.tap(p.locator('#invCountPostBtn'), 'Post count');
    await p.waitForTimeout(600);
  }, browser);

  await run('E5 Feed bay count', async (p, c) => {
    await c.tap(p.locator('#navInventory'), 'Inventory');
    await c.tap(p.locator('.sub-group[data-group="settings"] .group-btn'), 'Settings ▾');
    await c.tap(p.locator('#feedSubtabs [data-subtab="counts"][data-material="feed"]'), 'Counts');
    await p.waitForTimeout(500);
    await c.tap(p.locator('#fdNewCountBtn'), '+ Count a bay');
    await p.waitForTimeout(400);
    if (!(await p.inputValue('#fdCtLocation'))) await c.pick('#fdCtLocation', 'bay-1', 'Location');
    await p.waitForTimeout(400);
    await c.type('[data-fd-ct-qty]', 19500, 'Counted lb');
    await c.tap(p.locator('#fdCtPostBtn'), 'Post count');
    await p.waitForTimeout(600);
  }, browser);
  await browser.close(); return;
  }
  if (process.env.ONLY_NEW) { await browser.close(); return; }
  await run('B1 New lot', async (p, c) => {
    await c.tap(btn(p, '+ New lot'), '+ New lot');
    await c.type('#lotNumber', 'TEST-2', 'Lot number');
    await c.type('#lotEstWeight', 520, 'Estimated purchase weight');
    await c.tap(btn(p, 'Save lot'), 'Save lot');
    await p.waitForTimeout(500);
    return 'opened on tab: ' + await p.evaluate(() => (document.querySelector('#lotDetailSubtabs .sub-tab.active') || {}).textContent);
  }, browser);

  await run('B2 Purchase invoice', async (p, c) => {
    await c.tap(p.locator('tr[data-lot-id="lot-1"]'), 'lot row');
    await c.tap(p.locator('[data-lot-subtab="purchases"]'), 'Purchases tab');
    await c.tap(p.getByText('📄 + Invoice'), '+ Invoice');
    await c.type('#invoiceDate', '2026-10-01', 'Invoice date');
    await c.type('#invHeadCount', 50, 'Head count');
    await c.type('#invTotalWeight', 25000, 'Total weight');
    await c.type('#invTotalCost', 60000, 'Total cost');
    const pre = await p.inputValue('#invProtocol');
    await c.tap(btn(p, 'Save invoice'), 'Save invoice');
    return 'protocol pre-picked: ' + (pre === 'pro-1');
  }, browser);

  await run('B3 Load out', async (p, c) => {
    await p.evaluate(() => { Object.assign(window.__rpcAnswers, { record_load_out: { receipt_id: 'rc-1', tags_registered: 50, tags_retired: 0 } }); });
    await c.tap(p.locator('tr[data-lot-id="lot-1"]'), 'lot row');
    await c.tap(p.locator('[data-lot-subtab="purchases"]'), 'Purchases tab');
    await c.tap(p.getByText('🚛 + Load Out'), '+ Load Out');
    await c.type('#receiptHead', 50, 'Head count');
    await c.type('#receiptTagStart', 201, 'Start tag');
    await c.type('#receiptTagEnd', 250, 'End tag');
    await pickPasture(p, c, '#receiptModal', 'Home Place', 'North');
    const pre = await p.inputValue('#receiptProtocol');
    await c.tap(btn(p, 'Save load out'), 'Save load out');
    await p.waitForTimeout(500);
    return 'protocol pre-picked: ' + (pre === 'pro-1');
  }, browser);

  await run('C3 Record death', async (p, c) => {
    await c.tap(p.locator('tr[data-lot-id="lot-1"]'), 'lot row');
    await c.tap(p.locator('[data-lot-subtab="health"]'), 'Animal Health tab');
    await c.tap(p.getByText('⚠ + Record deaths'), '+ Record deaths');
    await c.type('.death-row-tag', '101', 'Tag #');
    await c.tap(p.locator('#deathsSaveBtn'), 'Save');
    await p.waitForTimeout(400);
  }, browser);

  await run('C4 Write off missing', async (p, c) => {
    await c.tap(p.locator('tr[data-lot-id="lot-1"]'), 'lot row');
    await c.tap(p.locator('[data-lot-subtab="health"]'), 'Animal Health tab');
    await c.tap(p.getByText('− Write off missing'), '− Write off missing');
    await c.type('#haHead', 1, 'Head');
    await c.tap(p.locator('#haSaveBtn'), 'Save');
    await p.waitForTimeout(400);
  }, browser);

  await run('D1 Moves tab', async (p, c) => {
    await c.tap(p.locator('#navSales'), 'Moves & Sales (opens on Moves)');
    await p.waitForTimeout(500);
    await c.pick('.mv-lot', 'lot-1', 'lot');
    await p.waitForTimeout(200);
    const from = await p.inputValue('.mv-from');
    await c.type('.mv-head', 10, 'head');
    await c.pick('.mv-to', 'pas-2', 'to pasture');
    await c.tap(btn(p, 'Save moves'), 'Save moves');
    await p.waitForTimeout(400);
    return 'from pasture auto-picked: ' + (from === 'pas-1');
  }, browser);

  await run('D2 Reverse a move', async (p, c) => {
    await p.evaluate(() => { Object.assign(window.__rpcAnswers, { record_move_with_pasture: 'mv-new' }); });
    await c.tap(p.locator('tr[data-lot-id="lot-1"]'), 'lot row');
    await c.tap(p.locator('[data-lot-subtab="moves"]'), 'Moves tab');
    const hist = p.locator('#moveHistoryCard .card-header, #moveHistoryCard h2, #moveHistoryCard summary').first();
    if (await hist.count()) await c.tap(hist, 'open Move history');
    await c.tap(p.locator('.move-row-reverse'), 'Reverse');
    await p.waitForTimeout(400);
  }, browser);

  await run('C1 Bulk doctoring', async (p, c) => {
    await c.tap(p.locator('#navAnimalHealth'), 'Health');
    await c.tap(p.locator('[data-subtab="doctoring-entry"]'), 'Doctoring Entry (bulk)');
    await p.waitForTimeout(400);
    await c.pick('#docEntryAction', 'act-1', 'action');
    await p.fill('#docEntryTagInput', '101'); await p.press('#docEntryTagInput', 'Enter'); c.fields++;
    await p.waitForTimeout(300);
    await c.tap(p.locator('#docEntrySaveBtn'), 'Save batch');
    await p.waitForTimeout(400);
    return 'death action offered in list: ' + await p.evaluate(() => [...document.querySelectorAll('#docEntryAction option')].some(o => o.value === 'act-2'));
  }, browser);

  await run('D5 Head count tile', async (p, c) => {
    await c.tap(p.locator('#headTieoutTile'), 'Head count tile');
    return 'modal visible: ' + await p.locator('#headTieoutModal').isVisible();
  }, browser);

  await browser.close();
})();
