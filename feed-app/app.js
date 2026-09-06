// =========================================================
// JFR Feed — the feed truck app (phase 2, 2026-09-04)
// =========================================================
// Design record: docs/feed-truck-integration-scope.md. The 21 decisions
// (D1..D21) referenced below are John's.
//
// What this app does, in order, every morning:
//   Bunks   score each bunk, set lb/head (prefilled from yesterday), save.
//   Plan    balanced loads from today's calls (planner.js), pick a truck,
//           move a pasture between loads if needed, start a load.
//   Truck   load the ingredients against a countdown (Done per ingredient,
//           NO auto-advance), sit out the mix timer (hard block), then
//           drop pasture by pasture (Start / Done), close the load.
//   History last two weeks, editable until the office posts.
//
// Where the numbers come from: the scale head, through window.FeedScale
// (the Flutter shell, phase 3) or the simulated scale on this screen.
// Nobody types a weight; an override after the fact keeps the scale
// reading beside it with a reason (D12).
//
// Offline: everything the day needs is pulled once at the barn (D15);
// every tap writes locally first and syncs by upsert on a client-made
// uuid, so a resend lands once. Bunk reads are the exception - saving
// them needs signal and the screen says so.
// =========================================================

const SUPABASE_URL = 'https://xpfmebdzcxorvwikfvtj.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_LhyJ7-bxebSa7HuRTxjmBQ__73Oc-66';

if (!window.supabase || typeof window.supabase.createClient !== 'function') {
    if (window.__reportBootError) window.__reportBootError('the Supabase library did not load. Tap "Reset app", or check your connection and reload.');
    throw new Error('Supabase library not available');
}
if (!window.FeedPlanner) {
    if (window.__reportBootError) window.__reportBootError('planner.js did not load. Tap "Reset app" and reload.');
    throw new Error('planner not available');
}
const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: true, autoRefreshToken: true } });
const { planLoads, lrSplit } = window.FeedPlanner;

// ---------------------------------------------------------
// small helpers
// ---------------------------------------------------------
const $ = id => document.getElementById(id);
function esc(s) { return s == null ? '' : String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
function fmt(n, d = 0) { if (n == null || isNaN(n)) return '—'; return Number(n).toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d }); }
function round1(n) { return Math.round(n * 10) / 10; }
function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); });
}
// Today in Kosse, not on the device's clock (same trap as toISOString()).
function ranchToday() { return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Chicago', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date()); }
function shiftDays(iso, n) { const [y, m, d] = iso.split('-').map(Number); return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10); }
function fmtDate(iso) { if (!iso) return '—'; const [y, m, d] = String(iso).slice(0, 10).split('-').map(Number); return new Date(y, m - 1, d).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' }); }
function fmtTime(ts) { return ts ? new Date(ts).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: 'America/Chicago' }) : '—'; }
function mmss(sec) { sec = Math.max(0, Math.round(sec)); return Math.floor(sec / 60) + ':' + String(sec % 60).padStart(2, '0'); }
function loadJSON(key, fallback) { try { const v = localStorage.getItem(key); return v == null ? fallback : JSON.parse(v); } catch (e) { return fallback; } }
function saveJSON(key, val) { try { localStorage.setItem(key, JSON.stringify(val)); return true; } catch (e) { console.error('storage', e); toast('Storage error - not saved on this device', 'error', 4000); return false; } }
let toastTimer = null;
function toast(msg, type = '', ms = 2200) {
    const t = $('toast'); t.textContent = msg; t.className = 'toast show ' + type;
    clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.className = 'toast'; }, ms);
}
function alertBox(id, msg, kind = 'error') { const el = $(id); if (el) el.innerHTML = msg ? `<div class="alert ${kind}">${msg}</div>` : ''; }

// ---------------------------------------------------------
// state
// ---------------------------------------------------------
const S = {
    userId: null, profile: null,
    refs: loadJSON('feedAppRefs', null),          // everything pulled at the barn
    loads: loadJSON('feedAppLoads', []),          // loads this device created or edited, with lines/drops/lots
    reads: loadJSON('feedAppReads', { date: null, rows: {} }),   // today's bunk reads by pasture_id
    queue: loadJSON('feedAppQueue', []),          // [{table, row}] upserts, in order
    rejected: loadJSON('feedAppRejected', []),
    truckId: localStorage.getItem('feedAppTruckId') || null,
    sim: localStorage.getItem('feedAppSim') === '1',
    activeLoadId: localStorage.getItem('feedAppActiveLoad') || null,
    planEdits: null,        // { rationId: loads[] } overrides until a load starts or reads change
    readsDirty: false,
    tab: 'bunks',
    syncing: false
};
const LOCAL_KEYS = ['feedAppRefs', 'feedAppLoads', 'feedAppReads', 'feedAppQueue', 'feedAppRejected', 'feedAppTruckId', 'feedAppSim', 'feedAppActiveLoad', 'feedAppUserId'];
function persist() {
    saveJSON('feedAppLoads', S.loads); saveJSON('feedAppReads', S.reads); saveJSON('feedAppQueue', S.queue);
    if (S.activeLoadId) localStorage.setItem('feedAppActiveLoad', S.activeLoadId); else localStorage.removeItem('feedAppActiveLoad');
}
function purgeLocal() { LOCAL_KEYS.forEach(k => { try { localStorage.removeItem(k); } catch (e) {} }); }

const settings = () => (S.refs && S.refs.settings) || {};
const tolerancePct = () => Number(settings().feed_truck_tolerance_pct) || 10;
const minSplit = () => Number(settings().feed_truck_min_split_lb) || 0;
const R = {
    ration: id => (S.refs?.rations || []).find(r => r.id === id) || null,
    item: id => (S.refs?.items || []).find(i => i.id === id) || null,
    loc: id => (S.refs?.locations || []).find(l => l.id === id) || null,
    truck: id => (S.refs?.trucks || []).find(t => t.id === id) || null,
    pasture: id => (S.refs?.pastures || []).find(p => p.id === id) || null,
    setup: id => (S.refs?.setup || []).find(s => s.pasture_id === id) || null,
    lotName: id => (S.refs?.lotNames || {})[id] || '?',
    head: pid => (S.refs?.pastureHead || {})[pid] || []
};
function pastureLabel(id) { const p = R.pasture(id); if (!p) return '?'; return (p.ranch ? p.ranch + ' / ' : '') + p.name; }
function pastureHeadTotal(id) { return R.head(id).reduce((s, h) => s + (Number(h.head) || 0), 0); }
function currentTruck() { return R.truck(S.truckId) || (S.refs?.trucks || []).find(t => t.is_default) || (S.refs?.trucks || [])[0] || null; }

// ---------------------------------------------------------
// scale: one object every screen reads. The shell (phase 3) calls
// window.FeedScale.onWeight / onStatus; the sim feeds the same path.
// ---------------------------------------------------------
const Scale = { gross: null, stable: false, connected: false, deviceId: null, deviceName: null, lastTs: 0, source: 'none' };
window.FeedScale = {
    onWeight(p) {
        if (S.sim) return;   // the sim owns the number while it is on
        const lb = Number(p && (p.lb != null ? p.lb : p.weight));
        if (isNaN(lb)) return;
        Scale.gross = lb; Scale.stable = !!(p && p.stable); Scale.lastTs = Date.now(); Scale.source = 'bridge';
        if (p && p.deviceId) Scale.deviceId = p.deviceId;
        Scale.connected = true;
    },
    onStatus(p) {
        if (!p) return;
        Scale.connected = !!p.connected;
        if (p.deviceId) Scale.deviceId = p.deviceId;
        if (p.name) Scale.deviceName = p.name;
        if (!p.connected) Scale.stable = false;
        renderChips();
    }
};
function shellSend(cmd, args) {
    const msg = JSON.stringify(Object.assign({ cmd }, args || {}));
    try {
        if (window.FeedShell && typeof window.FeedShell.postMessage === 'function') { window.FeedShell.postMessage(msg); return true; }
    } catch (e) { console.warn('shell send failed', e); }
    return false;
}
const hasShell = () => !!(window.FeedShell && typeof window.FeedShell.postMessage === 'function');
function scaleLive() { return S.sim || (Scale.lastTs > 0 && Date.now() - Scale.lastTs < 5000); }
function scaleGross() { return scaleLive() && Scale.gross != null ? Number(Scale.gross) : null; }

// Simulated scale (D19): a slider standing in for the head so every screen
// can be worked end to end on any iPad in Safari before a truck is involved.
const Sim = { gross: 0, auto: 0, timer: null };
function simSet(lb) { Sim.gross = Math.max(0, Math.min(30000, Math.round(lb))); $('simSlider').value = Sim.gross; }
function simTick() {
    if (!S.sim) return;
    if (Sim.auto) simSet(Sim.gross + Sim.auto * 0.25);
    Scale.gross = Sim.gross; Scale.stable = Sim.auto === 0; Scale.lastTs = Date.now(); Scale.source = 'sim'; Scale.connected = true;
}
function setSim(on) {
    S.sim = !!on; localStorage.setItem('feedAppSim', S.sim ? '1' : '0');
    $('moreSim').checked = S.sim;
    $('simBar').classList.toggle('hidden', !S.sim || S.tab !== 'truck');
    if (S.sim) { if (!Sim.timer) Sim.timer = setInterval(simTick, 250); simTick(); }
    else { clearInterval(Sim.timer); Sim.timer = null; Sim.auto = 0; $('simAutoBtn').textContent = 'Auto ▶'; Scale.source = 'none'; Scale.lastTs = 0; Scale.connected = false; }
    renderChips();
}
$('simSlider').addEventListener('input', e => simSet(Number(e.target.value)));
document.querySelectorAll('[data-sim]').forEach(b => b.addEventListener('click', () => simSet(Sim.gross + Number(b.dataset.sim))));
$('simAutoBtn').addEventListener('click', () => {
    // cycles: off -> filling (+400 lb/s) -> emptying (-400 lb/s) -> off
    Sim.auto = Sim.auto === 0 ? 400 : Sim.auto > 0 ? -400 : 0;
    $('simAutoBtn').textContent = Sim.auto === 0 ? 'Auto ▶' : Sim.auto > 0 ? 'Filling ▲ (tap)' : 'Emptying ▼ (tap)';
});

