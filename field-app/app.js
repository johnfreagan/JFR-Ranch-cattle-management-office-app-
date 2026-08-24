// =========================================================
// SUPABASE — the ranch books
// =========================================================
// The field app never writes to the books directly. Everything a cowboy
// saves lands in pending_field_entries (a staging table), and the office
// reviews and approves it before it becomes a real doctoring/death/move
// row. RLS enforces that: this app's token cannot write anywhere else.
//
// Replaces the old Google Apps Script transport. That one used
// mode:'no-cors', so it could not read the response and a rejected write
// looked exactly like a good one. This one sees real errors.
const SUPABASE_URL = 'https://xpfmebdzcxorvwikfvtj.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_LhyJ7-bxebSa7HuRTxjmBQ__73Oc-66';
const STAGING_TABLE = 'pending_field_entries';

// If the library did not load, say so plainly. Before this guard, this line
// threw and took the remaining ~2,200 lines of this file with it - including
// every event handler - so the page rendered normally and every button was
// simply inert, with nothing on screen to explain why.
if (!window.supabase || typeof window.supabase.createClient !== 'function') {
    if (window.__reportBootError) {
        window.__reportBootError('the Supabase library did not load. Tap "Reset app" below, ' +
                                 'or check your connection and reload.');
    }
    throw new Error('Supabase library not available');
}

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true }
});

// Set once a session is confirmed. Every staged row is stamped with this.
let currentUserId = null;
let currentProfile = null;

// --- UI ELEMENT SELECTORS ---
const doctoringTabBtn = document.getElementById('doctoringTabBtn');
const movesTabBtn = document.getElementById('movesTabBtn');
const historyTabBtn = document.getElementById('historyTabBtn');

const doctoringForm = document.getElementById('doctoringForm');
const movesForm = document.getElementById('movesForm');
const historySection = document.getElementById('historySection');

const recordTableBody = document.getElementById('recordTableBody');
const movesTableBody = document.getElementById('movesTableBody');
const tableContainer = document.getElementById('tableContainer'); 
const movesTableContainer = document.getElementById('movesTableContainer');

const syncCloudBtn = document.getElementById('syncCloudBtn');
const tagNumberInput = document.getElementById('tagNumber');
const tagAlert = document.getElementById('tagAlert'); 
const dateTimeInput = document.getElementById('dateTime');
const treatmentTypeInput = document.getElementById('treatmentType');
const submitBtn = document.getElementById('submitBtn'); 

const lotInput = document.getElementById('lotNumber');
const drugOffInput = document.getElementById('drugOff');
const propertyInput = document.getElementById('propertyInput');
const pastureInput = document.getElementById('pastureInput');
const medicationList = document.getElementById('medicationList');
const med1 = document.getElementById('medication1');
const dose1 = document.getElementById('dosage1');
const med2 = document.getElementById('medication2');
const dose2 = document.getElementById('dosage2');
const med3 = document.getElementById('medication3');
const dose3 = document.getElementById('dosage3');

const recordedByInput = document.getElementById('recordedBy'); 
const moveRecordedByInput = document.getElementById('moveRecordedBy'); 
const noTagBtn = document.getElementById('noTagBtn'); 
const clearTagBtn = document.getElementById('clearTagBtn'); 

// --- APP DATABASES ---
// Reading saved state must never be able to stop the app booting. A value
// that will not parse is discarded and the default used instead: losing a
// cached lookup is recoverable with one Pull, losing the whole app is not.
function loadJSON(key, fallback) {
    let raw;
    try { raw = localStorage.getItem(key); } catch (e) { return fallback; }
    if (raw === null || raw === undefined || raw === '') return fallback;
    try {
        const parsed = JSON.parse(raw);
        return (parsed === null || parsed === undefined) ? fallback : parsed;
    } catch (e) {
        console.warn(`Discarding corrupt localStorage value for ${key}:`, raw && raw.slice(0, 80));
        try { localStorage.removeItem(key); } catch (e2) {}
        return fallback;
    }
}

let records = loadJSON('betaCattleRecords', []);
let movesRecords = loadJSON('betaCattleMoves', []);
let medsDatabase = loadJSON('betaCattleMeds', []);
let locsDatabase = loadJSON('betaCattleLocs', []);
let lotsDatabase = loadJSON('betaCattleLots', []);
let protocolsDatabase = loadJSON('betaCattleProtocols', []);

// Treatments already in the ranch books (doctoring_events), as opposed to
// `records`, which is what THIS app has submitted. Kept separate on purpose:
// these are read-only reference rows and must never be editable, deletable
// or re-submittable from the field app. Tag recall and the safety checks
// consult both; everything that writes only ever touches `records`.
let booksHistory = loadJSON('betaCattleBooksHistory', []);

// tag number -> "Ranch - Pasture", only for tags whose location is actually
// knowable from the books. See the resolution rules in pullCloudData().
let tagLocationMap = loadJSON('betaCattleTagLocations', {});

// tag number -> lot number, straight from lot_tags. This is the ONLY
// reliable tag->lot mapping: lots.start_tag/end_tag covers 100 of 1,782
// open tags (most lots have no range at all, and hundreds of tags sit
// outside their lot's range), so the range is a last-ditch fallback only.
let tagLotMap = loadJSON('betaCattleTagLots', {});

// Per-receipt tag ranges, for a tag that is physically in the pasture but not
// registered in lot_tags yet.
let tagRanges = loadJSON('betaCattleTagRanges', []);

// One place that answers "which lot is this tag on", best source first.
function resolveLotForTag(tag) {
    const key = String(tag).trim();
    if (!key) return '';
    // 1. Registered in lot_tags - authoritative.
    if (tagLotMap[key]) return tagLotMap[key];
    const n = parseInt(key, 10);
    if (isNaN(n)) return '';
    // 2. Inside a delivery receipt's tag range.
    const hit = tagRanges.find(r => n >= r.start && n <= r.end);
    if (hit) return hit.lotNumber;
    // 3. lots.start_tag/end_tag - first load only, so genuinely last resort.
    const lot = lotsDatabase.find(l =>
        l.startTag != null && l.endTag != null && n >= parseInt(l.startTag) && n <= parseInt(l.endTag));
    return lot ? lot.lotNumber : '';
}

// Every read-only lookup by tag must see the books as well as this phone's
// own submissions, otherwise an animal treated last month looks brand new.
function historyPool() {
    return records.concat(booksHistory);
}

let currentEstWeight = 0; 
let editingRecordId = null;
let editingMoveId = null;
let deleteTimers = {}; 

// --- SYNC QUEUE & TOMBSTONES (offline resilience) ---
const SYNC_QUEUE_KEY = 'betaCattleSyncQueue';
const TOMBSTONES_KEY = 'betaCattleTombstones';
const REJECTED_KEY = 'betaCattleRejected';
let syncQueue = loadJSON(SYNC_QUEUE_KEY, []);
let tombstones = loadJSON(TOMBSTONES_KEY, {});
let isSyncingQueue = false;
const MAX_SYNC_ATTEMPTS = 25;   // ~25 min of retries before we call it dead
let isSubmittingDoctoring = false;
let isSubmittingMove = false;

// --- FIELD LOCKS (sticky fields for chute work) ---
const LOCKS_KEY = 'betaCattleLocks';
let locks = loadJSON(LOCKS_KEY, { ranch: false, pasture: false, lot: false, action: false });
// Pasture locked without ranch is invalid — repair stale state from older versions
if (locks.pasture && !locks.ranch) locks.ranch = true;

// Drug-off group reference (drugOffInput already declared above in selectors block)
const drugOffGroup = document.getElementById('drugOffGroup');

// =========================================================
// REMEMBER ME (CREW MEMBER SYNC)
// =========================================================
const savedName = localStorage.getItem('crewMemberName') || '';
recordedByInput.value = savedName;
moveRecordedByInput.value = savedName;

recordedByInput.addEventListener('input', (e) => moveRecordedByInput.value = e.target.value);
moveRecordedByInput.addEventListener('input', (e) => recordedByInput.value = e.target.value);

// =========================================================
// TOAST NOTIFICATIONS (replace alert for hot-path messages)
// =========================================================
function showToast(message, type = 'success', duration = 2000) {
    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    toast.textContent = message;
    document.body.appendChild(toast);

    // Haptic feedback where available (Android; iOS Safari ignores but harmless)
    try {
        if (navigator.vibrate) {
            navigator.vibrate(type === 'error' ? [50, 40, 50] : 30);
        }
    } catch (e) { /* no-op */ }

    // Force reflow then animate in
    requestAnimationFrame(() => toast.classList.add('show'));
    setTimeout(() => {
        toast.classList.remove('show');
        setTimeout(() => toast.remove(), 300);
    }, duration);
}

// =========================================================
// SYNC QUEUE — all writes go through here instead of fire-and-forget
// =========================================================
// =========================================================
// SAFE localStorage WRAPPER
// Browsers throw QuotaExceededError when the ~5MB cap is hit.
// On failure we prune old records and retry, then show a toast.
// =========================================================
let _storageWarned = false;

function pruneOldRecords() {
    // Drop doctoring records older than 60 days; cloud has the archive.
    const cutoff = Date.now() - (60 * 24 * 60 * 60 * 1000);
    const before = records.length;
    records = records.filter(r => {
        if (!r.dateTime) return true;
        const t = new Date(String(r.dateTime).split('T')[0]).getTime();
        return isNaN(t) || t >= cutoff;
    });
    const moveBefore = movesRecords.length;
    movesRecords = movesRecords.filter(m => {
        if (!m.date) return true;
        const t = new Date(String(m.date).split('T')[0]).getTime();
        return isNaN(t) || t >= cutoff;
    });
    return (before - records.length) + (moveBefore - movesRecords.length);
}

function safeSetItem(key, value) {
    try {
        localStorage.setItem(key, value);
        return true;
    } catch (err) {
        const isQuota = err && (err.name === 'QuotaExceededError' || err.code === 22 || err.code === 1014);
        if (!isQuota) {
            console.error('localStorage error:', err);
            if (!_storageWarned) {
                showToast('⚠ Storage error — record may not persist', 'error', 3500);
                _storageWarned = true;
            }
            return false;
        }
        const pruned = pruneOldRecords();
        try {
            localStorage.setItem('betaCattleRecords', JSON.stringify(records));
            localStorage.setItem('betaCattleMoves',   JSON.stringify(movesRecords));
            localStorage.setItem(key, value);
            showToast(`⚠ Storage full — pruned ${pruned} old records`, 'error', 4000);
            return true;
        } catch (err2) {
            console.error('localStorage still failing after prune:', err2);
            if (!_storageWarned) {
                showToast('🛑 Storage full. Pull Cloud, then clear app data.', 'error', 5000);
                _storageWarned = true;
            }
            return false;
        }
    }
}

function saveQueue() {
    safeSetItem(SYNC_QUEUE_KEY, JSON.stringify(syncQueue));
}

function saveTombstones() {
    safeSetItem(TOMBSTONES_KEY, JSON.stringify(tombstones));
}

function enqueueForSync(payload) {
    // De-dupe: drop any earlier queued entry for the same id.
    // The newest version of a record supersedes older ones, including
    // a delete superseding a previous save.
    if (payload && payload.id) {
        const targetId = String(payload.id);
        const before = syncQueue.length;
        syncQueue = syncQueue.filter(q => String(q.id) !== targetId);
        if (before !== syncQueue.length) {
            console.log(`Sync queue: superseded ${before - syncQueue.length} stale entry for id ${targetId}`);
        }
    }
    syncQueue.push({ ...payload, _attempts: 0, _queuedAt: Date.now() });
    saveQueue();
    updateSyncBadge();
    if (navigator.onLine) {
        processSyncQueue();
    }
}

