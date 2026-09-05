// =========================================================
// JFR Feed — load planner (D6) and the largest-remainder split (D10)
// =========================================================
// Pure functions, no DOM, no Supabase. Loaded as a plain script by the
// feed app and require()-able from node for the tests in
// feed-app/planner.test.js. Keep it that way: the planner is the one
// piece of this app that is easier to get wrong than to write.
//
// planLoads({ calls, cap, minSplit })
//   calls    [{ pasture_id, label, lb, one_pass, route_order }], lb > 0,
//            in the order the truck will drive them.
//   cap      max pounds a load may carry (ration max, truck capacity,
//            whichever is smaller), or null for "one load takes it all".
//   minSplit the smallest remainder the planner may leave for the next
//            load (D6). A remainder under this goes whole one way or the
//            other rather than as a 40 lb dribble.
// returns    [{ drops: [{ pasture_id, label, lb, split }], lb, over_cap }]
//
// Balanced loads (John's call, D6): loads needed = ceil(total / cap),
// each sized at total / that count, so three loads of 12,000 rather than
// 15,000, 15,000 and 6,000. Then walk the route: a pasture that fits goes
// in whole; a split-OK pasture that does not fit gets the remainder that
// fits now and the rest opens the next load; a one-pass pasture that does
// not fit closes this load early and starts the next. The cap is the hard
// ceiling; the balanced size is the target. A one-pass pasture bigger than
// the cap still goes as one load, flagged over_cap - refusing it does not
// feed the cattle.
(function (root) {
    'use strict';

    function round1(n) { return Math.round(n * 10) / 10; }

    function planLoads(opts) {
        // Everything in tenths of a pound, and the balanced size a whole
        // pound, so pieces and remainders add back to the call exactly.
        const calls = (opts.calls || []).filter(c => (Number(c.lb) || 0) > 0)
            .map(c => Object.assign({}, c, { lb: round1(Number(c.lb)) }));
        const cap = Number(opts.cap) > 0 ? Number(opts.cap) : null;
        const minSplit = Math.max(0, Number(opts.minSplit) || 0);
        if (!calls.length) return [];

        const total = calls.reduce((s, c) => s + Number(c.lb), 0);
        if (!cap || total <= cap) {
            return [{ drops: calls.map(c => ({ pasture_id: c.pasture_id, label: c.label, lb: round1(Number(c.lb)), split: false })),
                      lb: round1(total), over_cap: false }];
        }

        const n = Math.ceil(total / cap);
        const size = Math.ceil(total / n);   // the balanced target
        const loads = [];
        let cur = { drops: [], lb: 0, over_cap: false };
        const close = () => { if (cur.drops.length) { cur.lb = round1(cur.lb); loads.push(cur); } cur = { drops: [], lb: 0, over_cap: false }; };
        // split = this piece is less than the pasture's whole call, i.e. the
        // pasture is spread over more than one load.
        const put = (c, lb) => {
            cur.drops.push({ pasture_id: c.pasture_id, label: c.label, lb: round1(lb), split: lb < Number(c.lb) - 0.01 });
            cur.lb = round1(cur.lb + lb);
            if (cur.lb > cap + 0.5) cur.over_cap = true;
        };

        for (const c of calls) {
            let remaining = Number(c.lb);
            let guard = 0;
            while (remaining > 0 && guard++ < 50) {
                // Room against the balanced size, but never past the cap.
                const room = round1(Math.max(0, Math.min(size, cap) - cur.lb));
                if (remaining <= room + 0.5) { put(c, remaining); remaining = 0; break; }

                if (c.one_pass) {
                    // Never split. Whole into an empty load (even if it is
                    // over the cap - flagged), otherwise close and retry.
                    if (!cur.drops.length) { put(c, remaining); remaining = 0; break; }
                    close(); continue;
                }

                const take = room;
                const rest = round1(remaining - take);
                // Do not leave a dribble either side of the cut.
                if (take < minSplit || rest < minSplit) {
                    if (!cur.drops.length) {
                        // An empty load and still no clean cut: take what
                        // fits under the cap in one piece and carry on.
                        const t = Math.min(remaining, cap);
                        put(c, t);
                        remaining = round1(remaining - t);
                        if (remaining > 0) close();
                        continue;
                    }
                    close(); continue;
                }
                put(c, take);
                remaining = rest;
                close();
            }
        }
        close();
        return loads;
    }

    // Largest-remainder split of total over weights to `scale` decimals,
    // parts sum EXACTLY. Mirrors lr_split() in the database.
    function lrSplit(total, weights, scale) {
        const n = weights.length;
        if (!n) return [];
        const unit = Math.pow(10, -(scale == null ? 2 : scale));
        const wsum = weights.reduce((s, w) => s + (Number(w) || 0), 0);
        const toUnits = x => Math.round(x / unit);
        const totalU = toUnits(total);
        if (wsum <= 0) { const p = new Array(n).fill(0); p[0] = total; return p; }
        const exact = weights.map(w => totalU * (Number(w) || 0) / wsum);
        const floors = exact.map(Math.floor);
        let remain = totalU - floors.reduce((s, f) => s + f, 0);
        const order = exact.map((e, i) => ({ i, f: e - floors[i] })).sort((a, b) => b.f - a.f || a.i - b.i);
        for (let k = 0; k < order.length && remain > 0; k++, remain--) floors[order[k].i] += 1;
        return floors.map(u => u * unit);
    }

    const api = { planLoads, lrSplit };
    if (typeof module !== 'undefined' && module.exports) module.exports = api;
    root.FeedPlanner = api;
})(typeof window !== 'undefined' ? window : globalThis);