// ---------------------------------------------------------
// sync queue: upserts by id, in order, deduped in place
// ---------------------------------------------------------
const PERMANENT_PG_CODES = ['42501', '23514', '23503', '23502', '22P02', 'P0001', '23505'];
let queueGen = 0;   // bumped on every enqueue so a sync in flight knows to go again
function enqueue(table, row, op, key) {
    const k = key || 'id';
    const i = S.queue.findIndex(q => q.table === table && q.row[k] === row[k] && (q.key || 'id') === k);
    const entry = { table, row, op: op || 'upsert', key: k, _attempts: 0 };
    if (i >= 0) S.queue[i] = entry; else S.queue.push(entry);
    queueGen++;
}
// Order changes go as UPDATEs keyed on pasture_id: crew may change the two
// order columns (a DB trigger refuses anything else) but may not INSERT a
// setup row, and an upsert is an insert first.
function queueOrder(pid, patch) { enqueue('pasture_feed_setup', Object.assign({ pasture_id: pid }, patch), 'update', 'pasture_id'); }

// Drag-to-reorder on a finger (iPad Safari has no touch drag-and-drop): a
// handle is pressed, items shuffle as the pointer crosses their midlines,
// the list's `.locked` class parks it. Same helper as the office app.
function makeSortable(container, itemSel, handleSel, onDrop) {
    container.addEventListener('pointerdown', e => {
        const handle = e.target.closest(handleSel);
        if (!handle || container.classList.contains('locked')) return;
        const item = handle.closest(itemSel); if (!item) return;
        e.preventDefault();
        item.classList.add('dragging');
        const move = ev => {
            const items = [...container.querySelectorAll(itemSel)].filter(x => x !== item);
            for (const other of items) { const r = other.getBoundingClientRect(); if (ev.clientY < r.top + r.height / 2) { other.parentNode.insertBefore(item, other); return; } }
            if (items.length) items[items.length - 1].parentNode.appendChild(item);
        };
        const up = () => { item.classList.remove('dragging'); document.removeEventListener('pointermove', move); document.removeEventListener('pointerup', up); document.removeEventListener('pointercancel', up); onDrop([...container.querySelectorAll(itemSel)].map(x => x.dataset.pid)); };
        document.addEventListener('pointermove', move); document.addEventListener('pointerup', up); document.addEventListener('pointercancel', up);
    });
}
function loadRow(l) {
    const { lines, drops, _ui, ...row } = l; return row;
}
// Queue a whole load: the load row first, then lines, drops and lot
// splits, so a first-time sync creates parents before children.
function queueLoad(l) {
    enqueue('feed_loads', loadRow(l));
    (l.lines || []).forEach(x => enqueue('feed_load_lines', x));
    (l.drops || []).forEach(d => { const { lots, ...dr } = d; enqueue('feed_drops', dr); (lots || []).forEach(x => enqueue('feed_drop_lots', x)); });
    persist(); renderChips();
    if (navigator.onLine) processQueue();
}
async function processQueue() {
    if (S.syncing || !navigator.onLine || !S.userId || !S.queue.length) { renderChips(); return; }
    S.syncing = true; renderChips();
    const snapshot = S.queue.slice();
    const failed = [];
    for (const q of snapshot) {
        let ok = false;
        try {
            const { error } = q.op === 'update'
                ? await sb.from(q.table).update(q.row).eq(q.key, q.row[q.key])
                : await sb.from(q.table).upsert(q.row, { onConflict: 'id' });
            if (!error) ok = true;
            else if (PERMANENT_PG_CODES.includes(error.code) || /feed_load_guard|status_guard|frozen_guard/.test(error.message || '')) {
                S.rejected.unshift({ table: q.table, id: q.row.id, reason: error.message, at: new Date().toISOString() });
                S.rejected = S.rejected.slice(0, 30); saveJSON('feedAppRejected', S.rejected);
                toast('Save refused: ' + error.message, 'error', 6000);
                ok = true;   // stop retrying; it will never succeed
            } else { console.warn('transient', error); }
        } catch (e) { console.warn('network', e); }
        if (!ok) { q._attempts = (q._attempts || 0) + 1; failed.push(q); }
    }
    // Anything enqueued during this round is not in the snapshot - including
    // a row replaced in place with a newer version - and goes next.
    const fresh = S.queue.filter(q => !snapshot.includes(q));
    S.queue = failed.concat(fresh); S.syncing = false; persist(); renderChips();
    if (fresh.length && navigator.onLine) processQueue();
}
window.addEventListener('online', () => { renderChips(); processQueue(); });
window.addEventListener('offline', renderChips);
setInterval(() => { if (navigator.onLine) processQueue(); }, 45000);

// ---------------------------------------------------------
// pull everything the day needs (D15) - needs signal
// ---------------------------------------------------------
async function fetchAll(build) {
    const PAGE = 1000; let out = [], from = 0;
    for (;;) {
        const res = await build().range(from, from + PAGE - 1);
        if (res.error) return { error: res.error };
        out = out.concat(res.data || []);
        if (!res.data || res.data.length < PAGE) break;
        from += PAGE;
    }
    return { data: out };
}
async function pullRefs(quiet) {
    if (!navigator.onLine) { if (!quiet) toast('No signal - using the last data pulled', 'error'); return false; }
    const today = ranchToday();
    try {
        const [ra, su, pa, it, lo, tr, st, asg, br, ld] = await Promise.all([
            sb.from('rations').select('*, ration_lines(*)').eq('is_active', true).order('name'),
            sb.from('pasture_feed_setup').select('*').eq('is_active', true),
            sb.from('pastures').select('id, name, ranch_id, ranches(name)').eq('is_active', true),
            sb.from('feed_items').select('id, name, default_location_id, is_active'),
            sb.from('feed_storage_locations').select('id, name, is_active'),
            sb.from('feed_trucks').select('*').eq('is_active', true).order('name'),
            sb.from('ranch_settings').select('feed_truck_tolerance_pct, feed_truck_min_split_lb, feed_truck_tieout_pct, feed_truck_post_from').maybeSingle(),
            fetchAll(() => sb.from('lot_pasture_assignments').select('lot_id, pasture_id, head_count, lots!inner(lot_number, closed_at, is_test)').is('moved_out', null).order('id')),
            sb.from('bunk_reads').select('*').gte('read_date', shiftDays(today, -21)).order('read_date', { ascending: false }),
            sb.from('feed_loads').select('*, feed_load_lines(*), feed_drops(*, feed_drop_lots(*))').gte('load_date', shiftDays(today, -14)).order('load_date', { ascending: false }).order('load_seq', { ascending: false })
        ]);
        const bad = [ra, su, pa, it, lo, tr, st, asg, br, ld].find(r => r.error);
        if (bad) {
            const m = bad.error.message || '';
            toast(/relation .* does not exist|schema cache/i.test(m) ? 'The feed truck tables are not in the database yet' : 'Pull failed: ' + m, 'error', 5000);
            return false;
        }
        const pastureHead = {}; const lotNames = {};
        (asg.data || []).forEach(a => {
            if (!a.lots || a.lots.closed_at || a.lots.is_test || /^TEST[_-]/i.test(a.lots.lot_number || '')) return;
            const n = Number(a.head_count) || 0; if (n <= 0) return;
            lotNames[a.lot_id] = a.lots.lot_number;
            const arr = pastureHead[a.pasture_id] = pastureHead[a.pasture_id] || [];
            const hit = arr.find(x => x.lot_id === a.lot_id);
            if (hit) hit.head += n; else arr.push({ lot_id: a.lot_id, lot_number: a.lots.lot_number, head: n });
        });
        (ld.data || []).forEach(l => (l.feed_drops || []).forEach(d => (d.feed_drop_lots || []).forEach(x => { if (!lotNames[x.lot_id]) lotNames[x.lot_id] = lotNames[x.lot_id] || '?'; })));
        // Reads: today's rows, and the most recent earlier row per pasture
        // (the prefill), plus the last 15 days for the little history.
        const lastReads = {}; const todayRows = {}; const history = {};
        (br.data || []).forEach(r => {
            if (r.read_date === today) todayRows[r.pasture_id] = r;
            else if (!lastReads[r.pasture_id]) lastReads[r.pasture_id] = r;
            (history[r.pasture_id] = history[r.pasture_id] || []).push({ d: r.read_date, s: r.bunk_score, lb: r.lb_per_head, t: r.target_lb });
        });
        S.refs = {
            pulledAt: new Date().toISOString(),
            rations: (ra.data || []).map(r => ({ ...r, ration_lines: (r.ration_lines || []).slice().sort((a, b) => a.load_order - b.load_order) })),
            setup: su.data || [],
            pastures: (pa.data || []).map(p => ({ id: p.id, name: p.name, ranch: p.ranches ? p.ranches.name : '' })),
            items: it.data || [], locations: lo.data || [], trucks: tr.data || [], settings: st.data || {},
            pastureHead, lotNames, lastReads, history,
            serverLoads: (ld.data || []).map(normalizeServerLoad)
        };
        saveJSON('feedAppRefs', S.refs);
        // Today's reads from the server win over a stale local copy unless
        // the local copy is dirty (the person is typing on THIS device).
        if (S.reads.date !== today) { S.reads = { date: today, rows: {} }; S.readsDirty = false; }
        if (!S.readsDirty) Object.keys(todayRows).forEach(pid => { S.reads.rows[pid] = todayRows[pid]; });
        // A local load the office has posted or voided is now theirs.
        S.loads = S.loads.map(l => { const srv = S.refs.serverLoads.find(x => x.id === l.id); return srv && (srv.status === 'posted' || srv.status === 'void') ? srv : l; });
        S.loads = S.loads.filter(l => l.load_date >= shiftDays(today, -14));
        if (S.activeLoadId && !activeLoad()) S.activeLoadId = null;
        persist();
        if (!quiet) toast('Ranch data pulled', 'ok');
        return true;
    } catch (e) {
        console.error(e); if (!quiet) toast('Pull failed: ' + (e.message || e), 'error', 4000); return false;
    }
}
function normalizeServerLoad(l) {
    const { feed_load_lines, feed_drops, ...row } = l;
    return { ...row, lines: (feed_load_lines || []).slice().sort((a, b) => a.load_order - b.load_order),
             drops: (feed_drops || []).map(d => { const { feed_drop_lots, ...dr } = d; return { ...dr, lots: feed_drop_lots || [] }; }).sort((a, b) => a.drop_seq - b.drop_seq) };
}
// Every load we know of: local copies win over the server's (the queue
// may still hold the truth), server fills in the rest.
function allLoads() {
    const byId = new Map();
    ((S.refs && S.refs.serverLoads) || []).forEach(l => byId.set(l.id, l));
    S.loads.forEach(l => byId.set(l.id, l));
    return [...byId.values()].sort((a, b) => (b.load_date.localeCompare(a.load_date)) || (b.load_seq - a.load_seq));
}
function activeLoad() { return S.loads.find(l => l.id === S.activeLoadId && !['closed', 'posted', 'void'].includes(l.status)) || null; }
function todayLoads() { const t = ranchToday(); return allLoads().filter(l => l.load_date === t && l.status !== 'void'); }
const loadedLb = l => (l.lines || []).reduce((s, x) => s + (Number(x.lb) || 0), 0);
const droppedLb = l => (l.drops || []).reduce((s, d) => s + (Number(d.lb) || 0), 0);