// Anything that is not a transport failure is the database refusing the
// row on its merits (RLS, a check constraint, a bad FK). Retrying that
// forever just burns battery on a phone in a pasture, so those are
// dropped from the queue and surfaced instead. Only genuine network
// failures stay queued.
const PERMANENT_PG_CODES = [
    '42501',  // RLS / insufficient privilege
    '23514',  // check constraint (bad entry_type, bad status, negative head)
    '23503',  // FK violation
    '23502',  // not-null violation
    '22P02',  // malformed input (bad uuid/timestamp)
    'P0001'   // our own guard triggers (pfe_settled / pfe_status)
];

// "2026-08-24T14:32:01" carries no zone. new Date() reads that DATE-TIME
// form as LOCAL time, which is what the cowboy meant, and toISOString()
// converts it to UTC correctly for a timestamptz column.
//
// A DATE-ONLY string is the trap: JS parses "2026-08-24" as UTC midnight,
// not local midnight. In Texas that is 7pm the PREVIOUS day, so a move
// would show up in the office dated a day early. Moves carry a bare date,
// so pin those to local midnight explicitly.
function toIsoOrNull(value) {
    if (!value) return null;
    const str = String(value);
    const dateOnly = /^\d{4}-\d{2}-\d{2}$/.test(str);
    const d = new Date(dateOnly ? str + 'T00:00:00' : str);
    return isNaN(d.getTime()) ? null : d.toISOString();
}

// Map a field payload onto the staging row. `raw` is the payload verbatim
// and is never edited — the office resolves lot/pasture/action/meds at
// review time against live data, so the client deliberately does NOT
// guess at those foreign keys here.
function toStagingRow(record) {
    const isMove = record.type === 'move';
    const tag = String(record.tagNumber || '').trim();
    return {
        entry_type: isMove ? 'move' : 'doctoring',
        client_id: String(record.id),
        raw: record,
        tag_number: isMove ? null : (tag || null),
        no_tag: !isMove && /^NT\d*$/i.test(tag),
        event_datetime: toIsoOrNull(isMove ? record.date : record.dateTime),
        head_count: isMove ? (parseInt(record.headCount, 10) || 0) : null,
        submitted_by: currentUserId,
        status: 'pending'
    };
}

// Returns true when the item can leave the queue (delivered, or rejected
// on its merits and reported), false to keep it queued for another try.
async function sendOne(payload) {
    if (!currentUserId) return false;   // not signed in yet; stay queued

    const { _attempts, _queuedAt, ...record } = payload;

    try {
        let error;

        if (record.action === 'delete') {
            // A record the cowboy deleted in the field. Withdraw it so it
            // stops showing up in the office queue as something live.
            // Guarded to status='pending' so a withdrawal that arrives
            // after the office already approved it cannot take it back.
            ({ error } = await sb
                .from(STAGING_TABLE)
                .update({ status: 'withdrawn' })
                .eq('entry_type', record.type === 'move' ? 'move' : 'doctoring')
                .eq('client_id', String(record.id))
                .eq('status', 'pending'));
        } else {
            // Upsert, not insert: the app lets a cowboy edit a saved
            // record and re-queues it under the SAME id, so the second
            // delivery has to update the staged row rather than collide.
            ({ error } = await sb
                .from(STAGING_TABLE)
                .upsert(toStagingRow(record), { onConflict: 'entry_type,client_id' }));
        }

        if (!error) return true;

        if (PERMANENT_PG_CODES.includes(error.code)) {
            recordRejection(record, error);
            return true;    // stop retrying; it will never succeed
        }

        console.warn('sendOne transient error:', error);
        return false;       // server hiccup / offline — try again later
    } catch (err) {
        console.warn('sendOne network error:', err);
        return false;
    }
}

// A rejected record must never disappear quietly — the cowboy needs to
// know the save did not stick.
function recordRejection(record, error) {
    console.error('Record rejected by server:', record, error);
    const rejects = loadJSON(REJECTED_KEY, []);
    rejects.unshift({
        id: String(record.id),
        type: record.type || 'doctoring',
        tag: record.tagNumber || record.fromPasture || '',
        reason: error.message || String(error.code || 'unknown'),
        at: new Date().toISOString()
    });
    safeSetItem(REJECTED_KEY, JSON.stringify(rejects.slice(0, 50)));
    showToast(`\u26d4 Save rejected: ${error.message || error.code}`, 'error', 6000);
}

async function processSyncQueue() {
    if (isSyncingQueue) return;
    if (!navigator.onLine) { updateSyncBadge(); return; }
    if (syncQueue.length === 0) { updateSyncBadge(); return; }

    isSyncingQueue = true;
    updateSyncBadge();

    // Snapshot & drain
    const pending = [...syncQueue];
    const stillFailed = [];

    for (const item of pending) {
        const ok = await sendOne(item);
        if (!ok) {
            item._attempts = (item._attempts || 0) + 1;
            // Backstop. _attempts was counted but never checked before,
            // which was harmless when every send reported success. Now a
            // record that keeps failing transiently would otherwise retry
            // every 60s forever.
            if (item._attempts >= MAX_SYNC_ATTEMPTS) {
                recordRejection(item, { message: `gave up after ${item._attempts} attempts` });
            } else {
                stillFailed.push(item);
            }
        }
    }

    syncQueue = stillFailed;
    saveQueue();
    isSyncingQueue = false;
    updateSyncBadge();

    if (stillFailed.length === 0 && pending.length > 0) {
        showToast('☁️ All records synced', 'success', 1500);
    }
}

function updateSyncBadge() {
    // The queue drains on a timer; if the troubleshooting modal is open the
    // reset gate should unblock itself rather than needing a reopen.
    // Looked up directly rather than via the `troubleModal` const: that const
    // is declared far below this function, so touching it here would be a
    // temporal-dead-zone throw if the call order ever changes.
    const tm = document.getElementById('troubleModal');
    if (tm && tm.style.display === 'block') refreshResetState();

    const badge = document.getElementById('syncBadge');
    if (!badge) return;
    const n = syncQueue.length;
    if (n === 0 && navigator.onLine) {
        badge.style.display = 'none';
    } else if (!navigator.onLine) {
        badge.style.display = 'inline-block';
        badge.className = 'sync-badge offline';
        badge.textContent = n > 0 ? `⚠ Offline · ${n} pending` : '⚠ Offline';
    } else {
        badge.style.display = 'inline-block';
        badge.className = isSyncingQueue ? 'sync-badge syncing' : 'sync-badge pending';
        badge.textContent = isSyncingQueue ? `⏳ Syncing ${n}…` : `⏳ ${n} pending`;
    }
}

// Retry triggers
window.addEventListener('online', () => { updateSyncBadge(); processSyncQueue(); });
window.addEventListener('offline', updateSyncBadge);
window.addEventListener('focus', () => { if (navigator.onLine) processSyncQueue(); });
setInterval(() => { if (navigator.onLine) processSyncQueue(); }, 60000);

// =========================================================
// LONG-PRESS TOOLTIPS (touch fallback for desktop hover tooltips)
// Hold any element with a `title` attribute for ~500ms to see it
// without firing the underlying tap.
// =========================================================
(function() {
    let pressTimer = null;
    let suppressTap = false;
    let activeTooltip = null;

    function clearTooltip() {
        if (activeTooltip) {
            activeTooltip.remove();
            activeTooltip = null;
        }
    }

    function showTooltipFor(el, x, y) {
        const text = el.getAttribute('title') || el.getAttribute('aria-label');
        if (!text) return;

        clearTooltip();

        // Hide native title temporarily so iOS doesn't double-show it
        el.dataset._title = text;
        el.removeAttribute('title');

        const tip = document.createElement('div');
        tip.className = 'longpress-tooltip';
        tip.textContent = text;
        document.body.appendChild(tip);
        activeTooltip = tip;

        // Position above the touch point, clamped to viewport
        const tipW = tip.offsetWidth;
        const tipH = tip.offsetHeight;
        let left = x - tipW / 2;
        let top = y - tipH - 14;
        if (left < 8) left = 8;
        if (left + tipW > window.innerWidth - 8) left = window.innerWidth - tipW - 8;
        if (top < 8) top = y + 18; // flip below if no room above
        tip.style.left = left + 'px';
        tip.style.top  = top + 'px';

        if (navigator.vibrate) { try { navigator.vibrate(15); } catch(e){} }

        // Restore the title attribute when the tooltip is dismissed
        setTimeout(() => {
            if (el.dataset._title) {
                el.setAttribute('title', el.dataset._title);
                delete el.dataset._title;
            }
        }, 100);
    }

    function findTooltipTarget(target) {
        // Walk up looking for an element with title or aria-label
        let el = target;
        while (el && el !== document.body) {
            if (el.getAttribute && (el.getAttribute('title') || el.getAttribute('aria-label'))) {
                return el;
            }
            el = el.parentElement;
        }
        return null;
    }

    document.addEventListener('touchstart', (e) => {
        const el = findTooltipTarget(e.target);
        if (!el) return;
        const touch = e.touches[0];
        const x = touch.clientX, y = touch.clientY;
        suppressTap = false;
        pressTimer = setTimeout(() => {
            suppressTap = true;
            showTooltipFor(el, x, y);
        }, 500);
    }, { passive: true });

    function cancelPress() {
        if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; }
    }

    document.addEventListener('touchmove', cancelPress, { passive: true });
    document.addEventListener('touchend', () => {
        cancelPress();
        // Dismiss tooltip on next tap anywhere
        if (activeTooltip) {
            setTimeout(clearTooltip, 1500);
        }
    }, { passive: true });
    document.addEventListener('touchcancel', () => { cancelPress(); clearTooltip(); }, { passive: true });

    // Suppress the click that would fire after a long-press
    document.addEventListener('click', (e) => {
        if (suppressTap) {
            e.preventDefault();
            e.stopPropagation();
            suppressTap = false;
        }
    }, true);

    // Tap anywhere to dismiss an active tooltip
    document.addEventListener('click', () => clearTooltip());
})();

// =========================================================
// SERVICE WORKER REGISTRATION (offline PWA)
// =========================================================
if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
        navigator.serviceWorker.register('./sw.js')
            .catch(err => console.warn('SW registration failed:', err));
    });
}

// =========================================================
// FIELD LOCKS — sticky ranch/pasture/lot/action across saves
// =========================================================
function saveLocks() {
    safeSetItem(LOCKS_KEY, JSON.stringify(locks));
}

function renderLockButton(btn, field) {
    if (locks[field]) {
        btn.classList.add('locked');
        btn.textContent = '🔒';
        btn.setAttribute('aria-label', `Unlock ${field}`);
    } else {
        btn.classList.remove('locked');
        btn.textContent = '🔓';
        btn.setAttribute('aria-label', `Lock ${field}`);
    }
}

function wireLockButton(id, field) {
    const btn = document.getElementById(id);
    if (!btn) return;
    renderLockButton(btn, field);
    btn.addEventListener('click', () => {
        // Pasture can't be locked without Ranch — they're a hierarchy.
        // Tap pasture lock (off) → lock both. Tap ranch lock (on) → unlock both.
        if (field === 'pasture' && !locks.pasture) {
            locks.ranch = true;
            locks.pasture = true;
        } else if (field === 'ranch' && locks.ranch) {
            locks.ranch = false;
            locks.pasture = false; // pasture can't stay locked alone
        } else {
            locks[field] = !locks[field];
        }
        saveLocks();

        // Re-render any lock button that may have changed state
        renderLockButton(document.getElementById('lockRanchBtn'),   'ranch');
        renderLockButton(document.getElementById('lockPastureBtn'), 'pasture');
        renderLockButton(document.getElementById('lockLotBtn'),     'lot');
        renderLockButton(document.getElementById('lockActionBtn'),  'action');

        updateChuteBanner();

        if (navigator.vibrate) { try { navigator.vibrate(20); } catch(e){} }
    });
}

