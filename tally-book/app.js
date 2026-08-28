// =========================================================
// Tally Book — JFR Ranch
// Daily bullet journal + project status register.
//
// Schema: docs/sql/2026-08-28_tally_book.sql
// Tables: tally_entries, tally_projects — both RLS-scoped to auth.uid().
//
// Classic script, not an ES module: the Supabase client is vendored
// (supabase.min.js) rather than pulled from esm.sh, so the app boots with
// no network. An ESM import from a CDN is the one asset a service worker
// cannot cache cross-origin, which would have made "offline" mean "blank
// page" — the opposite of what a pocket tally book is for.
// =========================================================

const SUPABASE_URL = 'https://xpfmebdzcxorvwikfvtj.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_LhyJ7-bxebSa7HuRTxjmBQ__73Oc-66';

const el = (id) => document.getElementById(id);

// If the library did not load, every handler below is inert and the page
// still renders — which looks like a broken app rather than a failed load.
// Same guard, same reason, as the field app.
if (!window.supabase || typeof window.supabase.createClient !== 'function') {
    document.addEventListener('DOMContentLoaded', () => {
        const b = el('errorBanner');
        if (b) {
            b.textContent = 'The Supabase library did not load. Check your connection and reload.';
            b.classList.add('show');
        }
    });
    throw new Error('Supabase library not available');
}

// Default storage key on purpose: the office app, the field app and this one
// share an origin, so one sign-in covers all three. Sign-out does too — the
// button says so.
const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true }
});

let currentUserId = null;

// ── The day boundary ──────────────────────────────────────
// NOT toISOString(). That yields UTC, so after 7pm Central (6pm CST) the
// app rolls to tomorrow: today's log empties, everything just written jumps
// into "open loops", and the book looks wrong all evening. Every read here
// is keyed on this one value. Pinned to the ranch's clock, matching
// ranchToday() in the office app and public.ranch_today() in the database.
function ranchToday() {
    return new Intl.DateTimeFormat('en-CA', {
        timeZone: 'America/Chicago',
        year: 'numeric', month: '2-digit', day: '2-digit'
    }).format(new Date());   // en-CA formats as YYYY-MM-DD
}

let TODAY = ranchToday();

// ── Error surfacing ───────────────────────────────────────
// CLAUDE.md: errors must never be silently swallowed. The handed-over draft
// console.error()'d every failure, so a refused write looked identical to a
// successful one from the phone.
let errorTimer = null;
function showError(msg, err) {
    if (err) console.error(msg, err);
    const b = el('errorBanner');
    b.textContent = err && err.message ? `${msg} — ${err.message}` : msg;
    b.classList.add('show');
    clearTimeout(errorTimer);
    errorTimer = setTimeout(() => b.classList.remove('show'), 6000);
}

function clearError() {
    el('errorBanner').classList.remove('show');
}

// ── Boot ──────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', boot);

async function boot() {
    el('loginForm').addEventListener('submit', onSignIn);
    el('signOutBtn').addEventListener('click', onSignOut);
    el('rapidForm').addEventListener('submit', onSubmitEntry);
    el('priorityToggle').addEventListener('click', togglePriority);
    el('pfCancel').addEventListener('click', closeProjectSheet);
    el('pfSave').addEventListener('click', saveProject);
    el('projectSheet').addEventListener('click', (e) => {
        if (e.target === el('projectSheet')) closeProjectSheet();
    });

    window.addEventListener('online', () => { clearOffline(); refreshAll(); });
    window.addEventListener('offline', markOffline);
    if (!navigator.onLine) markOffline();

    // The date can go stale in an installed PWA that is never closed. Re-check
    // when the app comes back to the foreground and reload the day if it moved.
    document.addEventListener('visibilitychange', () => {
        if (document.visibilityState !== 'visible') return;
        const now = ranchToday();
        if (now !== TODAY) { TODAY = now; renderDateLine(); refreshAll(); }
    });

    if ('serviceWorker' in navigator) {
        navigator.serviceWorker.register('sw.js').catch(() => {});
    }

    const { data: { session } } = await sb.auth.getSession();
    if (session && session.user) {
        await enterBook(session.user.id);
    } else {
        showLogin();
    }
}

function markOffline()  { el('offlineBanner').classList.add('show'); }
function clearOffline() { el('offlineBanner').classList.remove('show'); }

function showLogin() {
    currentUserId = null;
    el('loginView').hidden = false;
    el('bookView').hidden = true;
    el('loginEmail').focus();
}