// ---------------------------------------------------------
// chips + tabs
// ---------------------------------------------------------
function renderChips() {
    const sc = $('scaleChip');
    if (S.sim) { sc.textContent = 'sim ' + fmt(Scale.gross); sc.className = 'chip ok'; }
    else if (scaleLive()) { sc.textContent = (Scale.deviceName || 'scale') + ' ' + fmt(Scale.gross); sc.className = 'chip ok'; }
    else if (Scale.connected) { sc.textContent = 'scale stale'; sc.className = 'chip warn'; }
    else { sc.textContent = hasShell() ? 'no scale' : 'no scale (browser)'; sc.className = 'chip bad'; }
    const sy = $('syncChip'); const n = S.queue.length;
    if (!navigator.onLine) { sy.textContent = n ? `offline · ${n}` : 'offline'; sy.className = 'chip warn'; }
    else if (S.syncing) { sy.textContent = `syncing ${n}`; sy.className = 'chip warn'; }
    else if (n) { sy.textContent = `${n} to send`; sy.className = 'chip warn'; }
    else { sy.textContent = 'synced'; sy.className = 'chip ok'; }
    const t = currentTruck();
    $('topSub').textContent = `${fmtDate(ranchToday())}${t ? ' · ' + t.name : ''}${S.profile ? ' · ' + S.profile.full_name : ''}`;
    $('moreQueue').textContent = n ? `${n} row${n === 1 ? '' : 's'}` : 'nothing';
    $('moreScale').textContent = S.sim ? 'simulated' : scaleLive() ? `${Scale.deviceName || Scale.deviceId || 'linked'} · ${fmt(Scale.gross)} lb` : hasShell() ? 'not connected' : 'no Bluetooth in a browser - use the shell app or the simulator';
    document.querySelectorAll('.tabbar button').forEach(b => {
        const on = b.dataset.tab === S.tab; b.classList.toggle('active', on);
        if (b.dataset.tab === 'truck') b.innerHTML = 'Truck' + (activeLoad() ? '<span class="n">●</span>' : '');
    });
}
function showTab(tab) {
    if (tab !== 'bunks' && S.readsDirty && tab !== 'more') {
        if (!confirm('Bunk calls are not saved yet. Leave without saving?')) return;
    }
    S.tab = tab;
    document.querySelectorAll('.view').forEach(v => v.classList.toggle('active', v.id === 'v-' + tab));
    $('bunkSaveBar').classList.toggle('hidden', tab !== 'bunks');
    $('simBar').classList.toggle('hidden', !S.sim || tab !== 'truck');
    renderChips();
    if (tab === 'bunks') renderBunks();
    if (tab === 'plan') renderPlan();
    if (tab === 'truck') renderTruck();
    if (tab === 'history') renderHistory();
    if (tab === 'more') renderMore();
}
document.querySelectorAll('.tabbar button').forEach(b => b.addEventListener('click', () => showTab(b.dataset.tab)));