wireLockButton('lockRanchBtn', 'ranch');
wireLockButton('lockPastureBtn', 'pasture');
wireLockButton('lockLotBtn', 'lot');
wireLockButton('lockActionBtn', 'action');

// Restore locked values to the form after a reset
function restoreLockedValues(snapshot) {
    if (snapshot.ranch) {
        propertyInput.value = snapshot.ranch;
        // Populate the pasture dropdown for the restored ranch
        propertyInput.dispatchEvent(new Event('change'));
    }
    if (snapshot.pasture) {
        // Make sure the option exists in the dropdown
        let exists = Array.from(pastureInput.options).some(o => o.value === snapshot.pasture);
        if (!exists) {
            pastureInput.innerHTML += `<option value="${snapshot.pasture}">${snapshot.pasture}</option>`;
        }
        pastureInput.value = snapshot.pasture;
        pastureInput.disabled = false;
    }
    if (snapshot.lot) {
        let exists = Array.from(lotInput.options).some(o => o.value === snapshot.lot);
        if (!exists) {
            lotInput.innerHTML += `<option value="${snapshot.lot}">${snapshot.lot}</option>`;
        }
        lotInput.value = snapshot.lot;
    }
    if (snapshot.action) {
        treatmentTypeInput.disabled = false;
        treatmentTypeInput.value = snapshot.action;
        // Defensive: explicitly mark the option selected too, in case .value alone
        // doesn't update the displayed text on some mobile browsers
        Array.from(treatmentTypeInput.options).forEach(o => {
            o.selected = (o.value === snapshot.action);
        });
        // Fire the change handler so medications auto-fill from the protocol
        treatmentTypeInput.dispatchEvent(new Event('change'));
    }
}

function snapshotLockedValues() {
    return {
        ranch:   locks.ranch   ? propertyInput.value      : '',
        pasture: locks.pasture ? pastureInput.value       : '',
        lot:     locks.lot     ? lotInput.value           : '',
        action:  locks.action  ? treatmentTypeInput.value : ''
    };
}

// Visible banner showing what's locked — gives confidence that autofill is correct
function updateChuteBanner() {
    const banner = document.getElementById('chuteBanner');
    if (!banner) return;
    const anyLocked = locks.ranch || locks.pasture || locks.lot || locks.action;
    if (!anyLocked) {
        banner.style.display = 'none';
        return;
    }
    const parts = [];
    if (locks.ranch && propertyInput.value)        parts.push(propertyInput.value);
    if (locks.pasture && pastureInput.value)       parts.push(pastureInput.value);
    if (locks.lot && lotInput.value)               parts.push(`Lot ${lotInput.value}`);
    if (locks.action && treatmentTypeInput.value)  parts.push(treatmentTypeInput.value);
    banner.innerHTML = `<span class="chute-banner-icon">🔒</span> Chute mode: <b>${parts.length ? parts.join(' · ') : 'set fields, then they will stick'}</b>`;
    banner.style.display = 'flex';
}

// =========================================================
// CUSTOM NUMERIC KEYPAD — replaces iOS keyboard for tag entry
// Avoids viewport-jump and predictive-text interference.
// =========================================================
const keypadModal = document.getElementById('keypadModal');
const keypadDisplay = document.getElementById('keypadDisplay');
let keypadBuffer = '';

function openKeypad() {
    keypadBuffer = tagNumberInput.value || '';
    renderKeypadDisplay();
    keypadModal.classList.add('show');
}

function closeKeypad() {
    keypadModal.classList.remove('show');
    // Commit final value and trigger the same input handler the form already uses
    tagNumberInput.value = keypadBuffer;
    tagNumberInput.dispatchEvent(new Event('input'));
}
window.closeKeypad = closeKeypad;

function renderKeypadDisplay() {
    keypadDisplay.textContent = keypadBuffer === '' ? '—' : keypadBuffer;
    // Live-update underlying input + alert box so locks/lot/etc. respond as you type
    tagNumberInput.value = keypadBuffer;
    tagNumberInput.dispatchEvent(new Event('input'));
}

document.querySelectorAll('.keypad-key').forEach(btn => {
    btn.addEventListener('click', () => {
        const k = btn.dataset.k;
        if (navigator.vibrate) { try { navigator.vibrate(10); } catch(e){} }
        if (k === 'clear') {
            keypadBuffer = '';
        } else if (k === 'back') {
            keypadBuffer = keypadBuffer.slice(0, -1);
        } else if (keypadBuffer.length < 8) {
            keypadBuffer += k;
        }
        renderKeypadDisplay();
    });
});

// Open the keypad when the user taps the tag input (input is readonly so the OS keyboard won't show)
// On desktop / hardware-keyboard devices, leave the input editable and skip the keypad entirely.
const isTouchPrimary = window.matchMedia && window.matchMedia('(pointer: coarse)').matches;

if (isTouchPrimary) {
    tagNumberInput.addEventListener('focus', openKeypad);
    tagNumberInput.addEventListener('click', openKeypad);
} else {
    // Desktop: allow typing directly. Drop readonly so keyboard input works.
    tagNumberInput.removeAttribute('readonly');
    tagNumberInput.placeholder = 'Type tag…';
    tagNumberInput.setAttribute('inputmode', 'numeric');
}

// Backdrop tap closes the keypad
keypadModal.addEventListener('click', (e) => {
    if (e.target === keypadModal) closeKeypad();
});

// Keyboard shortcuts (desktop or with bluetooth keyboard)
document.addEventListener('keydown', (e) => {
    if (keypadModal.classList.contains('show')) {
        if (e.key === 'Enter' || e.key === 'Escape') {
            e.preventDefault();
            closeKeypad();
        }
    }
});

// =========================================================
// DITTO BUTTON — fills tag with the most recently saved tag
// =========================================================
const dittoTagBtn = document.getElementById('dittoTagBtn');
if (dittoTagBtn) {
    dittoTagBtn.addEventListener('click', () => {
        // Last non-empty tag from records (records are sorted newest first)
        const last = records.find(r => r.tagNumber && String(r.tagNumber).trim() !== '');
        if (!last) {
            showToast('No previous tag to copy', 'error', 1500);
            return;
        }
        tagNumberInput.value = String(last.tagNumber);
        tagNumberInput.dispatchEvent(new Event('input'));
        showToast(`↺ Tag ${last.tagNumber}`, 'success', 1200);
    });
}

// =========================================================
// DAILY SUMMARY BAR — running tally for today + last save
// =========================================================
function updateDailySummary() {
    const bar = document.getElementById('dailySummary');
    if (!bar) return;

    const todayStr = new Date().toISOString().split('T')[0];
    const todays = records.filter(r => String(r.dateTime || '').startsWith(todayStr));
    const todayMoves = movesRecords.filter(m => String(m.date || '').startsWith(todayStr));

    if (todays.length === 0 && todayMoves.length === 0) {
        bar.style.display = 'none';
        return;
    }

    let firstPull = 0, secondPull = 0, dead = 0, other = 0;
    todays.forEach(r => {
        const t = String(r.treatmentType || '').toLowerCase();
        if (t.includes('1st') || t.includes('first')) firstPull++;
        else if (t.includes('2nd') || t.includes('second')) secondPull++;
        else if (t.includes('dead')) dead++;
        else other++;
    });

    // Find most recent save (records sorted newest first)
    const last = todays[0];
    let lastLine = '';
    if (last) {
        const tag = last.tagNumber || 'NT';
        const time = String(last.dateTime || '').split('T')[1] || '';
        const hhmm = time.slice(0, 5);
        lastLine = `Last: Tag ${tag} at ${hhmm}`;
    }

    const parts = [];
    if (firstPull) parts.push(`${firstPull} 1st`);
    if (secondPull) parts.push(`${secondPull} 2nd`);
    if (dead) parts.push(`<span style="color:#d70015;">${dead} dead</span>`);
    if (other) parts.push(`${other} other`);
    if (todayMoves.length) parts.push(`${todayMoves.length} move${todayMoves.length > 1 ? 's' : ''}`);

    bar.innerHTML = `
        <div class="ds-row ds-top">
            <span class="ds-count">${todays.length}</span>
            <span class="ds-label">treated today</span>
        </div>
        <div class="ds-row ds-mid">${parts.join(' · ')}</div>
        ${lastLine ? `<div class="ds-row ds-last">${lastLine}</div>` : ''}
    `;
    bar.style.display = 'block';
}

// =========================================================
// 3-TAB SWITCHING LOGIC
// =========================================================
function switchTab(tabName) {
    doctoringTabBtn.classList.remove('active');
    movesTabBtn.classList.remove('active');
    historyTabBtn.classList.remove('active');
    
    doctoringForm.style.display = 'none';
    movesForm.style.display = 'none';
    historySection.style.display = 'none';

    if (tabName === 'doctoring') {
        doctoringTabBtn.classList.add('active');
        doctoringForm.style.display = 'block';
    } 
    else if (tabName === 'moves') {
        movesTabBtn.classList.add('active');
        movesForm.style.display = 'block';
        populateMoveDropdowns();
        if(!editingMoveId) document.getElementById('moveDate').valueAsDate = new Date();
    } 
    else if (tabName === 'history') {
        historyTabBtn.classList.add('active');
        historySection.style.display = 'block';
        updateRecentList();
        updateMovesList();
        document.getElementById('searchInput').value = '';
    }
}

doctoringTabBtn.onclick = () => switchTab('doctoring');
movesTabBtn.onclick = () => switchTab('moves');
historyTabBtn.onclick = () => switchTab('history');

// =========================================================
// DAILY AUTO-SYNC LOGIC
// =========================================================
// Bump whenever a release starts caching something new. A device that
// synced under an older schema has a current betaLastSyncDate but is
// missing the new data entirely, and would otherwise sit there looking
// synced while tag lookups quietly returned nothing.
const DATA_SCHEMA_VERSION = 3;

function checkDailySync() {
    const lastSync = localStorage.getItem('betaLastSyncDate');
    const today = new Date().toISOString().split('T')[0];
    const storedSchema = parseInt(localStorage.getItem('betaCattleDataVersion'), 10);

    // Everything the doctoring form needs before it can answer a tag.
    // Checking only records/locsDatabase was the gap: those survive from an
    // older build while the tag maps do not exist at all.
    const missingData =
        locsDatabase.length === 0 ||
        lotsDatabase.length === 0 ||
        Object.keys(tagLotMap).length === 0 ||
        tagRanges.length === 0;

    if (missingData || storedSchema !== DATA_SCHEMA_VERSION || lastSync !== today) {
        syncCloudBtn.innerText = "⏳ Auto-Syncing Daily Data...";
        pullCloudData();
    }
}

// =========================================================
// MOVES FORM LOGIC (ADD / EDIT)
// =========================================================
function populateMoveDropdowns() {
    const fromRanch = document.getElementById('moveFromRanch');
    const toRanch = document.getElementById('moveToRanch');
    const validLocs = locsDatabase.filter(l => l && l.property);
    const uniqueProps = [...new Set(validLocs.map(l => String(l.property).trim()))].sort();
    const optionsHtml = '<option value="" disabled selected>Select Ranch...</option>'
        + uniqueProps.map(p => `<option value="${p}">${p}</option>`).join('');
    
    [fromRanch, toRanch].forEach(select => {
        const currentVal = select.value;
        select.innerHTML = optionsHtml;
        select.value = currentVal;
    });
}