async function enterBook(userId) {
    currentUserId = userId;
    el('loginView').hidden = true;
    el('bookView').hidden = false;
    TODAY = ranchToday();
    renderDateLine();
    await refreshAll();
}

function renderDateLine() {
    // Formatted from the ranch's date, not the device's, so the masthead and
    // the queries can never disagree about what day it is.
    const [y, m, d] = TODAY.split('-').map(Number);
    el('dateLine').textContent = new Date(y, m - 1, d).toLocaleDateString(undefined, {
        weekday: 'long', month: 'long', day: 'numeric', year: 'numeric'
    });
}

async function refreshAll() {
    await Promise.all([loadOpenLoops(), loadRapidBucket(), loadToday(), loadProjects()]);
}

// ── Auth ──────────────────────────────────────────────────

async function onSignIn(e) {
    e.preventDefault();
    const btn = el('loginBtn');
    const errBox = el('loginError');
    errBox.textContent = '';
    btn.disabled = true;
    btn.textContent = 'Signing in…';

    const { data, error } = await sb.auth.signInWithPassword({
        email: el('loginEmail').value.trim(),
        password: el('loginPassword').value
    });

    btn.disabled = false;
    btn.textContent = 'Sign in';

    if (error) {
        errBox.textContent = error.message || 'Sign-in failed.';
        return;
    }
    el('loginPassword').value = '';
    await enterBook(data.user.id);
}

async function onSignOut() {
    // Shared session across the JFR apps on this origin — say so rather than
    // letting the office app quietly log out in another tab.
    if (!confirm('Sign out? This signs you out of all JFR Ranch apps on this device.')) return;
    await sb.auth.signOut();
    el('openLoopsList').innerHTML = '';
    el('rapidList').innerHTML = '';
    el('todayList').innerHTML = '';
    el('projectList').innerHTML = '';
    showLogin();
}

function togglePriority() {
    const btn = el('priorityToggle');
    const active = btn.classList.toggle('active');
    btn.setAttribute('aria-pressed', String(active));
}

// ── Data loads ────────────────────────────────────────────

async function loadOpenLoops() {
    const { data, error } = await sb
        .from('tally_entries')
        .select('*')
        .eq('status', 'open')
        .not('type', 'is', null)
        .lt('entry_date', TODAY)
        .order('entry_date', { ascending: true });

    if (error) return showError('Could not load open loops', error);
    clearError();
    el('openLoopsCount').textContent = data.length ? `(${data.length})` : '';
    renderTriageList('openLoopsList', data, 'nothing carried over — clean slate');
}

async function loadRapidBucket() {
    const { data, error } = await sb
        .from('tally_entries')
        .select('*')
        .eq('status', 'open')
        .is('type', null)
        .order('created_at', { ascending: true });

    if (error) return showError('Could not load the rapid log', error);
    el('rapidCount').textContent = data.length ? `(${data.length})` : '';
    renderTriageList('rapidList', data, "bucket's empty", { uncategorized: true });
}

async function loadToday() {
    // Killed entries stay in the row but drop out of the day's page — the
    // strike-through is a paper metaphor, not a reason to keep reading it.
    const { data, error } = await sb
        .from('tally_entries')
        .select('*')
        .eq('entry_date', TODAY)
        .not('type', 'is', null)
        .neq('status', 'killed')
        .order('created_at', { ascending: true });

    if (error) return showError("Could not load today's log", error);
    el('todayCount').textContent = data.length ? `(${data.length})` : '';
    renderTodayList(data);
}

async function loadProjects() {
    const { data, error } = await sb
        .from('tally_projects')
        .select('*')
        .order('sort_order', { ascending: true })
        .order('name', { ascending: true });

    if (error) return showError('Could not load projects', error);
    renderProjects(data);
}

// ── Renderers ─────────────────────────────────────────────

function renderTriageList(containerId, rows, emptyText, opts = {}) {
    const container = el(containerId);
    container.innerHTML = '';
    if (!rows.length) {
        const d = document.createElement('div');
        d.className = 'empty';
        d.textContent = emptyText;
        container.appendChild(d);
        return;
    }
    for (const row of rows) container.appendChild(triageRow(row, opts));
}