// ---------------------------------------------------------
// BUNKS (D3, D4, D6)
// ---------------------------------------------------------
// Two orders on pasture_feed_setup (2026-09-05): the feed ROUTE the truck
// drives (route_order) and the bunk READING walk (read_order). Either may be
// dragged here; the DB lets crew change only those two columns.
function activeSetup() { return ((S.refs && S.refs.setup) || []).filter(s => s.is_active && R.pasture(s.pasture_id)); }
function routeSetup() {
    return activeSetup().sort((a, b) => ((Number(a.route_order) || 0) - (Number(b.route_order) || 0)) || pastureLabel(a.pasture_id).localeCompare(pastureLabel(b.pasture_id)));
}
function readSetup() {
    return activeSetup().sort((a, b) => ((Number(a.read_order) || Number(a.route_order) || 0) - (Number(b.read_order) || Number(b.route_order) || 0)) || pastureLabel(a.pasture_id).localeCompare(pastureLabel(b.pasture_id)));
}
// Today's read for a pasture, created (unsaved) from setup + the prefill
// the first time it is asked for. Everything the truck needs is snapshotted
// on the row (D6): feeder type, head, ration, route order.
function readFor(pid) {
    const today = ranchToday();
    if (S.reads.date !== today) { S.reads = { date: today, rows: {} }; S.readsDirty = false; }
    let r = S.reads.rows[pid];
    if (r) return r;
    const s = R.setup(pid) || {};
    const last = (S.refs && S.refs.lastReads && S.refs.lastReads[pid]) || null;
    const head = pastureHeadTotal(pid);
    const bulk = s.feeder_type === 'bulk';
    const lbhd = bulk ? null : (last && last.lb_per_head != null ? Number(last.lb_per_head) : 0);
    r = {
        id: uuid(), read_date: today, pasture_id: pid, feeder_type: bulk ? 'bulk' : 'bunk',
        bunk_score: null, lb_per_head: lbhd, head_count: head,
        target_lb: bulk ? (last ? Number(last.target_lb) || 0 : 0) : round1((lbhd || 0) * head),
        ration_id: s.ration_id || null, route_order: s.route_order || 0, frozen_load_id: null,
        notes: null, client_id: null, read_by: S.userId, _new: true
    };
    S.reads.rows[pid] = r;
    return r;
}
function readFrozen(r) { return !!r.frozen_load_id && allLoads().some(l => l.id === r.frozen_load_id && l.status !== 'void'); }
function setRead(pid, patch) {
    const r = readFor(pid);
    if (readFrozen(r)) { toast('This call is already loaded on the truck', 'error'); return; }
    Object.assign(r, patch);
    if (r.feeder_type === 'bunk') { r.head_count = pastureHeadTotal(pid); r.target_lb = round1((Number(r.lb_per_head) || 0) * r.head_count); }
    S.readsDirty = true; S.planEdits = null; persist(); renderBunks();
}
S.bunkIdx = 0;
function bunkGo(delta) {
    const n = readSetup().length; if (!n) return;
    S.bunkIdx = Math.max(0, Math.min(n - 1, S.bunkIdx + delta));
    renderBunks();
}
function readStatus(r) {
    if (r.feeder_type === 'bulk') return { txt: fmt(r.target_lb) + ' lb', done: !r._new };
    const scored = r.bunk_score != null;
    return { txt: (scored ? 'score ' + r.bunk_score + ' · ' : '') + fmt(r.lb_per_head, 2) + ' lb/hd', done: scored };
}
function renderBunks() {
    $('bunkDateH').textContent = 'Bunk read · ' + fmtDate(ranchToday());
    const card = $('bunkCard'), side = $('bunkSideList');
    if (!S.refs) { card.innerHTML = '<div class="empty">Pull ranch data first (More › Pull ranch data). It needs signal.</div>'; side.innerHTML = ''; $('bunkPos').textContent = '—'; return; }
    const order = readSetup();
    if (!order.length) { card.innerHTML = '<div class="empty">No pastures are on the feed route. The office sets them under Inventory › Truck › Pastures &amp; route.</div>'; side.innerHTML = ''; $('bunkPos').textContent = '—'; return; }
    if (S.bunkIdx >= order.length) S.bunkIdx = order.length - 1;
    const s = order[S.bunkIdx]; const pid = s.pasture_id;
    const r = readFor(pid); const frozen = readFrozen(r);
    const head = R.head(pid); const ration = R.ration(r.ration_id);
    const hist = ((S.refs.history || {})[pid] || []).slice(0, 7).reverse();
    const bulk = r.feeder_type === 'bulk';
    $('bunkPos').innerHTML = `${S.bunkIdx + 1} of ${order.length}<span class="sub">${order.filter(x => readStatus(readFor(x.pasture_id)).done).length} read</span>`;
    $('bunkPrevBtn').disabled = S.bunkIdx === 0; $('bunkNextBtn').disabled = S.bunkIdx === order.length - 1;
    const scores = [0, 1, 2, 3].map(n => `<button type="button" data-score="${n}" class="${r.bunk_score === n ? 'on' : ''}" ${frozen ? 'disabled' : ''}>${n}</button>`).join('');
    card.innerHTML = `<div class="card bunk-one ${frozen ? 'locked' : ''}" data-pid="${pid}">
        <div class="name">${esc(pastureLabel(pid))}</div>
        <div class="lots">${fmt(r.head_count)} hd${head.length ? ' · ' + head.map(h => esc(h.lot_number) + ' ' + h.head).join(', ') : ''}${ration ? ' · ' + esc(ration.name) : ' · <span class="tag red">no ration</span>'}${frozen ? ' · <span class="frozen">on the truck</span>' : ''}</div>
        ${bulk ? `<div class="label">Total pounds in the feeder</div>
                  <div class="stepper"><button type="button" data-step="-100" ${frozen ? 'disabled' : ''}>−</button><span class="val" data-edit="total">${fmt(r.target_lb)}</span><button type="button" data-step="100" ${frozen ? 'disabled' : ''}>+</button></div>`
               : `<div class="label">Bunk score</div><div class="scores">${scores}</div>
                  <div class="label">Pounds per head, as fed</div>
                  <div class="stepper"><button type="button" data-step="-0.25" ${frozen ? 'disabled' : ''}>−</button><span class="val" data-edit="lbhd">${fmt(r.lb_per_head, 2)}</span><button type="button" data-step="0.25" ${frozen ? 'disabled' : ''}>+</button></div>`}
        <div class="total"><span class="muted">${bulk ? 'Bulk feeder' : 'Pasture total'}</span><b>${fmt(r.target_lb)} lb</b></div>
        ${hist.length ? `<div class="label">Last ${hist.length} days · score / lb</div><div class="hist">${hist.map(h => `<span>${h.s != null ? h.s : '·'}<b>${h.lb != null ? fmt(h.lb, 1) : fmt(h.t)}</b></span>`).join('')}</div>` : ''}
    </div>`;
    card.querySelectorAll('[data-score]').forEach(b => b.addEventListener('click', () => { const x = readFor(pid); setRead(pid, { bunk_score: x.bunk_score === Number(b.dataset.score) ? null : Number(b.dataset.score) }); }));
    card.querySelectorAll('[data-step]').forEach(b => {
        let hold = null, fired = false;
        const step = () => { const x = readFor(pid); const d = Number(b.dataset.step);
            if (x.feeder_type === 'bulk') setRead(pid, { target_lb: Math.max(0, round1((Number(x.target_lb) || 0) + d)) });
            else setRead(pid, { lb_per_head: Math.max(0, Math.round(((Number(x.lb_per_head) || 0) + d) * 100) / 100) }); };
        b.addEventListener('click', () => { if (!fired) step(); fired = false; });
        b.addEventListener('touchstart', () => { hold = setTimeout(function run() { fired = true; step(); hold = setTimeout(run, 140); }, 450); }, { passive: true });
        ['touchend', 'touchcancel'].forEach(ev => b.addEventListener(ev, () => { clearTimeout(hold); hold = null; }));
    });
    card.querySelectorAll('[data-edit]').forEach(v => v.addEventListener('click', () => {
        const x = readFor(pid); if (readFrozen(x)) return;
        const isTotal = v.dataset.edit === 'total';
        const ans = prompt(isTotal ? 'Total pounds for this feeder:' : 'Pounds per head as-fed:', String(isTotal ? x.target_lb : (x.lb_per_head == null ? '' : x.lb_per_head)));
        if (ans === null) return; const n = parseFloat(ans); if (isNaN(n) || n < 0) return;
        setRead(pid, isTotal ? { target_lb: round1(n) } : { lb_per_head: Math.round(n * 100) / 100 });
    }));
    // the reading order down the side: tap to jump, unlock to drag
    side.innerHTML = order.map((x, i) => { const rr = readFor(x.pasture_id); const st = readStatus(rr);
        return `<div class="side-item ${i === S.bunkIdx ? 'cur' : ''}" data-pid="${x.pasture_id}"><span class="drag">&#9776;</span><span class="n">${i + 1}</span><span class="nm">${esc(pastureLabel(x.pasture_id))}</span><span class="st ${st.done ? 'done' : ''}">${readFrozen(rr) ? 'on truck' : st.done ? '✓ ' + st.txt : st.txt}</span></div>`; }).join('');
    side.querySelectorAll('.side-item .nm, .side-item .st, .side-item .n').forEach(el => el.addEventListener('click', () => { S.bunkIdx = order.findIndex(x => x.pasture_id === el.parentNode.dataset.pid); renderBunks(); }));
    $('bunkSaveHint').textContent = S.readsDirty ? 'Unsaved changes' : (Object.values(S.reads.rows).some(x => !x._new) ? 'Saved' : 'Not saved yet');
    $('bunkSaveBtn').disabled = false;
}
function applyOrder(field, pids) {
    pids.forEach((pid, i) => { const st = R.setup(pid); if (!st) return; if (Number(st[field]) !== i + 1) { st[field] = i + 1; queueOrder(pid, { [field]: i + 1 }); if (field === 'route_order') { const r = S.reads.rows[pid]; if (r) r.route_order = i + 1; } } });
    saveJSON('feedAppRefs', S.refs); S.planEdits = null; persist(); renderChips();
    if (navigator.onLine) processQueue();
}
makeSortable($('bunkSideList'), '.side-item', '.drag', pids => { const cur = readSetup()[S.bunkIdx]; applyOrder('read_order', pids); S.bunkIdx = Math.max(0, pids.indexOf(cur ? cur.pasture_id : '')); renderBunks(); });
$('bunkLockBtn').addEventListener('click', () => { const locked = $('bunkSideList').classList.toggle('locked'); $('bunkLockBtn').innerHTML = locked ? '&#128274;' : '&#128275; drag'; });
$('bunkPrevBtn').addEventListener('click', () => bunkGo(-1));
$('bunkNextBtn').addEventListener('click', () => bunkGo(1));
// Saving needs signal, and says so (D15). Every row on the route is saved
// so a pasture nobody touched still carries yesterday's call (D4).
async function saveBunks() {
    if (!S.refs) return;
    if (!navigator.onLine) { alertBox('bunkAlert', 'No signal. Bunk calls save straight to the ranch; try again when you have a bar.'); return; }
    alertBox('bunkAlert', '');
    const rows = readSetup().map(s => readFor(s.pasture_id)).filter(r => !readFrozen(r)).map(r => { const { _new, ...row } = r; return { ...row, route_order: (R.setup(r.pasture_id) || {}).route_order || row.route_order, read_by: S.userId }; });
    if (!rows.length) return;
    $('bunkSaveBtn').disabled = true; $('bunkSaveHint').textContent = 'Saving…';
    try {
        const { data, error } = await sb.from('bunk_reads').upsert(rows, { onConflict: 'read_date,pasture_id' }).select();
        if (error) { alertBox('bunkAlert', 'Not saved: ' + esc(error.message)); return; }
        if (!data || data.length !== rows.length) { alertBox('bunkAlert', 'Not every call was saved - check your role with the office.'); return; }
        data.forEach(r => { S.reads.rows[r.pasture_id] = r; });
        S.readsDirty = false; persist(); renderBunks();
        toast('Calls saved', 'ok');
    } finally { $('bunkSaveBtn').disabled = false; }
}
$('bunkSaveBtn').addEventListener('click', saveBunks);
$('bunkRefreshBtn').addEventListener('click', async () => { if (await pullRefs()) renderBunks(); });