document.getElementById('moveFromRanch').onchange = function() { updateMovePastures(this.value, 'moveFromPasture'); };
document.getElementById('moveToRanch').onchange = function() { updateMovePastures(this.value, 'moveToPasture'); };

function updateMovePastures(prop, targetId) {
    const target = document.getElementById(targetId);
    target.disabled = false;
    
    if (!prop) {
        target.innerHTML = '<option value="" disabled selected>Select Pasture...</option>';
        return;
    }

    const pastures = locsDatabase
        .filter(l => l.property && String(l.property).trim() === String(prop).trim())
        .map(l => String(l.pasture).trim())
        .sort();
        
    const uniquePastures = [...new Set(pastures)];
    target.innerHTML = '<option value="" disabled selected>Select Pasture...</option>'
        + uniquePastures.map(p => `<option value="${p}">${p}</option>`).join('');
}

movesForm.addEventListener('submit', function(e) {
    e.preventDefault();

    if (isSubmittingMove) return;
    
    const count = document.getElementById('moveHeadCount').value;
    const fromR = document.getElementById('moveFromRanch').value;
    const fromP = document.getElementById('moveFromPasture').value;
    const toR = document.getElementById('moveToRanch').value;
    const toP = document.getElementById('moveToPasture').value;

    if (fromR === toR && fromP === toP) {
        showToast("🛑 From/To pastures are the same", 'error', 3000);
        return; 
    }

    const moveData = {
        type: 'move',
        id: editingMoveId || "M-" + Date.now(),
        date: document.getElementById('moveDate').value,
        fromRanch: fromR,
        fromPasture: fromP,
        toRanch: toR,
        toPasture: toP,
        headCount: count || "0",
        notes: document.getElementById('moveNotes').value,
        recordedBy: moveRecordedByInput.value.trim()
    };

    const countMsg = count ? `${count} Head` : "Uncounted Head";
    if(!confirm(`Confirm Move:\n${countMsg}\nFrom: ${fromP}\nTo: ${toP}`)) return;

    const saveMoveBtn = document.getElementById('saveMoveBtn');
    isSubmittingMove = true;
    saveMoveBtn.disabled = true;
    saveMoveBtn.style.opacity = '0.6';

    if (editingMoveId) {
        movesRecords = movesRecords.map(m => String(m.id) === String(editingMoveId) ? moveData : m);
        editingMoveId = null;
        saveMoveBtn.innerText = "Save Move";
        saveMoveBtn.style.backgroundColor = "#5856d6";
    } else {
        movesRecords.unshift(moveData);
    }

    safeSetItem('betaCattleMoves', JSON.stringify(movesRecords));
    safeSetItem('crewMemberName', moveRecordedByInput.value.trim());

    pushToCloud(moveData);
    showToast(`🚚 Move saved: ${fromP} → ${toP}`, 'success', 2000);
    updateDailySummary();
    movesForm.reset();
    document.getElementById('moveDate').valueAsDate = new Date();
    moveRecordedByInput.value = localStorage.getItem('crewMemberName'); 

    setTimeout(() => {
        isSubmittingMove = false;
        saveMoveBtn.disabled = false;
        saveMoveBtn.style.opacity = '1';
    }, 600);
});

window.editMoveLocal = function(id) {
    const m = movesRecords.find(rec => String(rec.id) === String(id));
    if (!m) return;
    
    editingMoveId = String(id);
    switchTab('moves'); 
    
    document.getElementById('moveDate').value = m.date ? String(m.date).split('T')[0] : '';
    
    if (m.fromRanch) {
        document.getElementById('moveFromRanch').value = String(m.fromRanch).trim();
        updateMovePastures(String(m.fromRanch).trim(), 'moveFromPasture');
        document.getElementById('moveFromPasture').value = String(m.fromPasture).trim();
    }
    
    if (m.toRanch) {
        document.getElementById('moveToRanch').value = String(m.toRanch).trim();
        updateMovePastures(String(m.toRanch).trim(), 'moveToPasture');
        document.getElementById('moveToPasture').value = String(m.toPasture).trim();
    }
    
    document.getElementById('moveHeadCount').value = m.headCount || "";
    document.getElementById('moveNotes').value = m.notes || "";
    
    document.getElementById('saveMoveBtn').innerText = "Update Move Record";
    document.getElementById('saveMoveBtn').style.backgroundColor = "#ffcc00"; 
    
    window.scrollTo({ top: 0, behavior: 'smooth' });
};

// =========================================================
// UNIVERSAL DELETE LOGIC
// =========================================================
window.confirmDelete = function(id, type) {
    const stringId = String(id);
    const delBtn = document.getElementById(`del-${stringId}`);
    if (!delBtn) return;

    // If confirm UI is already showing for this row, ignore further Del taps
    if (delBtn.dataset.confirming === '1') return;

    const actionCell = delBtn.parentElement;
    delBtn.dataset.confirming = '1';
    delBtn.style.display = 'none';

    const confirmBtn = document.createElement('button');
    confirmBtn.type = 'button';
    confirmBtn.className = 'delete-btn delete-confirm-btn';
    confirmBtn.textContent = '✓ Delete';
    confirmBtn.id = `confirm-${stringId}`;

    const cancelBtn = document.createElement('button');
    cancelBtn.type = 'button';
    cancelBtn.className = 'edit-btn delete-cancel-btn';
    cancelBtn.textContent = '✕';
    cancelBtn.id = `cancel-${stringId}`;

    const cleanup = () => {
        if (deleteTimers[stringId]) {
            clearTimeout(deleteTimers[stringId]);
            delete deleteTimers[stringId];
        }
        if (confirmBtn.parentElement) confirmBtn.remove();
        if (cancelBtn.parentElement) cancelBtn.remove();
        delBtn.style.display = '';
        delBtn.dataset.confirming = '0';
    };

    confirmBtn.onclick = () => {
        cleanup();

        // Tombstone so a future cloud pull doesn't resurrect this record
        tombstones[stringId] = Date.now();
        saveTombstones();

        if (type === 'move') {
            movesRecords = movesRecords.filter(m => String(m.id) !== stringId);
            safeSetItem('betaCattleMoves', JSON.stringify(movesRecords));
            updateMovesList();
        } else {
            records = records.filter(r => String(r.id) !== stringId);
            safeSetItem('betaCattleRecords', JSON.stringify(records));
            updateRecentList();
        }

        pushToCloud({ action: 'delete', id: stringId, type: type });
        showToast('🗑 Deleted', 'success', 1500);
        updateDailySummary();
    };

    cancelBtn.onclick = cleanup;

    actionCell.appendChild(confirmBtn);
    actionCell.appendChild(cancelBtn);

    // Auto-cancel after 5 seconds
    deleteTimers[stringId] = setTimeout(cleanup, 5000);
};

// =========================================================
// CORE DOCTORING UTILITIES
// =========================================================
clearTagBtn.onclick = () => {
    tagNumberInput.value = '';
    tagNumberInput.dispatchEvent(new Event('input'));
    // Don't refocus — that reopens the keypad and surprises the user.
    // Tapping the field again is one tap and intentional.
};

noTagBtn.onclick = () => {
    let maxNt = 0;
    records.forEach(r => {
        const tag = String(r.tagNumber).toUpperCase();
        if (tag.startsWith('NT')) {
            const num = parseInt(tag.replace('NT', ''), 10);
            if (!isNaN(num) && num > maxNt) maxNt = num;
        }
    });
    tagNumberInput.value = `NT${maxNt + 1}`;
    tagNumberInput.dispatchEvent(new Event('input'));
};

window.processCloudData = function(data) {
    try {
        if (data && Array.isArray(data.records)) {
            const cloudRecords = data.records || [];
            const cloudMoves = data.moves || [];

            // IDs that are still queued for upload — never drop these from local view
            const queuedIds = new Set(syncQueue.map(q => String(q.id)));
            const cloudRecordIds = new Set(cloudRecords.map(r => String(r.id)));
            const cloudMoveIds = new Set(cloudMoves.map(m => String(m.id)));

            // Keep local records that haven't made it to cloud yet (still in queue)
            const localPendingRecords = records.filter(r =>
                queuedIds.has(String(r.id)) && !cloudRecordIds.has(String(r.id))
            );
            const localPendingMoves = movesRecords.filter(m =>
                queuedIds.has(String(m.id)) && !cloudMoveIds.has(String(m.id))
            );

            // Honor tombstones — records the user deleted locally should not reappear from cloud
            const filteredCloudRecords = cloudRecords.filter(r => !tombstones[String(r.id)]);
            const filteredCloudMoves = cloudMoves.filter(m => !tombstones[String(m.id)]);

            records = [...filteredCloudRecords, ...localPendingRecords]
                .sort((a, b) => new Date(b.dateTime) - new Date(a.dateTime));
            movesRecords = [...filteredCloudMoves, ...localPendingMoves]
                .sort((a, b) => new Date(b.date) - new Date(a.date));

            medsDatabase = data.medications || []; 
            locsDatabase = data.locations || []; 
            lotsDatabase = data.lots || []; 
            protocolsDatabase = data.protocols || []; 
            
            safeSetItem('betaCattleRecords', JSON.stringify(records));
            safeSetItem('betaCattleMoves', JSON.stringify(movesRecords));
            safeSetItem('betaCattleMeds', JSON.stringify(medsDatabase));
            safeSetItem('betaCattleLocs', JSON.stringify(locsDatabase));
            safeSetItem('betaCattleLots', JSON.stringify(lotsDatabase));
            safeSetItem('betaCattleProtocols', JSON.stringify(protocolsDatabase));
            
            safeSetItem('betaLastSyncDate', new Date().toISOString().split('T')[0]);
        // Recorded only here, after a pull has populated everything, so a
        // failed or partial pull cannot mark the device as up to date.
        safeSetItem('betaCattleDataVersion', String(DATA_SCHEMA_VERSION));

            // Retire tombstones the cloud has already dropped (keeps the set from growing forever)
            const allCloudIds = new Set([...cloudRecordIds, ...cloudMoveIds]);
            Object.keys(tombstones).forEach(id => {
                if (!allCloudIds.has(id)) delete tombstones[id];
            });
            saveTombstones();
            
            updateDataLists(); 
            if (historySection.style.display === 'block') {
                updateRecentList();
                updateMovesList();
            }
            updateDailySummary();
            syncCloudBtn.innerText = "✅ DATA REFRESHED!";
        }
    } catch (err) { 
        console.error('processCloudData error:', err);
        syncCloudBtn.innerText = "❌ Data Error"; 
    }
    setTimeout(() => { syncCloudBtn.innerText = "🔄 Pull Cloud History"; }, 3000);
};

// lot_tags runs to thousands of rows and PostgREST caps a response at 1000,
// so this pages until a short page comes back. Without paging, tags beyond
// the first 1000 would silently have no location - the worst kind of wrong,
// because it looks like "no data" rather than "truncated".
async function fetchOpenLotTags() {
    const PAGE = 1000;
    let from = 0, all = [];
    for (;;) {
        const { data, error } = await sb
            .from('lot_tags')
            .select('tag_number, lot_id, delivery_receipt_id, retired_at, lots!inner(lot_number, closed_at, is_test)')
            .is('retired_at', null)
            .is('lots.closed_at', null)
            .order('tag_number')
            .range(from, from + PAGE - 1);
        if (error) throw error;
        all = all.concat(data || []);
        if (!data || data.length < PAGE) break;
        from += PAGE;
        if (from > 50000) break;   // runaway guard
    }
    return all.filter(t => t.lots && !t.lots.is_test);
}

