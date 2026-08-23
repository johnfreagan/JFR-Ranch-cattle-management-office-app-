// =========================================================
// YOUR BETA GOOGLE URL
// =========================================================
const CLOUD_URL = 'https://script.google.com/macros/s/AKfycbzr834h25EsOZaKxibQpdLAVldu_Jt7DGnNquAVJl-W3wZRoLzIgtC4WkFHNqshDeu3jg/exec';

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
let records = JSON.parse(localStorage.getItem('betaCattleRecords')) || [];
let movesRecords = JSON.parse(localStorage.getItem('betaCattleMoves')) || [];
let medsDatabase = JSON.parse(localStorage.getItem('betaCattleMeds')) || [];
let locsDatabase = JSON.parse(localStorage.getItem('betaCattleLocs')) || [];
let lotsDatabase = JSON.parse(localStorage.getItem('betaCattleLots')) || []; 
let protocolsDatabase = JSON.parse(localStorage.getItem('betaCattleProtocols')) || []; 

let currentEstWeight = 0; 
let editingRecordId = null;
let editingMoveId = null;
let deleteTimers = {}; 

// --- SYNC QUEUE & TOMBSTONES (offline resilience) ---
const SYNC_QUEUE_KEY = 'betaCattleSyncQueue';
const TOMBSTONES_KEY = 'betaCattleTombstones';
let syncQueue = JSON.parse(localStorage.getItem(SYNC_QUEUE_KEY)) || [];
let tombstones = JSON.parse(localStorage.getItem(TOMBSTONES_KEY)) || {};
let isSyncingQueue = false;
let isSubmittingDoctoring = false;
let isSubmittingMove = false;

// --- FIELD LOCKS (sticky fields for chute work) ---
const LOCKS_KEY = 'betaCattleLocks';
let locks = JSON.parse(localStorage.getItem(LOCKS_KEY)) || { ranch: false, pasture: false, lot: false, action: false };
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

function sendOne(payload) {
    // Strip internal meta before sending
    const { _attempts, _queuedAt, ...record } = payload;
    record.cb = Date.now();
    const params = new URLSearchParams(record).toString();
    // no-cors = we can't read the response, but fetch still rejects on real network failure
    return fetch(CLOUD_URL + "?" + params, { method: 'GET', mode: 'no-cors' })
        .then(() => true)
        .catch(() => false);
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
            stillFailed.push(item);
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
function checkDailySync() {
    const lastSync = localStorage.getItem('betaLastSyncDate');
    const today = new Date().toISOString().split('T')[0]; 
    
    if (records.length === 0 || locsDatabase.length === 0 || lastSync !== today) {
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

function pullCloudData() {
    syncCloudBtn.innerText = "⏳ Downloading...";
    const script = document.createElement('script');
    script.src = CLOUD_URL + "?action=read&callback=processCloudData&cb=" + Date.now();
    // Remove the script tag once it's done so the DOM doesn't accumulate
    script.onload = script.onerror = () => script.remove();
    document.body.appendChild(script);
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

    const hist = records.find(r => String(r.tagNumber) === val);
    let foundLot = hist ? hist.lotNumber : "";

    if (!foundLot && !isNaN(parseInt(val))) {
        const lot = lotsDatabase.find(l => parseInt(val) >= parseInt(l.startTag) && parseInt(val) <= parseInt(l.endTag));
        if (lot) foundLot = lot.lotNumber;
    }
    
    if (foundLot && !locks.lot) {
        lotInput.value = foundLot;
        lotInput.style.pointerEvents = 'none';
        lotInput.style.backgroundColor = '#e5e5ea';
    } else if (!locks.lot) {
        lotInput.style.pointerEvents = 'auto';
        lotInput.style.backgroundColor = '#ffffff';
    }

    if (hist && hist.location && hist.location.includes(" - ") && !locks.ranch && !locks.pasture) {
        const parts = hist.location.split(" - ");
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
        const history = records.filter(r => String(r.tagNumber) === tagVal && String(r.id) !== String(editingRecordId));
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
    const history = records
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
    const tagHistory = records.filter(r => String(r.tagNumber) === tag && String(r.id) !== String(editingRecordId));

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
            const lot = lotsDatabase.find(l => parseInt(tag) >= parseInt(l.startTag) && parseInt(tag) <= parseInt(l.endTag));
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

document.getElementById('troubleshootBtn').addEventListener('click', () => {
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

// Init
setCurrentDateTime();
updateDataLists();
updateSyncBadge();
updateDailySummary();
updateChuteBanner();
if (navigator.onLine) processSyncQueue();
checkDailySync();