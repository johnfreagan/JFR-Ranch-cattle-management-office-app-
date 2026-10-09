#!/usr/bin/env node
// Field app v26: a tag's last pasture is reused only while its lot still
// stands there (2026-10-09). Drives the real field-app/index.html in Chromium
// with the books seeded into localStorage (the 8 Oct shape: 36-27 in six
// pastures, none of them Corner 4/7/8) and Supabase cut off.
//   NODE_PATH=<dir with playwright> node scripts/field-pasture-recall-harness/run.js
const path = require('path');
const http = require('http');
const fs = require('fs');
const { chromium } = require('playwright');
const ROOT = path.join(__dirname, '../../field-app');

const AUTH_KEY = 'sb-xpfmebdzcxorvwikfvtj-auth-token';   // supabase-js storage key for SUPABASE_URL in app.js
const LOT36 = '36-27', LOT32 = '32-27', LOT99 = '99-27';
const pastureLots = {
    'Shop - Shop House': [{ lot: LOT36, head: 149 }],
    'Garrett - Goat Hill': [{ lot: LOT36, head: 230 }],
    'Terrell - Shelton': [{ lot: LOT36, head: 299 }],
    '413 - Trap': [{ lot: LOT36, head: 13 }],
    'Corner - H2': [{ lot: LOT36, head: 7 }],
    'Corner - H3': [{ lot: LOT36, head: 2 }],
    'Corner - 1': [{ lot: LOT32, head: 84 }],
    'Corner - 2': [{ lot: LOT32, head: 80 }],
    'Corner - 3': [{ lot: LOT32, head: 42 }],
    'Corner - H1': [{ lot: LOT99, head: 5 }]
};
const locs = Object.keys(pastureLots).concat(['Corner - 4', 'Corner - 7', 'Corner - 8'])
    .map(l => ({ property: l.split(' - ')[0], pasture: l.split(' - ')[1] }));
const book = (tag, lot, loc) => ({ id: 'B' + tag, type: 'doctoring', tagNumber: tag, lotNumber: lot,
    location: loc, treatmentType: 'Other', dateTime: '2026-09-20T09:00:00', _status: 'approved' });
const seed = {
    betaCattleLocs: locs,
    betaCattleLots: [LOT36, LOT32, LOT99].map(n => ({ lotNumber: n, avgWeight: 300, targetADG: 1.5 })),
    betaCattleMeds: [{ name: 'Draxxin', dose: '1.1/100' }],
    betaCattleProtocols: [{ actionName: 'First Pull EX', med1: 'Draxxin', med2: '', med3: '' }],
    betaCattlePastureLots: pastureLots,
    betaCattleTagLots: { '8569': LOT36, '22': LOT32, '555': LOT99, '777': LOT36, '901': LOT36 },
    betaCattleBooksHistory: [book('8569', LOT36, 'Corner - 4'), book('22', LOT32, 'Corner - 1'),
                             book('555', LOT99, 'Corner - 4'), book('901', LOT36, 'Corner - 7')],
    betaCattleMoves: [{ type: 'move', id: 'M-1', date: '2026-10-09', fromRanch: 'Shop', fromPasture: 'Shop House',
                        toRanch: 'Corner', toPasture: '7', lotNumber: LOT36, lotSplit: [{ lot: LOT36, head: 20 }],
                        headCount: '20' }],   // this phone's move, not yet approved
    crewMemberName: 'test',
    [AUTH_KEY]: (() => {
        const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
        const exp = Math.floor(Date.now() / 1000) + 3600;
        return { access_token: `${b64({ alg: 'HS256' })}.${b64({ sub: 'u-test', exp, role: 'authenticated' })}.x`,
                 token_type: 'bearer', expires_in: 3600, expires_at: exp, refresh_token: 'r-test',
                 user: { id: 'u-test', aud: 'authenticated', role: 'authenticated', email: 'test@example.invalid' } };
    })(),
    betaLastSyncDate: new Date().toISOString()
};