// Reads now come from Supabase instead of a JSONP <script> injection
// against the Apps Script endpoint. The payload is shaped to exactly what
// processCloudData already expects, so the merge/tombstone logic below it
// is untouched.
async function pullCloudData() {
    if (!currentUserId) { showToast('Sign in first', 'error', 2000); return; }
    syncCloudBtn.innerText = "⏳ Downloading...";
    try {
        const [entriesRes, medsRes, pasturesRes, statusRes, lotsRes, bookRes, assignRes, destRes, receiptRes, actionsRes, protosRes] = await Promise.all([
            // Own submissions (RLS widens this to everything for owner/office).
            // Withdrawn entries are excluded so a deleted record cannot
            // reappear in the history list.
            sb.from(STAGING_TABLE)
              .select('entry_type, raw, status')
              .neq('status', 'withdrawn')
              .order('submitted_at', { ascending: false })
              .limit(1000),
            sb.from('medications')
              .select('name, dose_mode, flat_dose_amount, per_weight_rate, per_weight_basis, default_dose_amount')
              .eq('is_active', true).order('name'),
            sb.from('pastures')
              .select('id, name, is_active, ranches!inner(name, is_active)')
              .eq('is_active', true).order('name'),
            // Tags recycle across fiscal years, so the field app only ever
            // offers OPEN lots. lot_status carries the weight/ADG figures the
            // estimated-weight box and the dose auto-fill depend on; `lots`
            // carries the tag range used to infer a lot from a tag number.
            sb.from('lot_status')
              .select('lot_id, lot_number, arrival_date, target_adg, avg_weight_in, closed_at')
              .is('closed_at', null).order('lot_number'),
            sb.from('lots')
              .select('id, lot_number, start_tag, end_tag, closed_at, is_test')
              .is('closed_at', null),
            // Treatments already in the books. Without these, tag recall and
            // the 1st/2nd-pull safety checks only ever see what this phone
            // submitted, so an animal treated last month looks untouched.
            sb.from('doctoring_events')
              .select('tag_number, event_datetime, lot_id, pasture_id, field_actions(name), lots!inner(lot_number, closed_at, is_test)')
              .is('lots.closed_at', null)
              .order('event_datetime', { ascending: false })
              .limit(1000),
            // A lot usually spans several pastures, so location can only be
            // inferred when it sits in exactly one.
            sb.from('lot_pasture_assignments')
              .select('lot_id, pasture_id, moved_out, pastures!inner(name, ranches!inner(name))')
              .is('moved_out', null),
            // Where each delivery receipt's cattle were turned out. Combined
            // with lot_tags.delivery_receipt_id this is the only per-ANIMAL
            // location the books hold.
            sb.from('load_out_destinations').select('receipt_id, pasture_id').limit(1000),
            // Tag ranges per RECEIPT. lots.start_tag/end_tag only ever held the
            // FIRST load: lot 36-27 reads 8255-8283 there while its eleven
            // receipts actually span 8255-8695. Receipt ranges are the real ones.
            sb.from('delivery_receipts')
              .select('lot_id, tag_start, tag_end, lots!inner(lot_number, closed_at, is_test)')
              .is('lots.closed_at', null).limit(1000),
            sb.from('field_actions').select('name, is_dead, sort_order').order('sort_order'),
            sb.from('field_protocols')
              .select('is_active, field_actions(name), ' +
                      'm1:medications!field_protocols_default_med_1_id_fkey(name), ' +
                      'm2:medications!field_protocols_default_med_2_id_fkey(name), ' +
                      'm3:medications!field_protocols_default_med_3_id_fkey(name)')
              .eq('is_active', true)
        ]);

        // Degrade rather than die. Previously a single failing query threw and
        // the cowboy lost lots, meds and protocols together, with nothing to
        // say which one broke. Now each is reported by name and whatever
        // succeeded is still used.
        const named = [
            ['entries', entriesRes], ['medications', medsRes], ['pastures', pasturesRes],
            ['lot_status', statusRes], ['lots', lotsRes], ['doctoring history', bookRes],
            ['pasture assignments', assignRes], ['receipt destinations', destRes],
            ['receipt tag ranges', receiptRes], ['actions', actionsRes], ['protocols', protosRes]
        ];
        const failed = named.filter(([, r]) => r.error);
        if (failed.length) {
            failed.forEach(([name, r]) => console.error(`pull failed for ${name}:`, r.error));
            showToast(`\u26a0 Couldn't load: ${failed.map(([n]) => n).join(', ')}`, 'error', 6000);
        }
        // Losing the lot list is not a partial failure - the form cannot work
        // without it, so that one still stops the pull.
        if (statusRes.error && lotsRes.error) throw statusRes.error;

        const entries = entriesRes.data || [];

        // Rebuild the app's own record shape straight out of `raw` — it is
        // the submitted payload verbatim, so no back-conversion is needed.
        const cloudRecords = entries.filter(e => e.entry_type === 'doctoring').map(e => e.raw);
        const cloudMoves   = entries.filter(e => e.entry_type === 'move').map(e => e.raw);

        // The dose string feeds triggerMedAutoFill(), which splits on '/'
        // to mean rate-per-basis and otherwise treats it as a flat dose.
        const medications = (medsRes.data || []).map(m => ({
            name: m.name,
            dose: m.dose_mode === 'per_weight' && m.per_weight_rate && m.per_weight_basis
                ? `${m.per_weight_rate}/${m.per_weight_basis}`
                : String(m.flat_dose_amount ?? m.default_dose_amount ?? '')
        }));

        const locations = (pasturesRes.data || [])
            .filter(p => p.ranches && p.ranches.is_active)
            .map(p => ({ property: p.ranches.name, pasture: p.name }));

        // The app reads lotNumber, startTag, endTag, arrivalDate, targetADG and
        // avgWeight off these rows. Anything missing silently degrades a
        // feature rather than erroring: no tag range means no lot inferred
        // from a tag, and no weight/ADG means estimated weight stays 0, which
        // in turn stops per-weight doses auto-filling.
        const tagRangeById = {};
        (lotsRes.data || []).forEach(l => { tagRangeById[l.id] = l; });
        const lots = (statusRes.data || [])
            .map(l => {
                const base = tagRangeById[l.lot_id] || {};
                return {
                    lotNumber:   l.lot_number,
                    startTag:    base.start_tag,
                    endTag:      base.end_tag,
                    arrivalDate: l.arrival_date,
                    targetADG:   l.target_adg,
                    avgWeight:   l.avg_weight_in,
                    isTest:      !!base.is_test
                };
            })
            .filter(l => !l.isTest);

        // Lot -> "Ranch - Pasture", only where the lot sits in exactly one
        // pasture. Ambiguous lots are left out so the form asks rather than
        // guessing wrong.
        const pastureCountByLot = {};
        const soleLocationByLot = {};
        (assignRes.data || []).forEach(a => {
            pastureCountByLot[a.lot_id] = (pastureCountByLot[a.lot_id] || 0) + 1;
            if (a.pastures && a.pastures.ranches) {
                soleLocationByLot[a.lot_id] = `${a.pastures.ranches.name} - ${a.pastures.name}`;
            }
        });

        // --- Per-tag location -------------------------------------------
        // The books track pasture per LOT, not per animal: when 120 head of a
        // 400-head lot move, nothing records WHICH 120. So a tag's location is
        // only knowable in two cases, and this deliberately resolves nothing
        // else rather than guessing:
        //
        //   1. Its receipt turned out into exactly one pasture, AND the lot
        //      still has an open assignment there (so it has not moved off).
        //   2. Its lot currently sits in exactly one pasture.
        //
        // Roughly half of open tags land in case 1 or 2 today; the rest are
        // genuinely unknown and the cowboy is asked.
        const pastureLabelById = {};
        (pasturesRes.data || []).forEach(p => {
            if (p.ranches) pastureLabelById[p.id] = `${p.ranches.name} - ${p.name}`;
        });

        // receipt -> its single destination pasture (skipped if it split)
        const destsByReceipt = {};
        (destRes.data || []).forEach(d => {
            (destsByReceipt[d.receipt_id] = destsByReceipt[d.receipt_id] || []).push(d.pasture_id);
        });

        // lot -> set of pastures it is currently open in
        const openPastureIdsByLot = {};
        (assignRes.data || []).forEach(a => {
            (openPastureIdsByLot[a.lot_id] = openPastureIdsByLot[a.lot_id] || []).push(a.pasture_id);
        });

        const tagLocations = {};
        const tagLots = {};
        try {
            const openTags = await fetchOpenLotTags();
            openTags.forEach(t => {
                if (t.lots && t.lots.lot_number) tagLots[String(t.tag_number)] = t.lots.lot_number;
                const dests = destsByReceipt[t.delivery_receipt_id] || [];
                const openHere = openPastureIdsByLot[t.lot_id] || [];
                let pid = null;
                // Case 1: single arrival pasture the lot has not left.
                if (dests.length === 1 && openHere.indexOf(dests[0]) !== -1) pid = dests[0];
                // Case 2: the lot is only in one place, so the animal is too.
                else if (openHere.length === 1) pid = openHere[0];
                if (pid && pastureLabelById[pid]) tagLocations[String(t.tag_number)] = pastureLabelById[pid];
            });
        } catch (tagErr) {
            // Location is an autofill convenience; losing it must not fail the
            // whole pull and leave the cowboy without lots or meds.
            console.warn('tag location build failed:', tagErr);
        }
        tagRanges = (receiptRes.data || [])
            .filter(r => r.lots && !r.lots.is_test && r.tag_start != null && r.tag_end != null)
            .map(r => ({ lotNumber: r.lots.lot_number, start: r.tag_start, end: r.tag_end }));
        safeSetItem('betaCattleTagRanges', JSON.stringify(tagRanges));

        tagLocationMap = tagLocations;
        tagLotMap = tagLots;
        safeSetItem('betaCattleTagLocations', JSON.stringify(tagLocationMap));
        safeSetItem('betaCattleTagLots', JSON.stringify(tagLotMap));

        // Book treatments, shaped like the app's own records so the same
        // lookups work on both. No id: these must never be edited or deleted
        // from the field app, and every write path keys off id.
        const lotNumberById = {};
        (lotsRes.data || []).forEach(l => { lotNumberById[l.id] = l.lot_number; });
        booksHistory = (bookRes.data || [])
            .filter(d => d.lots && !d.lots.is_test)
            .map(d => ({
                fromBooks: true,
                tagNumber: d.tag_number,
                dateTime: d.event_datetime,
                lotNumber: (d.lots && d.lots.lot_number) || lotNumberById[d.lot_id] || '',
                treatmentType: (d.field_actions && d.field_actions.name) || '',
                // Prefer the pasture recorded ON the event; only 16 of 1080
                // rows have one today because the office doctoring form does
                // not yet ask, but it is the most accurate source when set.
                location: (d.pasture_id && pastureLabelById[d.pasture_id])
                    || tagLocations[String(d.tag_number)]
                    || (pastureCountByLot[d.lot_id] === 1 ? (soleLocationByLot[d.lot_id] || '') : '')
            }));
        safeSetItem('betaCattleBooksHistory', JSON.stringify(booksHistory));

        // The action dropdown is built from protocols, and it appends Dead
        // and Other itself — so those two are excluded here to avoid
        // listing them twice. Receiving has no protocol row but must still
        // appear, which is why this is driven by field_actions rather than
        // by field_protocols.
        const medsByAction = {};
        (protosRes.data || []).forEach(fp => {
            const name = fp.field_actions && fp.field_actions.name;
            if (name) medsByAction[name] = fp;
        });
        const protocols = (actionsRes.data || [])
            .filter(a => a.name !== 'Dead' && a.name !== 'Other')
            .map(a => {
                const fp = medsByAction[a.name] || {};
                return {
                    actionName: a.name,
                    med1: (fp.m1 && fp.m1.name) || '',
                    med2: (fp.m2 && fp.m2.name) || '',
                    med3: (fp.m3 && fp.m3.name) || ''
                };
            });

        window.processCloudData({
            records: cloudRecords, moves: cloudMoves,
            medications, locations, lots, protocols
        });
    } catch (err) {
        console.error('pullCloudData error:', err);
        syncCloudBtn.innerText = "❌ " + (err.message ? err.message.slice(0, 24) : 'Data Error');
        setTimeout(() => { syncCloudBtn.innerText = "🔄 Pull Cloud History"; }, 4000);
    }
}
syncCloudBtn.onclick = pullCloudData;