// ---------------------------------------------------------
// PLAN (D6, D9, D14)
// ---------------------------------------------------------
// What is still owed today per pasture: the call less what loads already
// started have planned or dropped for it.
function remainingCalls() {
    const served = {};
    todayLoads().forEach(l => (l.drops || []).forEach(d => { served[d.pasture_id] = (served[d.pasture_id] || 0) + Math.max(Number(d.lb) || 0, d.done_at ? 0 : Number(d.target_lb) || 0); }));
    return routeSetup().map(s => readFor(s.pasture_id)).map(r => ({
        pasture_id: r.pasture_id, label: pastureLabel(r.pasture_id), ration_id: r.ration_id,
        lb: round1(Math.max(0, (Number(r.target_lb) || 0) - (served[r.pasture_id] || 0))),
        one_pass: !!(R.setup(r.pasture_id) || {}).one_pass, route_order: r.route_order, read: r
    })).filter(c => c.lb > 0);
}
// Leftover in the box from the most recent load, for Distribute (D9).
function boxState() {
    const last = allLoads().find(l => ['closed', 'posted'].includes(l.status));
    if (!last || !(Number(last.left_in_box_lb) > 0)) return { lb: 0, ration_id: null };
    // Only if no later load has already carried it.
    const later = allLoads().find(l => l.status !== 'void' && (l.load_date > last.load_date || (l.load_date === last.load_date && l.load_seq > last.load_seq)));
    if (later) return { lb: 0, ration_id: null };
    return { lb: Number(last.left_in_box_lb), ration_id: last.ration_id };
}
function capFor(rationId) {
    const r = R.ration(rationId); const t = currentTruck();
    const a = r && Number(r.max_load_lb) > 0 ? Number(r.max_load_lb) : null;
    const b = t && Number(t.capacity_lb) > 0 ? Number(t.capacity_lb) : null;
    return a && b ? Math.min(a, b) : (a || b || null);
}
function buildPlan() {
    const calls = remainingCalls();
    const byRation = new Map();
    calls.forEach(c => { const k = c.ration_id || 'none'; (byRation.get(k) || byRation.set(k, []).get(k)).push(c); });
    const out = [];
    byRation.forEach((cs, rid) => {
        if (S.planEdits && S.planEdits[rid]) { out.push({ ration_id: rid, loads: S.planEdits[rid] }); return; }
        out.push({ ration_id: rid, loads: planLoads({ calls: cs, cap: capFor(rid === 'none' ? null : rid), minSplit: minSplit() }) });
    });
    return out;
}
// PB's Delivery overview, John's pick for this page (2026-09-06): one card
// per load - red header, the pens with Target and Fed, a Total, then the
// feed with Target and Loaded. Loads already run today show their actuals
// in the same shape; planned ones show zeros until the truck moves.
function ingredientTargets(rationId, plannedLb, carriedLb) {
    const r = R.ration(rationId); if (!r) return [];
    const fresh = Math.max(0, plannedLb - (carriedLb || 0));
    return r.ration_lines.map(ln => ({ item_id: ln.item_id, target_lb: round1(fresh * Number(ln.pct_as_fed) / 100) }));
}
function pbCard(opts) {
    // opts: {seq, rationName, pens:[{label, target, fed, split}], feed:[{name, target, loaded, done}], status, action, editable, over_cap, carried, ri, li}
    const pensTotal = opts.pens.reduce((s, x) => s + x.target, 0), fedTotal = opts.pens.reduce((s, x) => s + x.fed, 0);
    const pens = opts.pens.map((x, di) => `<tr class="drop-row" data-ri="${opts.ri || ''}" data-li="${opts.li == null ? '' : opts.li}" data-di="${di}">
        <td>${esc(x.label)}${x.split ? '<span class="tag amber">split</span>' : ''}</td>
        <td class="num"><span class="lb-show">${fmt(x.target)}</span><input type="number" step="10" min="0" class="lb-edit hidden" value="${x.target}"></td>
        <td class="num">${fmt(x.fed)}</td>
        <td class="mv hidden"><button type="button" data-move="-1" ${opts.li === 0 ? 'disabled' : ''}>↑</button><button type="button" data-move="1">↓</button></td></tr>`).join('');
    const feed = opts.feed.map(x => `<tr><td>${esc(x.name)}</td><td class="num">${fmt(x.target)}</td><td class="num ${x.done ? 'done' : ''}">${fmt(x.loaded)}</td></tr>`).join('');
    return `<div class="pb-load ${opts.status || ''}" data-ri="${opts.ri || ''}" data-li="${opts.li == null ? '' : opts.li}">
        <div class="pb-head"><span>Load ${opts.seq}</span><span class="pb-status">${esc(opts.statusText || '')}</span>${opts.action || ''}</div>
        <table class="pb-pens"><thead><tr><th>${esc(opts.rationName)}</th><th class="num">Target</th><th class="num">Fed</th><th class="mv hidden"></th></tr></thead>
            <tbody>${pens}</tbody>
            <tfoot><tr><td>Total${opts.carried ? ` <span class="pb-note">${fmt(opts.carried.lb)} lb in box</span>` : ''}${opts.over_cap ? ' <span class="tag red">over cap</span>' : ''}</td><td class="num">${fmt(pensTotal)}</td><td class="num">${fmt(fedTotal)}</td><td class="mv hidden"></td></tr></tfoot></table>
        <table class="pb-feed"><thead><tr><th></th><th class="num">Target</th><th class="num">Loaded</th></tr></thead><tbody>${feed}</tbody></table>
    </div>`;
}
function renderPlan() {
    const sel = $('planTruck');
    sel.innerHTML = ((S.refs && S.refs.trucks) || []).map(t => `<option value="${t.id}" ${currentTruck() && currentTruck().id === t.id ? 'selected' : ''}>${esc(t.name)}</option>`).join('') || '<option value="">no trucks</option>';
    const list = $('planList'); alertBox('planAlert', '');
    if (!S.refs) { list.innerHTML = '<div class="empty">Pull ranch data first.</div>'; renderRouteList(); return; }
    const act = activeLoad();
    let html = '';
    // Loads already run or running today, actuals in the same shape.
    todayLoads().slice().sort((a, b) => a.load_seq - b.load_seq).forEach(l => {
        const r = R.ration(l.ration_id) || {};
        const statusText = { loading: 'loading', mixing: 'mixing', dropping: 'feeding', closed: 'done', posted: 'posted' }[l.status] || l.status;
        html += pbCard({ seq: l.load_seq, rationName: r.name || '?', statusText, status: l.status,
            pens: (l.drops || []).map(d => ({ label: pastureLabel(d.pasture_id), target: Number(d.target_lb) || 0, fed: Number(d.lb) || 0 })),
            feed: (l.lines || []).map(x => ({ name: (R.item(x.item_id) || {}).name || '?', target: Number(x.target_lb) || 0, loaded: Number(x.lb) || 0, done: !!x.done_at })),
            action: act && act.id === l.id ? '<button type="button" class="pb-select plan-open">Open</button>' : '' });
    });
    if (act) html += `<div class="alert warn">Load ${act.load_seq} is in progress. Finish or close it on the Truck tab before starting another.</div>`;
    const plan = buildPlan();
    const box = boxState();
    let seq = todayLoads().length;
    if (!plan.length) html += '<div class="empty">Nothing left to feed today. Set calls on Bunks (and save them) first.</div>';
    plan.forEach(group => {
        const ration = R.ration(group.ration_id);
        const cap = capFor(group.ration_id);
        if (!ration) { html += `<div class="alert error">${group.loads.reduce((n, l) => n + l.drops.length, 0)} pasture(s) have no ration set. The office sets it under Pastures &amp; route.</div>`; return; }
        group.loads.forEach((l, li) => {
            seq += 1;
            const carried = (li === 0 && box.lb > 0) ? box : null;
            html += pbCard({ seq, rationName: ration.name, ri: group.ration_id, li, over_cap: l.over_cap, carried, statusText: cap ? `cap ${fmt(cap)}` : '',
                pens: l.drops.map(d => ({ label: d.label, target: d.lb, fed: 0, split: d.split })),
                feed: ingredientTargets(group.ration_id, l.lb, carried ? carried.lb : 0).map(x => ({ name: (R.item(x.item_id) || {}).name || '?', target: x.target_lb, loaded: 0 })),
                action: `<button type="button" class="pb-edit plan-edit">Edit</button>${li === 0 && !act ? `<button type="button" class="pb-select plan-start">Start</button>` : ''}` });
        });
    });
    list.innerHTML = html;
    list.querySelectorAll('.plan-open').forEach(b => b.addEventListener('click', () => showTab('truck')));
    list.querySelectorAll('.plan-edit').forEach(b => b.addEventListener('click', () => {
        const card = b.closest('.pb-load'); const editing = card.classList.toggle('editing');
        card.querySelectorAll('.lb-show').forEach(x => x.classList.toggle('hidden', editing));
        card.querySelectorAll('.lb-edit, .mv').forEach(x => x.classList.toggle('hidden', !editing));
        b.textContent = editing ? 'Apply' : 'Edit';
        if (!editing) {
            const plan = buildPlan(); const g = plan.find(x => x.ration_id === card.dataset.ri); if (!g) return;
            const loads = JSON.parse(JSON.stringify(g.loads));
            card.querySelectorAll('.drop-row').forEach(row => { const v = parseFloat(row.querySelector('.lb-edit').value); if (!isNaN(v) && v >= 0) loads[Number(row.dataset.li)].drops[Number(row.dataset.di)].lb = round1(v); });
            loads.forEach(l => { l.drops = l.drops.filter(d => d.lb > 0); l.lb = round1(l.drops.reduce((s, d) => s + d.lb, 0)); });
            S.planEdits = S.planEdits || {}; S.planEdits[card.dataset.ri] = loads.filter(l => l.drops.length);
            renderPlan();
        }
    }));
    list.querySelectorAll('[data-move]').forEach(b => b.addEventListener('click', () => {
        const row = b.closest('.drop-row'); const ri = row.dataset.ri, li = Number(row.dataset.li), di = Number(row.dataset.di);
        const plan = buildPlan(); const g = plan.find(x => x.ration_id === ri); if (!g) return;
        const loads = JSON.parse(JSON.stringify(g.loads));
        const [d] = loads[li].drops.splice(di, 1);
        const to = li + Number(b.dataset.move);
        if (!loads[to]) loads.push({ drops: [], lb: 0, over_cap: false });
        loads[to].drops.push(d);
        loads.forEach(l => { l.lb = round1(l.drops.reduce((s, x) => s + x.lb, 0)); l.over_cap = capFor(ri) ? l.lb > capFor(ri) + 0.5 : false; });
        S.planEdits = S.planEdits || {}; S.planEdits[ri] = loads.filter(l => l.drops.length);
        renderPlan();
    }));
    list.querySelectorAll('.plan-start').forEach(b => b.addEventListener('click', () => startLoad(b.closest('.pb-load').dataset.ri)));
    renderRouteList();
}
function renderRouteList() {
    const el = $('routeList'); if (!S.refs) { el.innerHTML = ''; return; }
    const started = new Set(todayLoads().flatMap(l => (l.drops || []).map(d => d.pasture_id)));
    el.innerHTML = routeSetup().map((x, i) => { const r = readFor(x.pasture_id);
        return `<div class="side-item" data-pid="${x.pasture_id}"><span class="drag">&#9776;</span><span class="n">${i + 1}</span><span class="nm">${esc(pastureLabel(x.pasture_id))}</span><span class="st ${started.has(x.pasture_id) ? 'done' : ''}">${fmt(r.target_lb)} lb${started.has(x.pasture_id) ? ' · loaded' : ''}</span></div>`; }).join('');
}
makeSortable($('routeList'), '.side-item', '.drag', pids => { applyOrder('route_order', pids); renderPlan(); });
$('routeLockBtn').addEventListener('click', () => { const locked = $('routeList').classList.toggle('locked'); $('routeLockBtn').innerHTML = locked ? '&#128274;' : '&#128275; drag'; });
$('planTruck').addEventListener('change', e => { S.truckId = e.target.value || null; localStorage.setItem('feedAppTruckId', S.truckId || ''); S.planEdits = null; renderPlan(); renderChips(); });

// Start a load (D6, D7, D9): the load row, its ingredient lines cut for
// any leftover already in the box, its planned drops, and the calls it
// carries frozen.
function startLoad(rationId) {
    if (activeLoad()) { toast('Finish the load in progress first', 'error'); return; }
    if (S.readsDirty) { toast('Save the bunk calls first', 'error'); showTab('bunks'); return; }
    const plan = buildPlan().find(g => g.ration_id === rationId); if (!plan || !plan.loads.length) return;
    const ration = R.ration(rationId); if (!ration) { toast('No ration on these pastures', 'error'); return; }
    if (!ration.ration_lines.length) { toast('That ration has no ingredients', 'error'); return; }
    const truck = currentTruck();
    const first = plan.loads[0];
    const box = boxState();
    const planned = first.lb;
    const fresh = Math.max(0, planned - box.lb);      // Distribute: the box ends at planned
    const id = uuid(); const now = new Date().toISOString();
    const load = {
        id, load_date: ranchToday(), load_seq: todayLoads().length + 1, ration_id: rationId,
        truck_id: truck ? truck.id : null, scale_device_id: Scale.deviceId || (S.sim ? 'SIM' : null),
        status: 'loading', planned_lb: planned, carried_in_lb: box.lb, carried_in_ration_id: box.ration_id,
        left_in_box_lb: 0, mix_minutes_required: Number(ration.mix_minutes) || 0,
        loading_started_at: now, mix_started_at: null, first_drop_at: null, closed_at: null,
        posted_at: null, posted_by: null, voided_at: null, voided_by: null, void_reason: null,
        notes: null, client_id: id, created_by: S.userId,
        lines: ration.ration_lines.map((ln, i) => ({
            id: uuid(), load_id: id, item_id: ln.item_id,
            location_id: ln.default_location_id || (R.item(ln.item_id) || {}).default_location_id || null,
            load_order: ln.load_order || i + 1, target_lb: round1(fresh * Number(ln.pct_as_fed) / 100),
            scale_lb: null, lb: 0, done_at: null, link_ok: null, edited_by: null, edited_at: null, edit_reason: null, client_id: null
        })),
        drops: first.drops.map((d, i) => ({
            id: uuid(), load_id: id, pasture_id: d.pasture_id, drop_seq: i + 1, target_lb: d.lb,
            start_gross_lb: null, end_gross_lb: null, scale_lb: null, lb: 0, started_at: null, done_at: null, link_ok: null,
            edited_by: null, edited_at: null, edit_reason: null, client_id: null, lots: []
        })),
        _ui: { line: 0, lineStart: null, drop: 0, dropStart: null }
    };
    const missingBay = load.lines.find(l => !l.location_id);
    if (missingBay) { toast(`${(R.item(missingBay.item_id) || {}).name || 'An ingredient'} has no bay set on the ration`, 'error', 4000); return; }
    S.loads.push(load); S.activeLoadId = id; S.planEdits = null;
    // Freeze the calls this load carries (D6).
    first.drops.forEach(d => { const r = readFor(d.pasture_id); if (!r.frozen_load_id) { r.frozen_load_id = id; const { _new, ...row } = r; enqueue('bunk_reads', row); } });
    queueLoad(load);
    showTab('truck');
}