const server = http.createServer((req, res) => {
    const f = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]).replace(/^\/$/, '/index.html'));
    if (!f.startsWith(ROOT) || !fs.existsSync(f)) { res.writeHead(404); return res.end(); }
    const ext = path.extname(f);
    res.writeHead(200, { 'Content-Type': ext === '.js' ? 'text/javascript' : ext === '.css' ? 'text/css' : 'text/html' });
    fs.createReadStream(f).pipe(res);
});

(async () => {
    await new Promise(r => server.listen(0, r));
    const url = `http://127.0.0.1:${server.address().port}/`;
    const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium' });
    const ctx = await browser.newContext({ serviceWorkers: 'block' });
    // Signed in, as a crew phone in the field is: a stored session, and the
    // one call the sign-in gate makes (user_profiles) answered. Everything
    // else to Supabase is cut off. Without a session the app's bootstrap
    // shows #loginScreen when getSession() resolves, which raced the old
    // forced hide below and covered the pickLotPlace chips on some runs.
    await ctx.route(/supabase\.co/, r => /\/rest\/v1\/user_profiles/.test(r.request().url())
        ? r.fulfill({ status: 200, contentType: 'application/json',
                      body: JSON.stringify({ full_name: 'test', role: 'crew', is_active: true }) })
        : r.abort());
    await ctx.addInitScript(s => {
        if (sessionStorage.getItem('seeded')) return;
        Object.keys(s).forEach(k => localStorage.setItem(k, typeof s[k] === 'string' ? s[k] : JSON.stringify(s[k])));
        sessionStorage.setItem('seeded', '1');
    }, seed);
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    const dialogs = [];
    let answer = [];
    page.on('dialog', d => { dialogs.push(d.message()); d.type() === 'confirm' ? (answer.shift() ? d.accept() : d.dismiss()) : d.accept(); });
    await page.goto(url);
    // Wait for the app's own sign-in to finish rather than hiding the gate.
    await page.waitForFunction(() => currentUserId === 'u-test' &&
        getComputedStyle(document.getElementById('loginScreen')).display === 'none');

    let fails = 0;
    const t = (name, ok, extra) => { console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${ok || !extra ? '' : ' -- ' + extra}`); if (!ok) fails++; };
    const state = () => page.evaluate(() => ({
        ranch: propertyInput.value, past: pastureInput.value, lot: lotInput.value,
        alert: document.getElementById('tagAlert').innerText,
        chips: [...document.querySelectorAll('.loc-chip')].map(b => b.innerText)
    }));
    const typeTag = async v => {
        await page.evaluate(v => { tagNumberInput.value = v; tagNumberInput.dispatchEvent(new Event('input')); }, v);
        return state();
    };
    const reset = () => page.evaluate(() => {
        tagNumberInput.value = ''; tagNumberInput.dispatchEvent(new Event('input'));
        propertyInput.value = ''; pastureInput.innerHTML = '<option value=""></option>'; pastureInput.value = '';
        autoFilledLocation = '';
    });

    // A. The 8 Oct case: last entry says Corner 4, the lot has left it.
    let s = await typeTag('8569');
    t('A stale recall not filled', s.past === '' && s.lot === LOT36, JSON.stringify(s));
    t('A says last entered on Corner - 4', /Last entered on Corner - 4/.test(s.alert), s.alert);
    t('A offers lot pastures + this phone\'s move, most head first',
      s.chips.length === 7 && /Terrell - Shelton/.test(s.chips[0]) && /Corner - 7/.test(s.chips[6]), JSON.stringify(s.chips));
    await page.click('.loc-chip >> text=Shop - Shop House');
    s = await state();
    t('A one tap sets ranch + pasture', s.ranch === 'Shop' && s.past === 'Shop House', JSON.stringify(s));
    t('A no warning after pick', !/is not in/.test(s.alert) && s.chips.length === 0, s.alert);

    // B. Recall still good: 32-27 is still in Corner 1.
    await reset();
    s = await typeTag('22');
    t('B good recall kept', s.ranch === 'Corner' && s.past === '1', JSON.stringify(s));

    // D. Next tag's answer is "pick": the auto-filled Corner 1 must not ride along.
    s = await typeTag('8569');
    t('D auto-filled pasture cleared for next tag', s.past === '', JSON.stringify(s));

    // C. Lot stands in exactly one place: fill it even though the recall is stale.
    await reset();
    s = await typeTag('555');
    t('C single place auto-filled', s.ranch === 'Corner' && s.past === 'H1', JSON.stringify(s));

    // G. This phone moved 36-27 into Corner 7 (not approved yet): recall there is good.
    await reset();
    s = await typeTag('901');
    t('G pending local move counts', s.ranch === 'Corner' && s.past === '7', JSON.stringify(s));

    // E. Cowboy picks a pasture himself first: never cleared, warned in red.
    await reset();
    await page.evaluate(() => { propertyInput.value = 'Corner'; propertyInput.onchange.call(propertyInput);
                                pastureInput.value = '8'; pastureInput.onchange(); });
    s = await typeTag('777');
    t('E hand-picked pasture kept', s.ranch === 'Corner' && s.past === '8', JSON.stringify(s));
    t('E red warning with picks', /Lot 36-27 is not in Corner - 8/.test(s.alert) && s.chips.length === 7, s.alert);

    // F. Submit on the wrong pasture: own question, Cancel = fix.
    await page.evaluate(() => { treatmentTypeInput.value = 'Other'; treatmentTypeInput.dispatchEvent(new Event('change'));
                                document.getElementById('notes').value = 'test'; });
    const before = await page.evaluate(() => records.length);
    dialogs.length = 0; answer = [false];
    await page.evaluate(() => doctoringForm.requestSubmit());
    let after = await page.evaluate(() => records.length);
    t('F cancel on mismatch does not save', after === before && /NOT in Corner - 8/.test(dialogs[0] || ''), JSON.stringify(dialogs));
    t('F pasture marked to fix', await page.evaluate(() => pastureInput.classList.contains('field-missing')));
    dialogs.length = 0; answer = [true, true];
    await page.evaluate(() => doctoringForm.requestSubmit());
    const saved = await page.evaluate(() => records[0]);
    t('F OK + Save saves with pastureOffBooks', saved && saved.tagNumber === '777' && saved.pastureOffBooks === true &&
      saved.location === 'Corner - 8' && dialogs.length === 2, JSON.stringify({ saved, dialogs }));

    // H. A right pasture asks only the ordinary Save question, and no flag.
    await page.waitForFunction(() => !isSubmittingDoctoring);   // the app's double-tap cooldown
    await reset();
    await typeTag('22');
    await page.evaluate(() => { treatmentTypeInput.value = 'Other'; treatmentTypeInput.dispatchEvent(new Event('change'));
                                document.getElementById('notes').value = 'test'; });
    dialogs.length = 0; answer = [true];
    await page.evaluate(() => doctoringForm.requestSubmit());
    const saved2 = await page.evaluate(() => records[0]);
    t('H right pasture: one confirm, no flag', saved2.tagNumber === '22' && !saved2.pastureOffBooks && dialogs.length === 1,
      JSON.stringify({ saved2, dialogs }));

    // I. Never synced: no pasture data, nothing checked, nothing blocked.
    t('I no data means no check', await page.evaluate(() => { const k = pastureLotsMap; pastureLotsMap = {};
        const r = lotStandsIn('36-27', 'Corner - 8'); pastureLotsMap = k; return r === null; }));

    t('no page errors', errors.length === 0, errors.join(' | '));
    await browser.close(); server.close();
    console.log(fails ? `${fails} FAILED` : 'ALL PASS');
    process.exit(fails ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