function triageRow(row, { uncategorized } = {}) {
    const wrap = document.createElement('div');
    wrap.className = 'entry';

    const sig = document.createElement('div');
    if (uncategorized) {
        sig.className = 'signifier note untriaged';
    } else {
        sig.className = `signifier ${row.type}`;
    }
    wrap.appendChild(sig);

    const body = document.createElement('div');
    body.className = 'entry-body';

    const content = document.createElement('div');
    content.className = 'entry-content';
    content.textContent = row.content;
    body.appendChild(content);

    const meta = document.createElement('div');
    meta.className = 'entry-meta';
    meta.textContent = `${row.entry_date} · ${row.source}${row.priority ? ' · priority' : ''}`;
    body.appendChild(meta);

    const actions = document.createElement('div');
    actions.className = 'actions';

    if (uncategorized) {
        actions.appendChild(actionBtn('task',  'keep', () => categorizeAndKeep(row, 'task')));
        actions.appendChild(actionBtn('event', 'keep', () => categorizeAndKeep(row, 'event')));
        actions.appendChild(actionBtn('note',  'keep', () => categorizeAndKeep(row, 'note')));
        actions.appendChild(actionBtn('kill',  'kill', () => killEntry(row)));
    } else {
        actions.appendChild(actionBtn('keep open', 'keep',  () => keepOpen(row)));
        actions.appendChild(actionBtn('→ today',   'today', () => moveToToday(row)));
        actions.appendChild(actionBtn('done',      'done',  () => markDone(row)));
        actions.appendChild(actionBtn('kill',      'kill',  () => killEntry(row)));
    }
    body.appendChild(actions);

    if (row.priority) {
        const stamp = document.createElement('div');
        stamp.className = 'stamp';
        wrap.appendChild(stamp);
    }

    wrap.appendChild(body);
    return wrap;
}

function actionBtn(label, cls, onClick) {
    const btn = document.createElement('button');
    btn.className = `action-btn ${cls}`;
    btn.textContent = label;
    btn.addEventListener('click', onClick);
    return btn;
}

function renderTodayList(rows) {
    const container = el('todayList');
    container.innerHTML = '';
    if (!rows.length) {
        const d = document.createElement('div');
        d.className = 'empty';
        d.textContent = 'nothing logged yet today';
        container.appendChild(d);
        return;
    }
    for (const row of rows) {
        const wrap = document.createElement('div');
        wrap.className = `entry${row.status === 'done' ? ' done' : ''}`;

        const sig = document.createElement('div');
        sig.className = `signifier ${row.type}${row.status === 'done' ? ' done' : ''}`;
        wrap.appendChild(sig);

        const body = document.createElement('div');
        body.className = 'entry-body';
        const content = document.createElement('div');
        content.className = 'entry-content';
        content.textContent = row.content;
        body.appendChild(content);

        const actions = document.createElement('div');
        actions.className = 'actions';
        if (row.status === 'done') {
            actions.appendChild(actionBtn('undo', 'keep', () => reopenEntry(row)));
        } else {
            actions.appendChild(actionBtn('done', 'done', () => markDone(row)));
            actions.appendChild(actionBtn('kill', 'kill', () => killEntry(row)));
        }
        body.appendChild(actions);

        if (row.priority) {
            const stamp = document.createElement('div');
            stamp.className = 'stamp';
            wrap.appendChild(stamp);
        }
        wrap.appendChild(body);
        container.appendChild(wrap);
    }
}

function renderProjects(rows) {
    const container = el('projectList');
    container.innerHTML = '';
    if (!rows.length) {
        const d = document.createElement('div');
        d.className = 'empty';
        d.textContent = 'no projects yet';
        container.appendChild(d);
        return;
    }
    for (const p of rows) {
        const card = document.createElement('button');
        card.type = 'button';
        card.className = `project-card${p.blocked_on ? ' blocked' : ''}`;
        card.addEventListener('click', () => openProjectSheet(p));

        const name = document.createElement('div');
        name.className = 'project-name';
        name.textContent = p.name;
        card.appendChild(name);

        if (p.status_line) {
            const status = document.createElement('div');
            status.className = 'project-status';
            status.textContent = p.status_line;
            card.appendChild(status);
        }

        if (p.next_action) {
            const next = document.createElement('div');
            next.className = 'project-next';
            const label = document.createElement('span');
            label.className = 'label';
            label.textContent = 'next';
            next.appendChild(label);
            next.appendChild(document.createTextNode(p.next_action));
            card.appendChild(next);
        }

        if (p.blocked_on) {
            const blocked = document.createElement('div');
            blocked.className = 'project-blocked';
            blocked.textContent = `blocked — ${p.blocked_on}`;
            card.appendChild(blocked);
        }

        if (p.target_date) {
            const target = document.createElement('div');
            target.className = 'project-target';
            target.textContent = `target ${p.target_date}`;
            card.appendChild(target);
        }

        container.appendChild(card);
    }
}