// ---------------------------------------------------------
// TRUCK (D7, D8, D9, D10, D12)
// ---------------------------------------------------------
let tick = null;
function band(remaining, target) {
    if (target <= 0) return 'idle';
    if (remaining <= 0) return 'red';
    return remaining <= target * tolerancePct() / 100 ? 'yellow' : '';
}
function saveLoad(l) { persist(); queueLoad(l); }
function renderTruck() {
    const l = activeLoad();
    $('truckNone').classList.toggle('hidden', !!l);
    $('truckLoad').classList.toggle('hidden', !l || l.status !== 'loading');
    $('truckMix').classList.toggle('hidden', !l || l.status !== 'mixing');
    $('truckDrop').classList.toggle('hidden', !l || l.status !== 'dropping');
    $('simBar').classList.toggle('hidden', !S.sim || S.tab !== 'truck');
    if (!l) { if (tick) { clearInterval(tick); tick = null; } return; }
    if (!tick) tick = setInterval(truckTick, 250);
    if (l.status === 'loading') renderLoading(l);
    if (l.status === 'mixing') renderMixing(l);
    if (l.status === 'dropping') renderDropping(l);
    truckTick();
}
function truckTick() {
    const l = activeLoad(); if (!l || S.tab !== 'truck') return;
    const g = scaleGross(); const live = scaleLive();
    if (l.status === 'loading') {
        const ln = l.lines[l._ui.line];
        $('ldGross').textContent = g == null ? '—' : fmt(g);
        $('ldLink').textContent = S.sim ? 'sim' : live ? 'link' : 'no link'; $('ldLink').className = 'scale-state ' + (S.sim ? 'sim' : live ? 'ok' : '');
        if (!ln) return;
        if (l._ui.lineStart == null && g != null) l._ui.lineStart = g;
        const got = (g != null && l._ui.lineStart != null) ? Math.max(0, g - l._ui.lineStart) : 0;
        const remaining = ln.target_lb - got;
        $('ldBigNum').textContent = fmt(Math.round(remaining));
        $('ldBig').className = 'big-panel ' + (g == null ? 'idle' : band(remaining, ln.target_lb));
        $('ldBigFoot').textContent = `${fmt(Math.round(got))} of ${fmt(ln.target_lb)} lb in · ${remaining <= 0 ? 'target reached - tap Done' : 'to go'}`;
        $('ldDoneBtn').disabled = !live;
        $('ldDoneBtn').textContent = live ? 'Done' : 'No link';
    } else if (l.status === 'mixing') {
        const req = (Number(l.mix_minutes_required) || 0) * 60;
        const elapsed = (Date.now() - new Date(l.mix_started_at).getTime()) / 1000;
        const left = req - elapsed;
        $('mxNum').textContent = left > 0 ? mmss(left) : '0:00';
        $('mxBig').className = 'big-panel mix' + (left <= 0 ? ' done' : '');
        $('mxFoot').textContent = left > 0 ? `${l.mix_minutes_required} min mix. No feed until the timer hits zero.` : `Mixed. Waited ${mmss(elapsed)}.`;
        $('mxGoBtn').disabled = left > 0;
        if (left <= 0 && !l._ui.chimed) { l._ui.chimed = true; chime(); persist(); }
    } else if (l.status === 'dropping') {
        const d = l.drops[l._ui.drop];
        $('drGross').textContent = g == null ? '—' : fmt(g);
        $('drLink').textContent = S.sim ? 'sim' : live ? 'link' : 'no link'; $('drLink').className = 'scale-state ' + (S.sim ? 'sim' : live ? 'ok' : '');
        if (!d) return;
        const started = l._ui.dropStart != null;
        const out = (started && g != null) ? Math.max(0, l._ui.dropStart - g) : 0;
        const remaining = d.target_lb - out;
        $('drBigNum').textContent = fmt(Math.round(started ? remaining : d.target_lb));
        $('drBig').className = 'big-panel ' + (!started || g == null ? 'idle' : band(remaining, d.target_lb));
        $('drBigFoot').textContent = started ? `${fmt(Math.round(out))} of ${fmt(d.target_lb)} lb out · ${remaining <= 0 ? 'target reached - tap Done' : 'to go'}` : `target ${fmt(d.target_lb)} lb · tap Start when you are at the bunk`;
        $('drStartBtn').classList.toggle('hidden', started); $('drDoneBtn').classList.toggle('hidden', !started);
        $('drStartBtn').disabled = !live; $('drDoneBtn').disabled = !live;
        if (!live) { $('drStartBtn').textContent = 'No link'; $('drDoneBtn').textContent = 'No link'; }
        else { $('drStartBtn').textContent = 'Start'; $('drDoneBtn').textContent = 'Done'; }
    }
}
function chime() {
    try {
        const ctx = new (window.AudioContext || window.webkitAudioContext)();
        [0, 0.35, 0.7].forEach(t => { const o = ctx.createOscillator(), gn = ctx.createGain(); o.frequency.value = 880; o.connect(gn); gn.connect(ctx.destination);
            gn.gain.setValueAtTime(0.4, ctx.currentTime + t); gn.gain.exponentialRampToValueAtTime(0.01, ctx.currentTime + t + 0.3); o.start(ctx.currentTime + t); o.stop(ctx.currentTime + t + 0.3); });
    } catch (e) {}
    if (navigator.vibrate) navigator.vibrate([200, 100, 200, 100, 400]);
}

// ---- loading ----
function renderLoading(l) {
    const ration = R.ration(l.ration_id) || {};
    const loaded = loadedLb(l);
    $('ldTitle').textContent = `${ration.name || 'Ration'} - ${fmt(l.planned_lb)}`;
    $('ldSub').textContent = `Load ${l.load_seq} · ${fmt(loaded)} lb loaded${l.carried_in_lb > 0 ? ` · ${fmt(l.carried_in_lb)} lb already in the box` : ''} · ${l.drops.length} drop${l.drops.length === 1 ? '' : 's'}`;
    const ln = l.lines[l._ui.line];
    $('ldBigLabel').textContent = ln ? `${(R.item(ln.item_id) || {}).name || '?'}` : 'All ingredients done';
    $('ldTiles').innerHTML = l.lines.map((x, i) => `<div class="tile ${i === l._ui.line ? 'cur' : ''} ${x.done_at ? 'done' : ''} ${x.edited_at ? 'edited' : ''}" data-i="${i}">
        <div class="name">${esc((R.item(x.item_id) || {}).name || '?')}</div>
        <div class="bay">${esc((R.loc(x.location_id) || {}).name || 'no bay')}</div>
        <div class="tgt">${fmt(x.target_lb)}</div>
        <div class="got">${x.done_at ? fmt(x.lb) : '0'}</div></div>`).join('');
    $('ldTiles').querySelectorAll('.tile').forEach(t => t.addEventListener('click', () => {
        const i = Number(t.dataset.i);
        if (l.lines[i].done_at) { editLine(l, i); return; }
        l._ui.line = i; l._ui.lineStart = scaleGross(); persist(); renderLoading(l);
    }));
    $('ldSkipBtn').classList.toggle('hidden', !ln);
    $('ldDoneBtn').classList.toggle('hidden', !ln);
    if (!ln) { $('ldBigNum').textContent = '✓'; $('ldBig').className = 'big-panel'; $('ldBigFoot').textContent = 'Starting the mix timer…'; }
}
function nextUndoneLine(l, from) { for (let k = 0; k < l.lines.length; k++) { const i = (from + k) % l.lines.length; if (!l.lines[i].done_at) return i; } return -1; }
function lineDone(l, lb, viaScale) {
    const ln = l.lines[l._ui.line]; if (!ln) return;
    ln.scale_lb = viaScale ? lb : null; ln.lb = lb; ln.done_at = new Date().toISOString(); ln.link_ok = viaScale ? scaleLive() : false;
    const next = nextUndoneLine(l, l._ui.line + 1);
    if (next < 0) {
        // Timer starts on the last ingredient's Done (D7). Hard block (D8).
        l.status = 'mixing'; l.mix_started_at = new Date().toISOString(); l._ui.chimed = false;
        if ((Number(l.mix_minutes_required) || 0) === 0) { l._ui.chimed = true; }
        saveLoad(l); renderTruck(); return;
    }
    l._ui.line = next; l._ui.lineStart = scaleGross();
    saveLoad(l); renderLoading(l);
}
$('ldDoneBtn').addEventListener('click', () => {
    const l = activeLoad(); if (!l || l.status !== 'loading') return;
    const g = scaleGross(); if (g == null) { toast('No scale reading', 'error'); return; }
    if (l._ui.lineStart == null) l._ui.lineStart = g;
    const got = round1(Math.max(0, g - l._ui.lineStart));
    const ln = l.lines[l._ui.line];
    if (got === 0 && !confirm(`Nothing went in for ${(R.item(ln.item_id) || {}).name || 'this ingredient'}. Mark it done at 0 lb?`)) return;
    lineDone(l, got, true);
});
$('ldSkipBtn').addEventListener('click', () => {
    const l = activeLoad(); if (!l || l.status !== 'loading') return;
    const ln = l.lines[l._ui.line]; if (!ln) return;
    if (!confirm(`Skip ${(R.item(ln.item_id) || {}).name || 'this ingredient'}? It goes down as 0 lb and the next ingredient comes up.`)) return;
    lineDone(l, 0, false);
});
$('ldZeroBtn').addEventListener('click', () => {
    const l = activeLoad();
    const inBox = l ? (Number(l.carried_in_lb) || 0) + loadedLb(l) : 0;
    if (inBox > 0 && !confirm(`The app believes ${fmt(inBox)} lb is in the box. Zeroing the head now makes that feed invisible to the next load's Distribute. Zero anyway?`)) return;
    if (S.sim) simSet(0); else if (!shellSend('zero')) toast('No scale shell to send Zero to', 'error');
    if (l && l.status === 'loading') { l._ui.lineStart = 0; persist(); }
});
$('ldEditBtn').addEventListener('click', () => { const l = activeLoad(); if (l) editSheetForLoad(l); });