function triggerMedAutoFill(medInput, doseInput) {
    const medName = medInput.value.trim().toLowerCase();
    if (!medName) {
        // No med = no dose. Prevents stale doses from sticking around.
        doseInput.value = '';
        return;
    }
    const selectedMed = medsDatabase.find(m => m.name.toLowerCase() === medName);
    if (selectedMed && selectedMed.dose && currentEstWeight > 0) {
        if (selectedMed.dose.includes('/')) {
            let parts = selectedMed.dose.split('/');
            doseInput.value = Math.ceil((currentEstWeight / parseFloat(parts[1])) * parseFloat(parts[0]));
        } else { doseInput.value = selectedMed.dose; }
    }
}
[med1, med2, med3].forEach((m, i) => m.onchange = () => triggerMedAutoFill(m, document.getElementById(`dosage${i+1}`)));

// =========================================================
// SMART AUTO-FILL (Location & Lot logic)
// =========================================================
tagNumberInput.oninput = function(e) {
    const val = e.target.value.trim();
    clearTagBtn.style.display = val !== '' ? 'flex' : 'none';
    if (editingRecordId) return;
    
    if (val === '') {
        tagAlert.style.display = 'none';
        // Don't clear locked fields — they need to persist across saves
        if (!locks.lot)    lotInput.value = '';
        if (!locks.action) treatmentTypeInput.value = '';
        lotInput.style.pointerEvents = 'auto';
        lotInput.style.backgroundColor = '#ffffff';
        return;
    }

    treatmentTypeInput.disabled = false;

    const hist = historyPool().find(r => String(r.tagNumber) === val);
    let foundLot = hist ? hist.lotNumber : "";

    if (!foundLot) foundLot = resolveLotForTag(val);
    
    if (foundLot && !locks.lot) {
        lotInput.value = foundLot;
        lotInput.style.pointerEvents = 'none';
        lotInput.style.backgroundColor = '#e5e5ea';
    } else if (!locks.lot) {
        lotInput.style.pointerEvents = 'auto';
        lotInput.style.backgroundColor = '#ffffff';
    }

    // Where this animal is. A previous entry for this exact tag wins - it is
    // the most recent first-hand sighting. Otherwise fall back to what the
    // books can prove about this tag. If neither knows, leave it blank and
    // let the cowboy say, rather than filling in a guess.
    const recalledLocation = (hist && hist.location && hist.location.includes(" - "))
        ? hist.location
        : (tagLocationMap[val] || '');

    if (recalledLocation && recalledLocation.includes(" - ") && !locks.ranch && !locks.pasture) {
        const parts = recalledLocation.split(" - ");
        const prop = String(parts[0]).trim();
        const past = String(parts[1]).trim();

        propertyInput.value = prop;
        pastureInput.disabled = false;
        
        const pastures = locsDatabase
            .filter(l => l.property && String(l.property).trim() === prop)
            .map(l => String(l.pasture).trim())
            .sort();
        const uniquePastures = [...new Set(pastures)];
        pastureInput.innerHTML = '<option value="" disabled selected>Select Pasture...</option>'
            + uniquePastures.map(p => `<option value="${p}">${p}</option>`).join('');
        
        pastureInput.value = past;
    }

    updateAlertBox();
};

function updateAlertBox() {
    const tagVal = tagNumberInput.value.trim();
    const lotVal = lotInput.value.trim();
    let alertHtml = "";
    
    if (tagVal !== '') {
        const history = historyPool().filter(r => String(r.tagNumber) === tagVal && String(r.id) !== String(editingRecordId));
        if (history.length > 0) {
            // Tappable history line — opens a modal with the prior records
            alertHtml += `<div class="tag-history-link" onclick="showTagHistory('${tagVal.replace(/'/g, "\\'")}')">⚠️ <b>History:</b> ${history.length} previous record${history.length > 1 ? 's' : ''} <span class="tag-history-cta">— tap to view ▸</span></div>`;
        }
    }
    
    currentEstWeight = 0; 
    if (lotVal !== '') {
        const lot = lotsDatabase.find(l => String(l.lotNumber).trim().toLowerCase() === lotVal.toLowerCase());
        if (lot) {
            const arrival = new Date(lot.arrivalDate);
            const today = new Date();
            arrival.setHours(0,0,0,0); today.setHours(0,0,0,0);
            let dof = isNaN(arrival.getTime()) ? 0 : Math.floor((today - arrival) / (1000 * 3600 * 24));
            if (dof < 0) dof = 0;
            const gain = parseFloat(lot.targetADG) || 0;
            const startW = parseFloat(lot.avgWeight) || 0;
            currentEstWeight = Math.round(startW + (dof * gain));
            alertHtml += `📦 <b>Lot: ${lot.lotNumber}</b> | <b>DOF:</b> ${dof} | <b>Gain:</b> ${gain}<br><b>Est. Weight: ${currentEstWeight} lbs</b>`;
        } else {
            alertHtml += `📦 <b>Lot: ${lotVal}</b> (No weight data found)`;
        }
    }
    
    if (alertHtml !== "") {
        tagAlert.style.backgroundColor = currentEstWeight > 0 ? '#e5fceb' : '#e5f0ff';
        tagAlert.style.borderLeftColor = currentEstWeight > 0 ? '#34c759' : '#007aff';
        tagAlert.innerHTML = alertHtml;
        tagAlert.style.display = 'block';
    } else {
        tagAlert.style.display = 'none';
    }
}

// =========================================================
// TAG HISTORY MODAL — one-tap drill-in for chute decisions
// =========================================================
window.showTagHistory = function(tag) {
    const history = historyPool()
        .filter(r => String(r.tagNumber) === String(tag))
        .sort((a, b) => new Date(b.dateTime) - new Date(a.dateTime));

    const modal = document.getElementById('tagHistoryModal');
    const body = document.getElementById('tagHistoryBody');
    const title = document.getElementById('tagHistoryTitle');

    title.textContent = `Tag ${tag} — ${history.length} record${history.length === 1 ? '' : 's'}`;

    if (history.length === 0) {
        body.innerHTML = '<p style="color:#8e8e93;">No prior records.</p>';
    } else {
        body.innerHTML = history.map(r => {
            const dt = String(r.dateTime || '').replace('T', ' ').slice(0, 16);
            const meds = [
                r.medication1 && `${r.medication1}${r.dosage1 ? ' (' + r.dosage1 + ')' : ''}`,
                r.medication2 && `${r.medication2}${r.dosage2 ? ' (' + r.dosage2 + ')' : ''}`,
                r.medication3 && `${r.medication3}${r.dosage3 ? ' (' + r.dosage3 + ')' : ''}`
            ].filter(Boolean).join(', ');
            const isDead = String(r.treatmentType).toLowerCase().includes('dead');
            return `
                <div class="tag-history-card${isDead ? ' tag-history-card-dead' : ''}">
                    <div class="thc-row">
                        <span class="thc-action">${r.treatmentType || ''}</span>
                        <span class="thc-date">${dt}</span>
                    </div>
                    ${meds ? `<div class="thc-meds">💊 ${meds}</div>` : ''}
                    <div class="thc-meta">
                        ${r.location ? `📍 ${r.location}` : ''}
                        ${r.recordedBy ? ` · by ${r.recordedBy}` : ''}
                        ${r.fromBooks ? ` · <span class="thc-books">from the books</span>` : ''}
                    </div>
                    ${r.drugOff ? `<div class="thc-drugoff">⚠ Drug off: ${r.drugOff}</div>` : ''}
                    ${r.notes ? `<div class="thc-notes">📝 ${r.notes}</div>` : ''}
                </div>
            `;
        }).join('');
    }

    modal.style.display = 'block';
};

window.closeTagHistory = function() {
    document.getElementById('tagHistoryModal').style.display = 'none';
};

// =========================================================
// ACTION SAFETY VALIDATION (Checks as soon as selected)
// =========================================================
function validateActionSafety(tag, action) {
    if (!tag || !action) return { valid: true };
    
    const actionLower = action.toLowerCase();
    const tagHistory = historyPool().filter(r => String(r.tagNumber) === tag && String(r.id) !== String(editingRecordId));

    const hasFirstPull = tagHistory.some(r => r.treatmentType.toLowerCase().includes('1st') || r.treatmentType.toLowerCase().includes('first'));
    const hasSecondPull = tagHistory.some(r => r.treatmentType.toLowerCase().includes('2nd') || r.treatmentType.toLowerCase().includes('second'));
    const hasDead = tagHistory.some(r => r.treatmentType.toLowerCase().includes('dead'));

    if ((actionLower.includes('1st') || actionLower.includes('first')) && hasFirstPull) {
        return { valid: false, msg: `Tag ${tag} already has a 1st Pull on record.` };
    }

    if (actionLower.includes('2nd') || actionLower.includes('second')) {
        if (hasSecondPull) {
            return { valid: false, msg: `Tag ${tag} already has a 2nd Pull on record.` };
        }
        if (!isNaN(parseInt(tag))) {
            const resolved = resolveLotForTag(tag);
            const lot = resolved ? lotsDatabase.find(l => String(l.lotNumber) === String(resolved)) : null;
            if (lot && lot.arrivalDate && String(lot.arrivalDate).trim() !== "") {
                if (!hasFirstPull) {
                    return { valid: false, msg: `Tag ${tag} is registered to Lot ${lot.lotNumber} with an arrival date. You cannot record a 2nd Pull without a 1st Pull.` };
                }
            }
        }
    }

    if (actionLower.includes('dead') && hasDead) {
        return { valid: false, msg: `Tag ${tag} is already marked as Dead.` };
    }

    return { valid: true };
}

treatmentTypeInput.onchange = function(e) {
    const action = e.target.value;
    const tag = tagNumberInput.value.trim();

    // WORKFLOW UPGRADE: Instant Action Validation
    const safetyCheck = validateActionSafety(tag, action);
    if (!safetyCheck.valid) {
        showToast(`🛑 ${safetyCheck.msg}`, 'error', 3500);
        treatmentTypeInput.value = ''; // Instantly clear the bad selection
        updateFormVisibility(''); 
        return;
    }

    updateFormVisibility(action);
    // Always clear all three med + dose slots before applying the new protocol,
    // otherwise stale values from the previous action linger.
    med1.value = ''; med2.value = ''; med3.value = '';
    dose1.value = ''; dose2.value = ''; dose3.value = '';

    const proto = protocolsDatabase.find(p => p.actionName === action);
    if (proto) {
        med1.value = proto.med1 || ''; med2.value = proto.med2 || ''; med3.value = proto.med3 || '';
        [med1, med2, med3].forEach((m, i) => triggerMedAutoFill(m, document.getElementById(`dosage${i+1}`)));
    }
};