// ── Entry actions ─────────────────────────────────────────
// Every write asserts on the returned rows. PostgREST answers a refused
// UPDATE with an empty result and no error, so "saved" and "silently
// refused" are indistinguishable without this check — open item 3 in
// docs/OPEN-ITEMS.md, and the reason this app checks from day one.

async function onSubmitEntry(e) {
    e.preventDefault();
    const content = el('contentInput').value.trim();
    if (!content) return;

    const { data, error } = await sb.from('tally_entries').insert({
        user_id: currentUserId,
        entry_date: TODAY,
        type: el('typeSelect').value,
        content,
        priority: el('priorityToggle').classList.contains('active'),
        status: 'open',
        source: 'manual'
    }).select();

    if (error) return showError('Entry not saved', error);
    if (!data || !data.length) return showError('Entry not saved — the write was refused.');

    el('contentInput').value = '';
    el('priorityToggle').classList.remove('active');
    el('priorityToggle').setAttribute('aria-pressed', 'false');
    el('contentInput').focus();
    await loadToday();
}

async function updateEntry(row, patch, failMsg) {
    const { data, error } = await sb
        .from('tally_entries')
        .update(patch)
        .eq('id', row.id)
        .select();

    if (error) { showError(failMsg, error); return false; }
    if (!data || !data.length) { showError(`${failMsg} — the write was refused.`); return false; }
    return true;
}

async function categorizeAndKeep(row, type) {
    if (!await updateEntry(row, { type, entry_date: TODAY }, 'Could not file that entry')) return;
    await Promise.all([loadRapidBucket(), loadToday()]);
}

function keepOpen(row) {
    // A deliberate no-op on the row: "keep open" means leave the date and the
    // status exactly where they are. It exists so the triage pass has an
    // explicit fourth disposition rather than an unanswered bullet. Nothing
    // is written, so nothing is reloaded — re-running the query here would
    // repaint an identical list and read as a failed tap.
}

async function moveToToday(row) {
    // status stays 'open'. The draft set it to 'migrated', which took the
    // entry out of the open-loops query (status = 'open') while moving it to
    // today — so a task pushed forward and not finished that day vanished
    // from the book entirely. 'migrated' describes how the bullet got here,
    // not whether it is still owed.
    if (!await updateEntry(row, { entry_date: TODAY, status: 'open' }, 'Could not move that entry')) return;
    await Promise.all([loadOpenLoops(), loadToday()]);
}

async function markDone(row) {
    if (!await updateEntry(row, { status: 'done' }, 'Could not mark that done')) return;
    await Promise.all([loadOpenLoops(), loadRapidBucket(), loadToday()]);
}

async function reopenEntry(row) {
    if (!await updateEntry(row, { status: 'open' }, 'Could not reopen that entry')) return;
    await loadToday();
}

async function killEntry(row) {
    // Soft. The draft DELETEd, which makes a mis-tap on a phone
    // unrecoverable; a struck-through bullet is what the paper book does.
    if (!await updateEntry(row, { status: 'killed' }, 'Could not strike that entry')) return;
    await Promise.all([loadOpenLoops(), loadRapidBucket(), loadToday()]);
}

// ── Project register ──────────────────────────────────────

let editingProject = null;

function openProjectSheet(p) {
    editingProject = p;
    el('projectSheetTitle').textContent = p.name;
    el('pfStatus').value  = p.status_line || '';
    el('pfNext').value    = p.next_action || '';
    el('pfBlocked').value = p.blocked_on || '';
    el('pfTarget').value  = p.target_date || '';
    el('pfError').textContent = '';
    el('projectSheet').hidden = false;
    el('pfStatus').focus();
}

function closeProjectSheet() {
    editingProject = null;
    el('projectSheet').hidden = true;
}

async function saveProject() {
    if (!editingProject) return;
    const btn = el('pfSave');
    btn.disabled = true;

    const blocked = el('pfBlocked').value.trim();
    const target = el('pfTarget').value;

    const { data, error } = await sb
        .from('tally_projects')
        .update({
            status_line: el('pfStatus').value.trim(),
            next_action: el('pfNext').value.trim(),
            // NULL, not '' — the card treats blocked_on as a flag, and an
            // empty string is truthy enough in SQL to keep a cleared project
            // showing as blocked forever.
            blocked_on: blocked || null,
            target_date: target || null
        })
        .eq('id', editingProject.id)
        .select();

    btn.disabled = false;

    if (error) { el('pfError').textContent = error.message; return; }
    if (!data || !data.length) { el('pfError').textContent = 'The write was refused.'; return; }

    closeProjectSheet();
    await loadProjects();
}