// ---- mixing ----
function renderMixing(l) {
    const ration = R.ration(l.ration_id) || {};
    $('mxTitle').textContent = `${ration.name || 'Ration'} - ${fmt(loadedLb(l))}`;
    $('mxSub').textContent = `Load ${l.load_seq} · ${l.drops.length} drop${l.drops.length === 1 ? '' : 's'} to make`;
}
$('mxGoBtn').addEventListener('click', () => {
    const l = activeLoad(); if (!l || l.status !== 'mixing') return;
    const req = (Number(l.mix_minutes_required) || 0) * 60;
    if ((Date.now() - new Date(l.mix_started_at).getTime()) / 1000 < req) { toast('Not mixed yet', 'error'); return; }
    l.status = 'dropping'; l._ui.drop = nextUndoneDrop(l, 0); l._ui.dropStart = null;
    saveLoad(l); renderTruck();
});

// ---- dropping ----
function nextUndoneDrop(l, from) { for (let k = 0; k < l.drops.length; k++) { const i = (from + k) % l.drops.length; if (!l.drops[i].done_at) return i; } return -1; }
function renderDropping(l) {
    const ration = R.ration(l.ration_id) || {};
    const inBox = round1((Number(l.carried_in_lb) || 0) + loadedLb(l) - droppedLb(l));
    $('drTitle').textContent = `${ration.name || 'Ration'} - ${fmt(round1((Number(l.carried_in_lb) || 0) + loadedLb(l)))}`;
    $('drSub').textContent = `Load ${l.load_seq} · ${fmt(inBox)} lb in the box · ${fmt(droppedLb(l))} fed`;
    const d = l.drops[l._ui.drop];
    $('drBigLabel').textContent = d ? pastureLabel(d.pasture_id) : 'All drops done';
    $('drTiles').innerHTML = l.drops.map((x, i) => `<div class="tile ${i === l._ui.drop ? 'cur' : ''} ${x.done_at ? 'done' : ''} ${x.edited_at ? 'edited' : ''}" data-i="${i}">
        <div class="name">${esc(pastureLabel(x.pasture_id))}</div>
        <div class="bay">${fmt(pastureHeadTotal(x.pasture_id))} hd${x.lots && x.lots.length > 1 ? ' · ' + x.lots.length + ' lots' : ''}</div>
        <div class="tgt">${fmt(x.target_lb)}</div>
        <div class="got">${x.done_at ? fmt(x.lb) : '0'}</div></div>`).join('');
    $('drTiles').querySelectorAll('.tile').forEach(t => t.addEventListener('click', () => {
        const i = Number(t.dataset.i);
        if (l.drops[i].done_at) { editDrop(l, i); return; }
        if (l._ui.dropStart != null && i !== l._ui.drop && !confirm('A drop is in progress. Switch pasture and lose its start reading?')) return;
        l._ui.drop = i; l._ui.dropStart = null; persist(); renderDropping(l);
    }));
    $('drStartBtn').classList.toggle('hidden', !d || l._ui.dropStart != null);
    $('drDoneBtn').classList.toggle('hidden', !d || l._ui.dropStart == null);
    if (!d) { $('drBigNum').textContent = '✓'; $('drBig').className = 'big-panel'; $('drBigFoot').textContent = `${fmt(inBox)} lb left in the box · tap Close load`; }
}
$('drStartBtn').addEventListener('click', () => {
    const l = activeLoad(); if (!l || l.status !== 'dropping') return;
    const g = scaleGross(); if (g == null) { toast('No scale reading', 'error'); return; }
    const d = l.drops[l._ui.drop]; if (!d) return;
    d.start_gross_lb = g; d.started_at = new Date().toISOString(); l._ui.dropStart = g;
    if (!l.first_drop_at) l.first_drop_at = d.started_at;
    saveLoad(l); renderDropping(l);
});
$('drDoneBtn').addEventListener('click', () => {
    const l = activeLoad(); if (!l || l.status !== 'dropping') return;
    const g = scaleGross(); if (g == null) { toast('No scale reading', 'error'); return; }
    const d = l.drops[l._ui.drop]; if (!d || l._ui.dropStart == null) return;
    const out = round1(Math.max(0, l._ui.dropStart - g));
    if (out === 0 && !confirm('The scale did not drop. Record 0 lb for this pasture?')) return;
    d.end_gross_lb = g; d.scale_lb = out; d.lb = out; d.done_at = new Date().toISOString(); d.link_ok = scaleLive();
    d.lots = splitLots(d);
    l._ui.dropStart = null; l._ui.drop = nextUndoneDrop(l, l._ui.drop + 1);
    saveLoad(l); renderDropping(l);
});
// D10: pro-rata by head on the books, stored per drop. Empty when the
// barn pull knew of no head here; posting fills it from the books then.
function splitLots(d) {
    const heads = R.head(d.pasture_id);
    if (!heads.length || !(Number(d.lb) > 0)) return [];
    const parts = lrSplit(Number(d.lb), heads.map(h => h.head), 2);
    return heads.map((h, i) => ({ id: (d.lots || []).find(x => x.lot_id === h.lot_id)?.id || uuid(), drop_id: d.id, lot_id: h.lot_id, head_count: h.head, lb: parts[i] }));
}
$('drAddBtn').addEventListener('click', () => {
    const l = activeLoad(); if (!l || l.status !== 'dropping') return;
    const opts = routeSetup().map(s => s.pasture_id).concat((S.refs.pastures || []).map(p => p.id).filter(id => !R.setup(id)));
    sheet('Add a pasture to this load', `<label>Pasture</label><select id="shPasture">${opts.map(id => `<option value="${id}">${esc(pastureLabel(id))}</option>`).join('')}</select>
        <label>Target (lb)</label><input type="number" id="shTarget" step="10" min="0" value="0">`, () => {
        const pid = $('shPasture').value; const t = round1(Math.max(0, parseFloat($('shTarget').value) || 0));
        l.drops.push({ id: uuid(), load_id: l.id, pasture_id: pid, drop_seq: l.drops.length + 1, target_lb: t, start_gross_lb: null, end_gross_lb: null, scale_lb: null, lb: 0,
            started_at: null, done_at: null, link_ok: null, edited_by: null, edited_at: null, edit_reason: null, client_id: null, lots: [] });
        if (l._ui.drop < 0) l._ui.drop = l.drops.length - 1;
        saveLoad(l); renderDropping(l);
    });
});
$('drCloseBtn').addEventListener('click', () => {
    const l = activeLoad(); if (!l || l.status !== 'dropping') return;
    const undone = l.drops.filter(d => !d.done_at);
    const inBox = round1(Math.max(0, (Number(l.carried_in_lb) || 0) + loadedLb(l) - droppedLb(l)));
    const msg = (undone.length ? `${undone.length} planned drop(s) were not made. ` : '') + `${fmt(inBox)} lb stays in the box and carries into the next load. Close this load?`;
    if (!confirm(msg)) return;
    // Undone planned drops stay on record at 0 lb; nothing is deleted (D12).
    l.left_in_box_lb = inBox; l.status = 'closed'; l.closed_at = new Date().toISOString();
    S.activeLoadId = null; saveLoad(l);
    toast('Load closed', 'ok'); showTab('plan');
});
$('drEditBtn').addEventListener('click', () => { const l = activeLoad(); if (l) editSheetForLoad(l); });