function updateDataLists() {
    lotInput.innerHTML = '<option value="" disabled selected>Select Lot...</option>'
        + lotsDatabase.map(l => `<option value="${l.lotNumber}">${l.lotNumber}</option>`).join('');

    medicationList.innerHTML = medsDatabase.map(m => `<option value="${m.name}">`).join('');

    const props = [...new Set(locsDatabase.map(l => String(l.property).trim()))].sort();
    propertyInput.innerHTML = '<option value="" disabled selected>Select Ranch...</option>'
        + props.map(p => `<option value="${p}">${p}</option>`).join('');

    treatmentTypeInput.innerHTML = '<option value="" disabled selected>Select Action...</option>'
        + protocolsDatabase.map(p => `<option value="${p.actionName}">${p.actionName}</option>`).join('')
        + '<option value="Dead">Dead</option><option value="Other">Other</option>';
}

propertyInput.onchange = function() {
    pastureInput.disabled = false;
    const prop = this.value;
    const pastures = locsDatabase
        .filter(l => l.property && String(l.property).trim() === String(prop).trim())
        .map(l => String(l.pasture).trim())
        .sort();
    const uniquePastures = [...new Set(pastures)];
    pastureInput.innerHTML = '<option value="" disabled selected>Select Pasture...</option>'
        + uniquePastures.map(p => `<option value="${p}">${p}</option>`).join('');
};

function pushToCloud(record) {
    // Queue for resilient delivery. Retries on reconnect, focus, and interval.
    enqueueForSync(record);
}

// Submitting Doctoring Record
doctoringForm.onsubmit = function(e) {
    e.preventDefault();

    // Guard against double-taps / rapid resubmits
    if (isSubmittingDoctoring) return;

    const prop = propertyInput.value.trim();
    const past = pastureInput.value.trim();
    const tag = tagNumberInput.value.trim();
    const action = treatmentTypeInput.value;

    // Minimum info check — avoid saving empty records by accident
    const missing = [];
    if (!recordedByInput.value.trim()) missing.push('Crew Member');
    if (!tag) missing.push('Tag # (or NT)');
    if (!action) missing.push('Action');
    if (!prop) missing.push('Ranch');
    if (missing.length) {
        showToast(`Missing: ${missing.join(', ')}`, 'error', 3000);
        return;
    }

    // Final safety net check just in case
    const safetyCheck = validateActionSafety(tag, action);
    if (!safetyCheck.valid) {
        showToast(`🛑 ${safetyCheck.msg}`, 'error', 3500);
        return;
    }

    const tagMsg = tag ? tag : "No Tag (NT)";
    if(!confirm(`Save ${tagMsg} — ${action}?`)) {
        return; 
    }

    // Lock the button — can't double-submit
    isSubmittingDoctoring = true;
    submitBtn.disabled = true;
    submitBtn.style.opacity = '0.6';

    // Preserve original time when editing; new records get current time
    let timeStr;
    if (editingRecordId) {
        const orig = records.find(r => String(r.id) === String(editingRecordId));
        if (orig && orig.dateTime && String(orig.dateTime).includes('T')) {
            timeStr = String(orig.dateTime).split('T')[1];
        } else {
            timeStr = new Date().toLocaleTimeString('en-GB');
        }
    } else {
        timeStr = new Date().toLocaleTimeString('en-GB');
    }

    const data = {
        type: 'doctoring',
        id: editingRecordId || String(Date.now()),
        tagNumber: tag,
        dateTime: dateTimeInput.value + "T" + timeStr,
        location: `${prop} - ${past}`,
        lotNumber: lotInput.value,
        treatmentType: action,
        medication1: med1.value, dosage1: dose1.value,
        medication2: med2.value, dosage2: dose2.value,
        medication3: med3.value, dosage3: dose3.value,
        drugOff: action === 'Dead' ? (drugOffInput.value || '') : '',
        notes: document.getElementById('notes').value,
        recordedBy: recordedByInput.value.trim()
    };
    
    const wasEditing = !!editingRecordId;
    if (editingRecordId) {
        records = records.map(r => String(r.id) === String(editingRecordId) ? data : r);
        editingRecordId = null;
        submitBtn.innerText = "Save Record"; submitBtn.style.backgroundColor = "#34c759";
    } else {
        records.unshift(data);
    }
    
    safeSetItem('betaCattleRecords', JSON.stringify(records));
    safeSetItem('crewMemberName', recordedByInput.value.trim());

    pushToCloud(data);

    // Capture locked values BEFORE reset so we can put them back
    const lockedSnapshot = snapshotLockedValues();

    doctoringForm.reset();
    setCurrentDateTime();
    recordedByInput.value = localStorage.getItem('crewMemberName'); 
    
    tagNumberInput.dispatchEvent(new Event('input'));

    // Restore any locked fields so the crew doesn't re-enter them
    restoreLockedValues(lockedSnapshot);

    // Hide meds section if Action wasn't locked (or if locked Action was Dead)
    updateFormVisibility(treatmentTypeInput.value);

    // Refresh banner so the displayed values match the restored fields
    updateChuteBanner();

    showToast(`✓ Saved: ${tagMsg}`, 'success', 1800);
    updateDailySummary();

    // In chute mode (any lock active), the next animal needs only a tag.
    // Auto-open the keypad so it's one less tap per animal (touch devices only).
    // Skip after edits — user finished editing, not advancing to a new animal.
    const inChuteMode = locks.ranch || locks.pasture || locks.lot || locks.action;
    if (!wasEditing && inChuteMode && isTouchPrimary) {
        setTimeout(() => openKeypad(), 250);
    } else if (!wasEditing && inChuteMode) {
        // Desktop: just focus the field so they can start typing
        setTimeout(() => tagNumberInput.focus(), 250);
    }

    // Re-enable after short cooldown
    setTimeout(() => {
        isSubmittingDoctoring = false;
        submitBtn.disabled = false;
        submitBtn.style.opacity = '1';
    }, 600);
};

document.getElementById('recallLocationBtn').onclick = function() {
    const r = records[0];
    if (r && r.location && r.location.includes(" - ")) {
        const parts = r.location.split(" - ");
        const prop = String(parts[0]).trim();
        const past = String(parts[1]).trim();
        
        propertyInput.value = prop;
        pastureInput.innerHTML = `<option value="${past}">${past}</option>`;
        pastureInput.value = past;
        pastureInput.disabled = false;
    }
};

document.getElementById('recallLotBtn').onclick = function() {
    const r = records[0];
    if (r && r.lotNumber) lotInput.value = r.lotNumber;
};

document.getElementById('recallActionBtn').onclick = function() {
    const r = records[0];
    if (r && r.treatmentType) treatmentTypeInput.value = r.treatmentType;
};

// =========================================================
// TABLE RENDERING (Only shown on History Tab)
// =========================================================
function getYesterdayMidnight() {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const yesterday = new Date(today);
    yesterday.setDate(yesterday.getDate() - 1);
    return yesterday;
}

function updateRecentList() {
    recordTableBody.innerHTML = '';
    const cutoff = getYesterdayMidnight();
    const recentRecords = records.filter(r => {
        if (!r.dateTime) return false;
        const recDate = new Date(r.dateTime.split('T')[0] + "T00:00:00");
        return recDate >= cutoff;
    });

    recentRecords.forEach(r => renderDoctoringRow(r));
    tableContainer.style.display = recentRecords.length > 0 ? 'block' : 'none';
}

function updateMovesList() {
    movesTableBody.innerHTML = '';
    const cutoff = getYesterdayMidnight();
    const recentMoves = movesRecords.filter(m => {
        if (!m.date) return false;
        const mDate = new Date(m.date.split('T')[0] + "T00:00:00");
        return mDate >= cutoff;
    });

    recentMoves.forEach(m => renderMoveRow(m));
    movesTableContainer.style.display = recentMoves.length > 0 ? 'block' : 'none';
}

function renderDoctoringRow(r) {
    const tr = document.createElement('tr');
    const drugOffTag = r.drugOff ? `<b style="color:#d70015;">[Drug off: ${r.drugOff}]</b> ` : '';
    tr.innerHTML = `
        <td><b>${r.tagNumber}</b></td>
        <td>${String(r.dateTime).replace('T', ' ')}</td>
        <td>${r.treatmentType}</td>
        <td>${r.location}</td>
        <td>${r.medication1} <small>${r.dosage1}</small></td>
        <td>${drugOffTag}${r.notes || ''}</td>
        <td>
            <div class="action-buttons">
                <button type="button" class="edit-btn" title="Load this record into the form to edit it." onclick="editLocal('${r.id}')">Edit</button>
                <button type="button" id="del-${r.id}" class="delete-btn" title="Delete this record. You'll be asked to confirm." onclick="confirmDelete('${r.id}', 'doctoring')">Del</button>
            </div>
        </td>
    `;
    recordTableBody.appendChild(tr);
}

function renderMoveRow(m) {
    const tr = document.createElement('tr');
    tr.innerHTML = `
        <td>${m.date}</td>
        <td>${m.fromRanch} - ${m.fromPasture}</td>
        <td>${m.toRanch} - ${m.toPasture}</td>
        <td>${m.headCount || '0'}</td>
        <td>${m.notes || '-'}</td>
        <td>
            <div class="action-buttons">
                <button type="button" class="edit-btn" title="Load this move into the form to edit it." onclick="editMoveLocal('${m.id}')">Edit</button>
                <button type="button" id="del-${m.id}" class="delete-btn" title="Delete this move. You'll be asked to confirm." onclick="confirmDelete('${m.id}', 'move')">Del</button>
            </div>
        </td>
    `;
    movesTableBody.appendChild(tr);
}

window.editLocal = function(id) {
    const r = records.find(rec => String(rec.id) === String(id));
    if (!r) return;
    
    editingRecordId = String(id);
    switchTab('doctoring');
    
    tagNumberInput.value = r.tagNumber;
    dateTimeInput.value = r.dateTime ? String(r.dateTime).split('T')[0] : '';
    treatmentTypeInput.disabled = false;
    
    if (r.lotNumber) {
        let exists = Array.from(lotInput.options).some(opt => opt.value === r.lotNumber);
        if (!exists) lotInput.innerHTML += `<option value="${r.lotNumber}">${r.lotNumber}</option>`;
        lotInput.value = r.lotNumber;
    }

    treatmentTypeInput.value = r.treatmentType;
    updateFormVisibility(r.treatmentType);
    if (r.treatmentType === 'Dead') {
        drugOffInput.value = r.drugOff || '';
    }
    
    if (r.location && r.location.includes(" - ")) {
        const parts = r.location.split(" - ");
        const prop = String(parts[0]).trim();
        const past = String(parts[1]).trim();
        
        propertyInput.value = prop;
        pastureInput.innerHTML = `<option value="${past}">${past}</option>`;
        pastureInput.value = past;
        pastureInput.disabled = false;
    }
    
    med1.value = r.medication1; dose1.value = r.dosage1;
    med2.value = r.medication2; dose2.value = r.dosage2;
    document.getElementById('notes').value = r.notes;
    
    submitBtn.innerText = "Update Record";
    submitBtn.style.backgroundColor = "#ffcc00";
    window.scrollTo({ top: 0, behavior: 'smooth' });
};

