// node feed-app/planner.test.js
const { planLoads, lrSplit } = require('./planner.js');
const assert = require('assert');
let n = 0;
function t(name, fn) { fn(); n++; console.log('ok', name); }
const sum = a => a.reduce((s, x) => s + x, 0);
const loadSum = l => sum(l.drops.map(d => d.lb));

t('single load when under cap', () => {
    const p = planLoads({ calls: [{ pasture_id: 'a', lb: 6000 }, { pasture_id: 'b', lb: 4000 }], cap: 15000, minSplit: 500 });
    assert.strictEqual(p.length, 1); assert.strictEqual(p[0].lb, 10000);
});
t('balanced: 36,000 over cap 15,000 -> three loads of 12,000, not 15/15/6', () => {
    const calls = [6000, 5000, 7000, 4000, 8000, 6000].map((lb, i) => ({ pasture_id: 'p' + i, lb }));
    const p = planLoads({ calls, cap: 15000, minSplit: 500 });
    assert.strictEqual(p.length, 3);
    p.forEach(l => assert(l.lb <= 15000 && l.lb >= 9000, 'load ' + l.lb));
    assert.strictEqual(sum(p.map(loadSum)), 36000);
    assert(p.every(l => !l.over_cap));
});
t('split-ok pasture is cut across two loads and the pieces sum', () => {
    const p = planLoads({ calls: [{ pasture_id: 'a', lb: 7000 }, { pasture_id: 'b', lb: 11000 }], cap: 12000, minSplit: 500 });
    assert.strictEqual(p.length, 2);
    const b = p.flatMap(l => l.drops).filter(d => d.pasture_id === 'b');
    assert.strictEqual(b.length, 2);
    assert.strictEqual(sum(b.map(d => d.lb)), 11000);
    assert(b.every(d => d.split));
    assert.deepStrictEqual(p.map(l => l.lb), [9000, 9000]);
});
t('one-pass pasture is never split; closes the load early', () => {
    const p = planLoads({ calls: [{ pasture_id: 'a', lb: 7000 }, { pasture_id: 'b', lb: 11000, one_pass: true }], cap: 12000, minSplit: 500 });
    const b = p.flatMap(l => l.drops).filter(d => d.pasture_id === 'b');
    assert.strictEqual(b.length, 1); assert.strictEqual(b[0].lb, 11000); assert(!b[0].split);
    assert.strictEqual(p.length, 2);
});
t('one-pass pasture over the cap goes whole, flagged', () => {
    const p = planLoads({ calls: [{ pasture_id: 'a', lb: 17000, one_pass: true }, { pasture_id: 'b', lb: 3000 }], cap: 15000, minSplit: 500 });
    const big = p.find(l => l.drops.some(d => d.pasture_id === 'a'));
    assert(big.over_cap); assert.strictEqual(big.drops.length, 1);
    assert.strictEqual(sum(p.map(loadSum)), 20000);
});
t('no dribble under minSplit', () => {
    const p = planLoads({ calls: [{ pasture_id: 'a', lb: 11800 }, { pasture_id: 'b', lb: 400 }, { pasture_id: 'c', lb: 11800 }], cap: 12000, minSplit: 500 });
    p.flatMap(l => l.drops).forEach(d => assert(d.lb >= 400, 'dribble ' + d.lb));
    assert.strictEqual(sum(p.map(loadSum)), 24000);
});
t('every plan conserves pounds and respects the cap unless one-pass', () => {
    let seed = 7; const rnd = () => (seed = (seed * 9301 + 49297) % 233280) / 233280;
    for (let k = 0; k < 300; k++) {
        const calls = Array.from({ length: 1 + Math.floor(rnd() * 9) }, (_, i) => ({ pasture_id: 'p' + i, lb: Math.round(500 + rnd() * 9000), one_pass: rnd() < 0.3 }));
        const cap = 8000 + Math.round(rnd() * 8000);
        const p = planLoads({ calls, cap, minSplit: 500 });
        assert(Math.abs(sum(p.map(loadSum)) - sum(calls.map(c => c.lb))) < 0.01, 'pounds lost');
        p.forEach(l => { if (!l.over_cap) assert(l.lb <= cap + 0.5, 'over cap'); });
        p.forEach(l => l.drops.forEach(d => { const c = calls.find(x => x.pasture_id === d.pasture_id); if (c.one_pass) assert(!d.split); }));
        calls.forEach(c => { const parts = p.flatMap(l => l.drops).filter(d => d.pasture_id === c.pasture_id); assert(Math.abs(sum(parts.map(d => d.lb)) - c.lb) < 0.01); });
    }
});
t('a small pasture rides along after a one-pass pasture instead of its own trip', () => {
    const p = planLoads({ calls: [{ pasture_id: 'a', lb: 916 }, { pasture_id: 'b', lb: 4770, one_pass: true }, { pasture_id: 'c', lb: 600 }], cap: 6000, minSplit: 500 });
    assert.strictEqual(p.length, 2);
    assert.deepStrictEqual(p[1].drops.map(d => d.pasture_id), ['b', 'c']);
    assert.strictEqual(p[1].lb, 5370);
});
t('lrSplit sums exactly and matches the DB rule', () => {
    assert.deepStrictEqual(lrSplit(100, [3, 3, 3]), [33.34, 33.33, 33.33]);
    assert.deepStrictEqual(lrSplit(4000, [20, 30]), [1600, 2400]);
    assert.deepStrictEqual(lrSplit(5, [0, 0]), [5, 0]);
    const parts = lrSplit(7010, [7600, 2400]);
    assert.strictEqual(Math.round(sum(parts) * 100) / 100, 7010);
});
console.log(n + ' planner tests passed');