// ---- edits before posting (D12): scale reading kept, override + reason ----
function sheet(title, bodyHtml, onOk) {
    $('sheetTitle').textContent = title; $('sheetBody').innerHTML = bodyHtml;
    $('sheetBackdrop').classList.add('show');
    const close = () => { $('sheetBackdrop').classList.remove('show'); $('sheetOk').onclick = null; $('sheetCancel').onclick = null; };
    $('sheetCancel').onclick = close;
    $('sheetOk').onclick = () => { if (onOk() !== false) close(); };
}
function editable(l) { return !['posted', 'void'].includes(l.status); }
function editLine(l, i) {
    if (!editable(l)) { toast('This load is posted; the office can unpost it', 'error'); return; }
    const x = l.lines[i];
    sheet(`${(R.item(x.item_id) || {}).name || 'Ingredient'} · scale read ${x.scale_lb == null ? '—' : fmt(x.scale_lb)} lb`,
        `<label>Pounds to book</label><input type="number" id="shLb" step="1" min="0" value="${x.lb}">
         <label>Bay</label><select id="shLoc">${(S.refs.locations || []).filter(o => o.is_active || o.id === x.location_id).map(o => `<option value="${o.id}" ${o.id === x.location_id ? 'selected' : ''}>${esc(o.name)}</option>`).join('')}</select>
         <label>Reason (required if the pounds change)</label><input type="text" id="shWhy" value="${esc(x.edit_reason || '')}" placeholder="e.g. scale bounced, loader spilled">`,
        () => {
            const lb = round1(Math.max(0, parseFloat($('shLb').value) || 0)); const why = $('shWhy').value.trim();
            if (lb !== Number(x.lb) && !why) { toast('A reason is required', 'error'); return false; }
            x.location_id = $('shLoc').value || x.location_id;
            if (lb !== Number(x.lb)) { x.lb = lb; x.edited_by = S.userId; x.edited_at = new Date().toISOString(); x.edit_reason = why; }
            saveLoad(l); renderTruck(); if (S.tab === 'history') renderHistory();
        });
}
function editDrop(l, i) {
    if (!editable(l)) { toast('This load is posted; the office can unpost it', 'error'); return; }
    const d = l.drops[i];
    const opts = (S.refs.pastures || []).map(p => `<option value="${p.id}" ${p.id === d.pasture_id ? 'selected' : ''}>${esc(pastureLabel(p.id))}</option>`).join('');
    sheet(`Drop ${d.drop_seq} · scale read ${d.scale_lb == null ? '—' : fmt(d.scale_lb)} lb`,
        `<label>Pasture</label><select id="shPasture">${opts}</select>
         <label>Pounds to book</label><input type="number" id="shLb" step="1" min="0" value="${d.lb}">
         <label>Reason (required for any change)</label><input type="text" id="shWhy" value="${esc(d.edit_reason || '')}" placeholder="e.g. wrong bunk tapped">`,
        () => {
            const lb = round1(Math.max(0, parseFloat($('shLb').value) || 0)); const pid = $('shPasture').value; const why = $('shWhy').value.trim();
            const changed = lb !== Number(d.lb) || pid !== d.pasture_id;
            if (changed && !why) { toast('A reason is required', 'error'); return false; }
            if (changed) { d.lb = lb; d.pasture_id = pid; d.edited_by = S.userId; d.edited_at = new Date().toISOString(); d.edit_reason = why; d.lots = splitLots(d); }
            saveLoad(l); renderTruck(); if (S.tab === 'history') renderHistory();
        });
}
function editSheetForLoad(l) {
    const rows = l.lines.map((x, i) => `<tr class="editable" data-k="line" data-i="${i}"><td>${esc((R.item(x.item_id) || {}).name || '?')}</td><td class="num">${fmt(x.target_lb)}</td><td class="num">${x.done_at ? fmt(x.lb) : '—'}</td><td>${x.edited_at ? 'edited' : ''}</td></tr>`).join('')
        + l.drops.map((d, i) => `<tr class="editable" data-k="drop" data-i="${i}"><td>${esc(pastureLabel(d.pasture_id))}</td><td class="num">${fmt(d.target_lb)}</td><td class="num">${d.done_at ? fmt(d.lb) : '—'}</td><td>${d.edited_at ? 'edited' : ''}</td></tr>`).join('');
    sheet(`Load ${l.load_seq} · tap a row to edit`, `<table class="mini"><thead><tr><th>Item / pasture</th><th class="num">Target</th><th class="num">Booked</th><th></th></tr></thead><tbody>${rows}</tbody></table>`, () => {});
    $('sheetBody').querySelectorAll('tr.editable').forEach(tr => tr.addEventListener('click', () => {
        $('sheetBackdrop').classList.remove('show');
        if (tr.dataset.k === 'line') editLine(l, Number(tr.dataset.i)); else editDrop(l, Number(tr.dataset.i));
    }));
}

// ---------------------------------------------------------
// HISTORY
// ---------------------------------------------------------
function renderHistory() {
    const list = $('histList');
    const loads = allLoads();
    if (!loads.length) { list.innerHTML = '<div class="empty">No loads in the last two weeks.</div>'; return; }
    list.innerHTML = loads.map(l => {
        const st = l.status === 'posted' ? 'posted' : l.status === 'void' ? 'void' : l.status === 'closed' ? 'closed' : 'open';
        const mixOk = l.mix_started_at && l.first_drop_at ? ((new Date(l.first_drop_at) - new Date(l.mix_started_at)) / 60000 + 0.05 >= (Number(l.mix_minutes_required) || 0)) : null;
        return `<div class="card hist-card" data-id="${l.id}">
            <div class="hist"><div class="title">${esc(fmtDate(l.load_date))} · load ${l.load_seq} · ${esc((R.ration(l.ration_id) || {}).name || '?')}</div><div class="st ${st}">${esc(l.status)}</div>
            <div class="sub">${fmt(loadedLb(l))} lb loaded · ${fmt(droppedLb(l))} dropped over ${(l.drops || []).filter(d => Number(d.lb) > 0).length} pasture(s)${Number(l.left_in_box_lb) > 0 ? ' · ' + fmt(l.left_in_box_lb) + ' left in box' : ''}${mixOk === false ? ' · <span class="tag red">mix short</span>' : ''}${(l.lines || []).some(x => x.edited_at) || (l.drops || []).some(d => d.edited_at) ? ' · <span class="tag amber">edited</span>' : ''}</div></div>
        </div>`;
    }).join('');
    list.querySelectorAll('.hist-card').forEach(c => c.addEventListener('click', () => {
        let l = S.loads.find(x => x.id === c.dataset.id);
        if (!l) { const srv = allLoads().find(x => x.id === c.dataset.id); if (!srv) return; l = { ...srv, _ui: { line: 0, drop: 0 } }; if (editable(l)) { S.loads.push(l); persist(); } }
        if (!l._ui) l._ui = { line: 0, drop: 0 };
        editSheetForLoad(l);
    }));
}
$('histRefreshBtn').addEventListener('click', async () => { if (await pullRefs()) renderHistory(); });

// ---------------------------------------------------------
// MORE
// ---------------------------------------------------------
function renderMore() {
    $('moreUser').textContent = S.profile ? `${S.profile.full_name} · ${S.profile.role}` : '—';
    const sel = $('moreTruck');
    sel.innerHTML = ((S.refs && S.refs.trucks) || []).map(t => `<option value="${t.id}" ${currentTruck() && currentTruck().id === t.id ? 'selected' : ''}>${esc(t.name)}</option>`).join('') || '<option value="">no trucks</option>';
    $('moreSim').checked = S.sim;
    $('morePulled').textContent = S.refs && S.refs.pulledAt ? new Date(S.refs.pulledAt).toLocaleString('en-US', { timeZone: 'America/Chicago' }) : 'never';
    $('moreRejected').innerHTML = S.rejected.length ? `<div class="card"><div class="title">Refused by the ranch database</div>${S.rejected.slice(0, 5).map(r => `<div class="small muted">${esc(r.table)} · ${esc(r.reason)}</div>`).join('')}</div>` : '';
    renderChips();
}
$('moreTruck').addEventListener('change', e => { S.truckId = e.target.value || null; localStorage.setItem('feedAppTruckId', S.truckId || ''); S.planEdits = null; renderChips(); });
$('moreSim').addEventListener('change', e => setSim(e.target.checked));
$('morePullBtn').addEventListener('click', async () => { await pullRefs(); renderMore(); });
$('moreSyncBtn').addEventListener('click', async () => { await processQueue(); toast(S.queue.length ? `${S.queue.length} still waiting` : 'All synced', S.queue.length ? 'error' : 'ok'); renderMore(); });
$('moreScanBtn').addEventListener('click', () => { if (!shellSend('scan')) toast('No scale shell - Bluetooth needs the JFR Feed app, not a browser', 'error', 4000); });
$('moreSignOutBtn').addEventListener('click', async () => {
    if (S.queue.length && !confirm(`${S.queue.length} row(s) have not synced and will be lost. Sign out anyway?`)) return;
    await sb.auth.signOut(); purgeLocal(); location.reload();
});

// ---------------------------------------------------------
// auth + boot (same three outcomes as the field app)
// ---------------------------------------------------------
function showLoginError(msg) { $('loginAlert').textContent = msg; $('loginAlert').style.display = 'block'; }
async function onSignedIn(user) {
    const { data: profile, error } = await sb.from('user_profiles').select('full_name, role, is_active').eq('id', user.id).maybeSingle();
    if (error) { showLoginError(`Couldn't reach the ranch database (${error.code || error.message || 'network'}). Check signal and try again.`); $('loginBtn').disabled = false; return; }
    if (!profile) { await sb.auth.signOut(); showLoginError(`Signed in as ${user.email || 'this account'}, but it has no ranch profile. Ask the office to add one.`); $('loginBtn').disabled = false; return; }
    if (!profile.is_active) { await sb.auth.signOut(); showLoginError(`The account ${user.email || ''} has been deactivated.`); $('loginBtn').disabled = false; return; }
    // A different person on this device: the cache is theirs, not yours.
    const prev = localStorage.getItem('feedAppUserId');
    if (prev && prev !== user.id) { purgeLocal(); S.refs = null; S.loads = []; S.reads = { date: null, rows: {} }; S.queue = []; S.rejected = []; S.activeLoadId = null; }
    localStorage.setItem('feedAppUserId', user.id);
    S.userId = user.id; S.profile = profile;
    $('loginScreen').style.display = 'none'; $('app').classList.remove('hidden');
    startApp();
}
async function startApp() {
    if (S.sim) setSim(true);
    renderChips();
    const stale = !S.refs || (Date.now() - new Date(S.refs.pulledAt).getTime() > 10 * 60 * 1000);
    if (navigator.onLine && stale) await pullRefs(true);
    if (navigator.onLine) processQueue();
    showTab(activeLoad() ? 'truck' : 'bunks');
}
$('loginForm').addEventListener('submit', async e => {
    e.preventDefault(); $('loginAlert').style.display = 'none'; $('loginBtn').disabled = true; $('loginBtn').textContent = 'Signing in…';
    try {
        const { data, error } = await sb.auth.signInWithPassword({ email: $('loginEmail').value.trim(), password: $('loginPassword').value });
        if (error) { showLoginError(`${error.message}${error.status ? ` (${error.status})` : ''}`); $('loginBtn').disabled = false; }
        else await onSignedIn(data.user);
    } catch (err) { showLoginError(err.message || 'Sign-in failed. Check signal and try again.'); $('loginBtn').disabled = false; }
    $('loginBtn').textContent = 'Sign in';
});
if ('serviceWorker' in navigator) window.addEventListener('load', () => navigator.serviceWorker.register('./sw.js').catch(e => console.warn('SW', e)));
(async function bootstrap() {
    try {
        const { data: { session } } = await sb.auth.getSession();
        if (session && session.user) await onSignedIn(session.user);
        else $('loginScreen').style.display = 'flex';
    } catch (e) { console.error('bootstrap', e); $('loginScreen').style.display = 'flex'; }
})();