document.getElementById('openReportBtn').onclick = function() {
    const today = new Date().toISOString().split('T')[0];
    const todays = records.filter(r => String(r.dateTime).startsWith(today));
    let html = `<p><b>Total Today:</b> ${todays.length}</p><ul>`;
    const counts = {};
    todays.forEach(r => counts[r.treatmentType] = (counts[r.treatmentType] || 0) + 1);
    for (const [type, count] of Object.entries(counts)) { html += `<li>${type}: ${count}</li>`; }
    document.getElementById('reportContent').innerHTML = html;
    document.getElementById('reportModal').style.display = "block";
};
document.getElementById('closeModalBtn').onclick = () => document.getElementById('reportModal').style.display = "none";

function setCurrentDateTime() { dateTimeInput.valueAsDate = new Date(); }
function updateFormVisibility(type) {
    const hasAction = type && type !== '';
    const isDead = type === 'Dead';
    // Show meds only when an action calls for them (not Dead, not empty)
    document.getElementById('medicationsSection').style.display = (hasAction && !isDead) ? 'block' : 'none';
    drugOffGroup.style.display = isDead ? 'block' : 'none';
    if (!isDead) drugOffInput.value = '';
}

// Display Records for Search Bar
function displayRecords(filter = '', exact = false) {
    if (!filter) { 
        updateRecentList();
        movesTableContainer.style.display = 'block'; 
        return; 
    }
    movesTableContainer.style.display = 'none'; 
    recordTableBody.innerHTML = '';
    const filtered = records.filter(r => exact ? String(r.tagNumber) === filter : String(r.tagNumber).includes(filter));
    if (filtered.length === 0) { tableContainer.style.display = 'none'; return; }
    tableContainer.style.display = 'block';
    filtered.forEach(r => renderDoctoringRow(r));
}
document.getElementById('searchInput').addEventListener('input', (e) => displayRecords(e.target.value));

// =========================================================
// HELP & TROUBLESHOOTING MODALS
// =========================================================
const helpModal = document.getElementById('helpModal');
const troubleModal = document.getElementById('troubleModal');

document.getElementById('helpBtn').addEventListener('click', () => {
    helpModal.style.display = 'block';
    helpModal.scrollTop = 0;
    const content = helpModal.querySelector('.modal-content');
    if (content) content.scrollTop = 0;
});

// =========================================================
// RESET APP DATA
// =========================================================
// Walking a cowboy through Settings -> Safari -> Advanced -> Website Data
// is not realistic in a pasture, so the app resets itself.
//
// Scoped on purpose: it clears only this app's own betaCattle* keys. The
// office app lives on the SAME ORIGIN (github.io serves both from one
// host), and localStorage is per-origin, not per-path - so a blanket
// localStorage.clear() would also blow away the office app's session.
const RESET_KEYS = [
    'betaCattleRecords', 'betaCattleMoves', 'betaCattleMeds', 'betaCattleLocs',
    'betaCattleLots', 'betaCattleProtocols', 'betaCattleLocks',
    'betaCattleBooksHistory', 'betaCattleTagLocations', 'betaCattleTagLots',
    'betaCattleTagRanges',
    'betaCattleSyncQueue', 'betaCattleTombstones', 'betaCattleRejected',
    'betaLastSyncDate', 'betaCattleDataVersion'
    // 'crewMemberName' is deliberately kept - it is a convenience, not state,
    // and retyping it is pure friction.
];

function refreshResetState() {
    const status = document.getElementById('resetStatus');
    const btn = document.getElementById('resetAppBtn');
    if (!status || !btn) return;

    const queued = syncQueue.length;
    if (queued > 0) {
        // Resetting now would destroy work the office has never seen.
        status.textContent = `\u26a0 ${queued} record(s) still waiting to sync. Get signal and let the queue clear first.`;
        status.className = 'reset-note blocked';
        btn.disabled = true;
    } else {
        status.textContent = '\u2713 Nothing waiting to sync — safe to reset.';
        status.className = 'reset-note ready';
        btn.disabled = false;
    }
}

async function resetAppData(opts) {
    opts = opts || {};
    // Re-check at the moment of the tap, not just when the modal opened.
    // `force` is the locked-out path: someone stuck at the login screen has
    // no way to drain the queue, so losing it beats a phone that cannot work
    // at all — but only after they have been told, in the caller.
    if (syncQueue.length > 0 && !opts.force) {
        showToast(`\u26d4 ${syncQueue.length} record(s) still unsent. Reset blocked.`, 'error', 4000);
        refreshResetState();
        return;
    }

    if (!opts.skipConfirm && !confirm(
        'Reset app data?\n\n' +
        'Clears this phone\'s saved records, lists and settings, then reloads a ' +
        'fresh copy.\n\nNothing is removed from the ranch database — Pull Cloud ' +
        'History brings your entries back.'
    )) return;

    const btn = document.getElementById('resetAppBtn');
    if (btn) { btn.disabled = true; btn.textContent = 'Resetting…'; }

    try {
        RESET_KEYS.forEach(k => { try { localStorage.removeItem(k); } catch (e) {} });

        // Drop the cached app shell, otherwise the reload just serves the
        // same stale build back and the reset appears to do nothing.
        if ('caches' in window) {
            const names = await caches.keys();
            await Promise.all(names.filter(n => n.startsWith('beta-cattle')).map(n => caches.delete(n)));
        }

        // Unregister the worker so the next load fetches a fresh one rather
        // than waking the old one from its own cache.
        if ('serviceWorker' in navigator) {
            const regs = await navigator.serviceWorker.getRegistrations();
            await Promise.all(regs.map(r => r.unregister()));
        }
    } catch (err) {
        // Never leave the user staring at a dead button — say what happened.
        console.error('reset error:', err);
        alert('Reset hit a problem: ' + (err.message || err) +
              '\n\nThe app will reload anyway. If it still looks wrong, clear ' +
              'website data in your browser settings.');
    }

    // Cache-busted so the reload cannot be answered from the HTTP cache.
    window.location.replace(window.location.pathname + '?reset=' + Date.now());
}

document.getElementById('resetAppBtn').addEventListener('click', resetAppData);

// NOTE: the Reset button on the LOGIN screen is wired by the inline script in
// index.html, not here. It has to work when this file has failed to run, which
// is exactly when someone is locked out and needs it.

document.getElementById('troubleshootBtn').addEventListener('click', () => {
    refreshResetState();
    troubleModal.style.display = 'block';
    const content = troubleModal.querySelector('.modal-content');
    if (content) content.scrollTop = 0;
});

window.closeHelp = () => { helpModal.style.display = 'none'; };
window.closeTrouble = () => { troubleModal.style.display = 'none'; };

// Tap backdrop to dismiss
helpModal.addEventListener('click', (e) => {
    if (e.target === helpModal) closeHelp();
});
troubleModal.addEventListener('click', (e) => {
    if (e.target === troubleModal) closeTrouble();
});

// =========================================================
// AUTH GATE
// =========================================================
// Nothing in the app is usable until Supabase confirms a session — the
// staging table is the only thing this app can write to, and every row
// has to be stamped with a real user id.
const loginScreen = document.getElementById('loginScreen');
const loginForm = document.getElementById('loginForm');
const loginBtn = document.getElementById('loginBtn');
const loginAlert = document.getElementById('loginAlert');
const userChip = document.getElementById('userChip');

function showLoginError(msg) {
    loginAlert.textContent = msg;
    loginAlert.style.display = 'block';
}

async function onSignedIn(user) {
    currentUserId = user.id;

    // A user can authenticate but have no profile row, in which case
    // current_user_role() returns null and every insert would be refused
    // by RLS. Catch that here rather than letting saves fail in a pasture.
    //
    // Three outcomes, deliberately kept apart. The first version of this
    // treated all three as "no profile", signed the user out and told them
    // their account was broken - so one weak-signal request locked someone
    // out of an offline-first app, with no session left to retry with.
    const { data: profile, error } = await sb
        .from('user_profiles')
        .select('full_name, role, is_active')
        .eq('id', user.id)
        .maybeSingle();

    // 1. Could not ASK. That is not the same as being told no. Keep the
    //    session; it is the only way back in without signal.
    if (error) {
        currentUserId = null;
        showLoginError(`Couldn't reach the ranch database (${error.code || error.message || 'network'}). ` +
                       `Check signal and try again — your account is fine.`);
        loginBtn.disabled = false;
        return;
    }

    // 2. Asked, and there is genuinely no profile for this account.
    if (!profile) {
        currentUserId = null;
        await sb.auth.signOut();
        showLoginError(`Signed in as ${user.email || 'this account'}, but it has no ranch profile. ` +
                       `Ask the office to add one.`);
        loginBtn.disabled = false;
        return;
    }

    // 3. Profile exists but has been switched off.
    if (!profile.is_active) {
        currentUserId = null;
        await sb.auth.signOut();
        showLoginError(`The account ${user.email || ''} has been deactivated. Ask the office to turn it back on.`);
        loginBtn.disabled = false;
        return;
    }

    currentProfile = profile;
    loginScreen.style.display = 'none';
    userChip.style.display = 'flex';
    document.getElementById('userChipName').textContent = `${profile.full_name} · ${profile.role}`;

    // Default the crew-member field to the signed-in name when the phone
    // has no saved name yet.
    if (!recordedByInput.value) {
        recordedByInput.value = profile.full_name;
        moveRecordedByInput.value = profile.full_name;
    }

    startApp();
}

function showLoginScreen() {
    currentUserId = null; currentProfile = null;
    loginScreen.style.display = 'flex';
    userChip.style.display = 'none';
}

loginForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    loginAlert.style.display = 'none';
    loginBtn.disabled = true;
    loginBtn.textContent = 'Signing in…';
    try {
        const { data, error } = await sb.auth.signInWithPassword({
            email: document.getElementById('loginEmail').value.trim(),
            password: document.getElementById('loginPassword').value
        });
        if (error) {
            // Include the status/code — "Invalid login credentials" and a
            // server fault look identical to a user otherwise.
            showLoginError(`${error.message}${error.status ? ` (${error.status})` : ''}`);
            loginBtn.disabled = false;
        }
        else await onSignedIn(data.user);
    } catch (err) {
        showLoginError(err.message || 'Sign-in failed. Check signal and try again.');
        loginBtn.disabled = false;
    }
    loginBtn.textContent = 'Sign in';
});

document.getElementById('logoutBtn').addEventListener('click', async () => {
    // Anything still queued would have nobody to submit as after sign-out.
    if (syncQueue.length > 0 &&
        !confirm(`${syncQueue.length} record(s) still waiting to sync. Sign out anyway?`)) return;
    await sb.auth.signOut();
    showLoginScreen();
});

// Init — the parts that are safe before a session exists.
setCurrentDateTime();
updateDataLists();
updateSyncBadge();
updateDailySummary();
updateChuteBanner();

// The rest waits until we know who is signed in.
function startApp() {
    updateDataLists();
    updateSyncBadge();
    updateDailySummary();
    if (navigator.onLine) processSyncQueue();
    checkDailySync();
}

(async function bootstrap() {
    try {
        const { data: { session } } = await sb.auth.getSession();
        if (session && session.user) await onSignedIn(session.user);
        else showLoginScreen();
    } catch (err) {
        // Offline on a cold start with a stored session: supabase-js reads
        // the session from localStorage, so this only trips on a genuinely
        // broken client. Fail closed rather than pretending to be signed in.
        console.error('bootstrap error:', err);
        showLoginScreen();
    }
})();