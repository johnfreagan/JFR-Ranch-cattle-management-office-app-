// =========================================================
// Tally Book — JFR Ranch
//
// The "JFR Tally Book" artifact, ported onto Supabase. The app itself is
// unchanged — day page, migration ritual, delegation, collections,
// trackers, repeats, voice capture. What changed is where it keeps things:
// the artifact rebuilt and republished its own HTML with the state baked
// into it, which meant the book lived in one browser's localStorage and
// the published copy stayed empty.
//
// Now: localStorage is the local cache, Supabase is the record.
//   tally_days  — one row per day
//   tally_book  — colls, months, rules, people, inbox, trackers,
//                 track, settings, lots
// Both RLS-scoped to auth.uid(). Schema: docs/sql/2026-08-28_tally_book_v2.sql
// =========================================================

const SUPABASE_URL = 'https://xpfmebdzcxorvwikfvtj.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_LhyJ7-bxebSa7HuRTxjmBQ__73Oc-66';

/* Shown in More. Two days were lost to "is this device actually on the new
   code?" - a question nobody could answer from the phone. Bump it with the
   ?v= strings and CACHE_VERSION. */
const APP_VERSION = 'v7';

var TB_USER_ID = null;

// If the library did not load, every handler below is inert while the page
// still renders — which reads as a broken app rather than a failed load.
// Same guard, same reason, as the field app.
if (!window.supabase || typeof window.supabase.createClient !== 'function') {
    document.addEventListener('DOMContentLoaded', function () {
        var b = document.getElementById('bootError');
        if (b) {
            b.textContent = 'The Supabase library did not load. Check your connection and reload.';
            b.hidden = false;
        }
    });
    throw new Error('Supabase library not available');
}

// Default storage key on purpose: the office app, the field app and this one
// share an origin, so one sign-in covers all three. Sign-out does too, and
// the button says so.
var sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true }
});

(function () {
    'use strict';

    var $ = function (id) { return document.getElementById(id); };
    var booted = false;

    // IndexedDB and localStorage know nothing about RLS. A cache left behind
    // by one account is readable by the next person to sign in on this
    // device, so both local stores go on sign-out AND on a user change.
    var WHO = 'jfr-tally-who';
    function purgeLocal() {
        try {
            localStorage.removeItem('jfr-tally-book-v1');
            localStorage.removeItem('jfr-tally-synced-v1');
            sessionStorage.removeItem('jfr-tally-resume');
        } catch (e) { /* private window */ }
    }
    function checkOwner(uid) {
        var prev = null;
        try { prev = localStorage.getItem(WHO); } catch (e) { /* ignore */ }
        if (prev && prev !== uid) purgeLocal();
        try { localStorage.setItem(WHO, uid); } catch (e) { /* ignore */ }
    }

    function showLogin() {
        $('loginView').hidden = false;
        $('bookView').hidden = true;
        $('loginEmail').focus();
    }

    function enterBook(uid) {
        TB_USER_ID = uid;
        checkOwner(uid);
        $('loginView').hidden = true;
        $('bookView').hidden = false;
        // Boot paints from the local cache first so the book is on screen
        // immediately, then the sync fills in whatever another device wrote.
        if (!booted) { window.__bootTallyBook(); booted = true; }
        if (window.__tallySync) window.__tallySync(true);
    }

    async function onSignIn(e) {
        e.preventDefault();
        var btn = $('loginBtn'), err = $('loginError');
        err.textContent = '';
        btn.disabled = true;
        btn.textContent = 'Signing in…';

        var res = await sb.auth.signInWithPassword({
            email: $('loginEmail').value.trim(),
            password: $('loginPassword').value
        });

        btn.disabled = false;
        btn.textContent = 'Sign in';

        if (res.error) { err.textContent = res.error.message || 'Sign-in failed.'; return; }
        $('loginPassword').value = '';
        enterBook(res.data.user.id);
    }

    async function onSignOut() {
        if (!confirm('Sign out? This signs you out of all JFR Ranch apps on this device, '
                   + 'and clears the copy of the book cached here.')) return;
        // Push anything still pending before the local copy goes, or an entry
        // made in the last few seconds dies with the cache.
        try { if (window.__tallySync) await window.__tallySync(false); } catch (e) { /* reported already */ }
        await sb.auth.signOut();
        purgeLocal();
        try { localStorage.removeItem(WHO); } catch (e) { /* ignore */ }
        // Reload rather than un-wire: the book binds its handlers once on
        // boot, and tearing that down by hand is more ways to be wrong.
        location.reload();
    }

    document.addEventListener('DOMContentLoaded', async function () {
        $('loginForm').addEventListener('submit', onSignIn);
        $('signOutBtn').addEventListener('click', onSignOut);

        var vn = $('verNote');
        if (vn) vn.textContent = 'Version ' + APP_VERSION;

        /* iOS keeps an installed PWA's service worker alive well past the
           point the site has moved on, and the only reliable cure was
           deleting the home-screen icon. This does it from inside: drop the
           worker and its caches, then reload. It deliberately does NOT touch
           localStorage - that is the book, not the code. */
        var fu = $('mForce');
        if (fu) fu.onclick = async function () {
            fu.disabled = true;
            try {
                if ('serviceWorker' in navigator) {
                    var regs = await navigator.serviceWorker.getRegistrations();
                    await Promise.all(regs.map(function (r) { return r.unregister(); }));
                }
                if (window.caches) {
                    var keys = await caches.keys();
                    await Promise.all(keys.map(function (k) { return caches.delete(k); }));
                }
            } catch (e) { /* reload anyway - a stale worker is the thing we are escaping */ }
            location.reload();
        };

        if ('serviceWorker' in navigator) {
            navigator.serviceWorker.register('sw.js').catch(function () {});
        }

        var s = await sb.auth.getSession();
        if (s.data.session && s.data.session.user) enterBook(s.data.session.user.id);
        else showLogin();
    });

    window.addEventListener('online', function () {
        if (TB_USER_ID && window.__tallySync) window.__tallySync(true);
    });
})();


/* ---------------- the book ----------------
   The artifact's app, unchanged except for where it stores things.
   It ran itself on load; here it waits for a session, because the
   book is scoped to auth.uid() and painting an empty one to a
   signed-out user looks like data loss rather than a login screen. */
window.__bootTallyBook = function () {
  "use strict";

  /* ---------------- helpers ---------------- */
  var $ = function (id) { return document.getElementById(id); };
  function el(tag, cls, txt) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (txt != null) n.textContent = txt;
    return n;
  }
  function uid() { return Math.random().toString(36).slice(2, 9) + Date.now().toString(36).slice(-4); }
  function pad(n) { return n < 10 ? "0" + n : "" + n; }
  function key(d) { return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()); }
  function parseKey(k) { var p = k.split("-"); return new Date(+p[0], +p[1] - 1, +p[2]); }
  function addDays(k, n) { var d = parseKey(k); d.setDate(d.getDate() + n); return key(d); }
  function addMonths(k, n) {
    var d = parseKey(k), day = d.getDate();
    d.setDate(1); d.setMonth(d.getMonth() + n);
    var last = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
    d.setDate(Math.min(day, last));
    return key(d);
  }  var WEEK = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  var MON = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

  /* ---------------- state ---------------- */
  var LS = "jfr-tally-book-v1";

  /* localStorage is the LOCAL CACHE, not the record. It paints instantly and
     it is what keeps the book usable with no signal; Supabase is the durable
     copy and the thing that reaches the other device. The artifact read a
     state blob embedded in its own published page - there is no such blob
     here, because the page is served from GitHub Pages and the data is not
     in it. */
  var state = { v: 1, updatedAt: "1970-01-01T00:00:00.000Z", days: {}, colls: [], lots: null, settings: {} };
  try {
    var local = JSON.parse(localStorage.getItem(LS) || "null");
    if (local && local.days) state = local;
  } catch (e) { /* ignore - a corrupt cache must not brick the book */ }
  state.days = state.days || {};
  state.colls = state.colls || [];
  state.months = state.months || {};   /* "2026-09" — this month, no day picked */
  state.rules = state.rules || [];     /* repeating entries */
  state.people = state.people || [];   /* who you hand things to */
  state.inbox = state.inbox || [];     /* unfiled capture — no day picked */
  state.trackers = state.trackers || [{ id: "rain", name: "Rain", unit: "in", kind: "num" }];
  state.track = state.track || {};     /* "2026-08-20": {rain: 1.1} */
  state.settings = state.settings || {};
  if (state.settings.auto == null) state.settings.auto = true;
  if (state.settings.size == null) state.settings.size = 1;

  var SIZES = [
    { v: 1, name: "regular" },
    { v: 1.12, name: "large" },
    { v: 1.24, name: "larger" },
    { v: 1.36, name: "largest" }
  ];
  function applySize() {
    var s = state.settings.size || 1;
    document.documentElement.style.setProperty("--s", String(s));
    var m = SIZES.filter(function (x) { return Math.abs(x.v - s) < 0.001; })[0];
    var lab = $("mSizeV");
    if (lab) lab.textContent = m ? m.name : s.toFixed(2) + "×";
  }
  applySize();

  var today = key(new Date());
  var sel = today;
  var view = "day";
  var capType = "task";
  var capPrio = false;
  var capUnfiled = false;

  var RESUME = "jfr-tally-resume";
  var resume = null;
  try {
    resume = JSON.parse(sessionStorage.getItem(RESUME) || "null");
    sessionStorage.removeItem(RESUME);
  } catch (e) { /* ignore */ }
  if (resume && resume.sel) sel = resume.sel;
  if (resume && resume.view && resume.view !== "panel") view = resume.view;

  var syncedAt = state.updatedAt;
  var syncing = false, autoOff = false, lastSyncAt = 0;
  var lastStamp = (resume && resume.stamp) || "";
  var idleT = null;
  var SYNC_IDLE = 20000, SYNC_GAP = 45000;

  function touch() {
    state.updatedAt = new Date().toISOString();
    try { localStorage.setItem(LS, JSON.stringify(state)); } catch (e) { /* quota */ }
    paintDot();
    scheduleAuto();
  }
  function day(k) {
    if (!state.days[k]) state.days[k] = { entries: [], reflect: "" };
    return state.days[k];
  }
  function mKey(k) { return k.slice(0, 7); }
  function month(mk) {
    if (!state.months[mk]) state.months[mk] = { entries: [] };
    return state.months[mk];
  }
  function monthLabel(mk) {
    var p = mk.split("-");
    return MON[+p[1] - 1] + " " + p[0];
  }
  function addMonthKey(mk, n) {
    var p = mk.split("-"), d = new Date(+p[0], +p[1] - 1 + n, 1);
    return d.getFullYear() + "-" + pad(d.getMonth() + 1);
  }
  function openOf(k) {
    var r = state.days[k];
    return r ? r.entries.filter(function (e) { return e.type !== "note" && e.st === 0; }).length : 0;
  }

  /* ---------------- order & groups ---------------- */
  function ensureOrd(rec) {
    var need = rec.entries.some(function (e) { return typeof e.ord !== "number"; });
    if (!need) return;
    rec.entries.slice().sort(function (a, b) {
      if (!!a.time !== !!b.time) return a.time ? -1 : 1;
      if (a.time && b.time && a.time !== b.time) return a.time < b.time ? -1 : 1;
      return 0;
    }).forEach(function (e, i) { if (typeof e.ord !== "number") e.ord = i * 10; });
  }
  function nextOrd(rec) {
    var max = -10;
    rec.entries.forEach(function (e) { if (typeof e.ord === "number" && e.ord > max) max = e.ord; });
    return max + 10;
  }
  function groupsOf(rec) { return rec.groups || (rec.groups = []); }
  function sortEntries(rec, list) {
    var gs = groupsOf(rec);
    return list.sort(function (a, b) {
      var ga = a.grp ? gs.indexOf(a.grp) + 1 : 0;
      var gb = b.grp ? gs.indexOf(b.grp) + 1 : 0;
      if (ga !== gb) return ga - gb;
      return (a.ord || 0) - (b.ord || 0);
    });
  }
  /* swap with the neighbour that shares its group */
  function moveEntry(e, dir) {
    var rec = day(sel);
    ensureOrd(rec);
    var sibs = sortEntries(rec, rec.entries.filter(function (x) {
      return x.st !== 4 && (x.grp || null) === (e.grp || null);
    }));
    var i = sibs.indexOf(e), j = i + dir;
    if (i < 0 || j < 0 || j >= sibs.length) return false;
    var a = e.ord, b = sibs[j].ord;
    e.ord = b; sibs[j].ord = a;
    touch(); paintAll();
    return true;
  }

  /* ---------------- when parsing ----------------
     "friday 7:30 load out" / "8/24 vet" / "tomorrow 2pm" — the date and time
     are lifted out of what you typed, the rest stays as the entry text. */
  var WD = { sun: 0, sunday: 0, mon: 1, monday: 1, tue: 2, tues: 2, tuesday: 2, wed: 3, weds: 3, wednesday: 3, thu: 4, thur: 4, thurs: 4, thursday: 4, fri: 5, friday: 5, sat: 6, saturday: 6 };
  var MO = { jan: 0, january: 0, feb: 1, february: 1, mar: 2, march: 2, apr: 3, april: 3, may: 4, jun: 5, june: 5, jul: 6, july: 6, aug: 7, august: 7, sep: 8, sept: 8, september: 8, oct: 9, october: 9, nov: 10, november: 10, dec: 11, december: 11 };

  function fromParts(base, y, m, d) {
    var bd = parseKey(base);
    if (y == null) {
      y = bd.getFullYear();
      var cand = new Date(y, m, d);
      if ((bd - cand) / 86400000 > 180) y += 1;
      else if ((cand - bd) / 86400000 > 300) y -= 1;
    } else if (y < 100) y += 2000;
    var dt = new Date(y, m, d);
    if (isNaN(dt) || dt.getMonth() !== m || dt.getDate() !== d) return null;
    return key(dt);
  }

  function parseWhen(text, base) {
    var rest = String(text), date = null, time = null;
    function eat(re, fn) {
      var m = rest.match(re);
      if (!m) return false;
      if (fn(m) === false) return false;
      rest = (rest.slice(0, m.index) + " " + rest.slice(m.index + m[0].length)).replace(/\s{2,}/g, " ").trim();
      return true;
    }
    eat(/\b(\d{4})-(\d{1,2})-(\d{1,2})\b/, function (m) {
      date = fromParts(base, +m[1], +m[2] - 1, +m[3]);
      return date !== null;
    }) ||
      /* a slash date only counts at the start or end of the line —
         mid-sentence "3/4" is a fraction, not March 4th */
      eat(/\b(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?\b/, function (m) {
        if (m.index !== 0 && m.index + m[0].length !== rest.length) return false;
        date = fromParts(base, m[3] ? +m[3] : null, +m[1] - 1, +m[2]);
        return date !== null;
      }) ||
      eat(/\b(jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b/i, function (m) {
        date = fromParts(base, null, MO[m[1].toLowerCase()], +m[2]);
        return date !== null;
      }) ||
      eat(/\b(\d{1,2})(?:st|nd|rd|th)?\s+(jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)\b/i, function (m) {
        date = fromParts(base, null, MO[m[2].toLowerCase()], +m[1]);
        return date !== null;
      }) ||
      eat(/\b(today|tonight|tomorrow|tmrw|tmw)\b/i, function (m) {
        var w = m[1].toLowerCase();
        date = (w === "tomorrow" || w === "tmrw" || w === "tmw") ? addDays(base, 1) : base;
        return true;
      }) ||
      eat(/\b(?:next\s+)?(sun|sunday|mon|monday|tue|tues|tuesday|wed|weds|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday)\b/i, function (m) {
        var want = WD[m[1].toLowerCase()], have = parseKey(base).getDay();
        var ahead = (want - have + 7) % 7;
        date = addDays(base, ahead === 0 ? 7 : ahead);
        return true;
      });

    eat(/\b(\d{1,2}):(\d{2})\s*(am|pm)?\b/i, function (m) {
      var h = +m[1], mm = m[2], ap = (m[3] || "").toLowerCase();
      if (ap === "pm" && h < 12) h += 12;
      if (ap === "am" && h === 12) h = 0;
      if (h > 23 || +mm > 59) return false;
      time = pad(h) + ":" + mm;
      return true;
    }) ||
      eat(/\b(\d{1,2})\s*(am|pm)\b/i, function (m) {
        var h = +m[1], ap = m[2].toLowerCase();
        if (h > 12) return false;
        if (ap === "pm" && h < 12) h += 12;
        if (ap === "am" && h === 12) h = 0;
        time = pad(h) + ":00";
        return true;
      });

    return { date: date, time: time, rest: rest.replace(/^[\s,;:–—-]+|[\s,;:–—-]+$/g, "") };
  }

  /* ---------------- repeats ----------------
     "every friday", "every day", "every weekday", "every other tuesday",
     "every 2 weeks", "monthly" — lifted out before the date parser runs, so
     "every friday" makes a rule instead of a one-off next Friday. */
  var DOWNAME = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

  function parseRepeat(text) {
    var rest = String(text), freq = null;
    function eat(re, fn) {
      var m = rest.match(re);
      if (!m) return false;
      if (fn(m) === false) return false;
      rest = (rest.slice(0, m.index) + " " + rest.slice(m.index + m[0].length)).replace(/\s{2,}/g, " ").trim();
      return true;
    }
    var DOW = "sun|sunday|mon|monday|tue|tues|tuesday|wed|weds|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday";

    eat(/\b(every\s+day|daily|each\s+day)\b/i, function () {
      freq = { kind: "daily", interval: 1, dow: [] };
      return true;
    }) ||
      eat(/\b(every\s+weekday|weekdays|each\s+weekday)\b/i, function () {
        freq = { kind: "weekly", interval: 1, dow: [1, 2, 3, 4, 5] };
        return true;
      }) ||
      eat(new RegExp("\\bevery\\s+other\\s+(" + DOW + ")\\b", "i"), function (m) {
        freq = { kind: "weekly", interval: 2, dow: [WD[m[1].toLowerCase()]] };
        return true;
      }) ||
      eat(new RegExp("\\bevery\\s+(" + DOW + ")(?:\\s+and\\s+(" + DOW + "))?\\b", "i"), function (m) {
        var d = [WD[m[1].toLowerCase()]];
        if (m[2]) d.push(WD[m[2].toLowerCase()]);
        freq = { kind: "weekly", interval: 1, dow: d };
        return true;
      }) ||
      eat(/\bevery\s+(\d{1,2})\s+days?\b/i, function (m) {
        var n = +m[1];
        if (n < 1 || n > 60) return false;
        freq = { kind: "daily", interval: n, dow: [] };
        return true;
      }) ||
      eat(/\bevery\s+(\d{1,2})\s+weeks?\b/i, function (m) {
        var n = +m[1];
        if (n < 1 || n > 26) return false;
        freq = { kind: "weekly", interval: n, dow: [] };
        return true;
      }) ||
      eat(/\b(every\s+week|weekly)\b/i, function () {
        freq = { kind: "weekly", interval: 1, dow: [] };
        return true;
      }) ||
      eat(/\b(every\s+month|monthly)\b/i, function () {
        freq = { kind: "monthly", interval: 1, dow: [] };
        return true;
      });

    return { freq: freq, rest: rest.replace(/^[\s,;:–—-]+|[\s,;:–—-]+$/g, "") };
  }

  function freqLabel(f) {
    if (!f) return "";
    if (f.kind === "daily") return f.interval === 1 ? "every day" : "every " + f.interval + " days";
    if (f.kind === "monthly") return "monthly";
    if (f.dow.length === 5 && f.dow.indexOf(1) >= 0 && f.dow.indexOf(5) >= 0) return "every weekday";
    if (!f.dow.length) return f.interval === 1 ? "every week" : "every " + f.interval + " weeks";
    var names = f.dow.map(function (d) { return DOWNAME[d].slice(0, 3); }).join(" & ");
    return (f.interval === 2 ? "every other " : "every ") + names;
  }

  function ruleMatches(rule, k) {
    if (k < rule.start) return false;
    var d = parseKey(k), s = parseKey(rule.start);
    var days = Math.round((d - s) / 86400000);
    var f = rule.freq;
    if (f.kind === "daily") return days % f.interval === 0;
    if (f.kind === "monthly") return d.getDate() === s.getDate();
    if (f.dow.length) {
      if (f.dow.indexOf(d.getDay()) < 0) return false;
      if (f.interval === 1) return true;
      return Math.floor(days / 7) % f.interval === 0;
    }
    return days % (7 * f.interval) === 0;
  }

  function skipRule(rid, k) {
    var rule = state.rules.filter(function (r) { return r.id === rid; })[0];
    if (!rule) return;
    rule.skips = rule.skips || [];
    if (rule.skips.indexOf(k) < 0) rule.skips.push(k);
  }

  /* fill the next month of days from the rules, without creating empty days */
  function materialize() {
    if (!state.rules.length) return;
    var last = addDays(today, 32);
    if (sel > last) last = addDays(sel, 3);
    state.rules.forEach(function (rule) {
      var k = rule.start > today ? rule.start : today;
      var guard = 0;
      while (k <= last && guard++ < 400) {
        if (ruleMatches(rule, k) && !(rule.skips && rule.skips.indexOf(k) >= 0)) {
          var rec = state.days[k];
          var already = rec && rec.entries.some(function (e) { return e.rid === rule.id; });
          if (!already) {
            day(k).entries.push({
              id: uid(), rid: rule.id, type: rule.type || "task", text: rule.text,
              st: 0, prio: !!rule.prio, time: rule.time || null
            });
          }
        }
        k = addDays(k, 1);
      }
    });
  }

  function whenLabel(k, t) {
    var d = parseKey(k), bits;
    if (k === today) bits = "today";
    else if (k === addDays(today, 1)) bits = "tomorrow";
    else if (k === addDays(today, -1)) bits = "yesterday";
    else bits = WEEK[d.getDay()].slice(0, 3) + " " + d.getDate() + " " + MON[d.getMonth()].slice(0, 3);
    return t ? bits + " · " + t : bits;
  }

  /* ---------------- toast ---------------- */
  var toastT;
  function toast(msg) {
    var t = $("toast");
    t.textContent = msg;
    t.classList.add("up");
    clearTimeout(toastT);
    toastT = setTimeout(function () { t.classList.remove("up"); }, 2400);
  }

  /* ---------------- view switching ---------------- */
  var VIEWS = ["day", "loops", "lots", "month", "lists", "notes", "more", "panel", "search", "migrate"];
  var TABOF = { notes: "day", panel: "more", search: "month", migrate: "loops" };
  var seg = "cal", lseg = "inbox";
  function lsegTo(l) {
    lseg = l;
    ["inbox", "colls", "who"].forEach(function (x) {
      var n = $("l-" + x);
      if (n) n.hidden = x !== l;
    });
    [].forEach.call($("listSeg").children, function (b) {
      b.setAttribute("aria-selected", String(b.getAttribute("data-l") === l));
    });
    if (view === "lists") paintTop();
  }
  function segTo(p) {
    seg = p;
    ["cal", "tasks", "future", "track"].forEach(function (x) {
      var n = $("p-" + x);
      if (n) n.hidden = x !== p;
    });
    [].forEach.call($("monthSeg").children, function (b) {
      b.setAttribute("aria-selected", String(b.getAttribute("data-p") === p));
    });
  }
  function show(v) {
    view = v;
    VIEWS.forEach(function (x) {
      var n = $("v-" + x);
      if (!n) return;
      var on = x === v;
      n.hidden = !on;
      if (on) { n.classList.remove("in"); void n.offsetWidth; n.classList.add("in"); n.scrollTop = 0; }
    });
    [].forEach.call($("tabs").children, function (t) {
      var d = t.getAttribute("data-v");
      t.setAttribute("aria-selected", String(d === v || TABOF[v] === d));
    });
    $("capture").hidden = v !== "day";
    paintTop();
  }

  /* ---------------- top bar ---------------- */
  function act(label, fn, title) {
    var b = el("button", "ghost", label);
    if (title) b.title = title;
    b.onclick = fn;
    return b;
  }

  var ICON = {
    prev: '<path d="M15 5l-7 7 7 7"/>',
    next: '<path d="M9 5l7 7-7 7"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="M20.5 20.5L16.6 16.6"/>'
  };
  function iconAct(name, fn, title) {
    var b = el("button", "ghost ico");
    b.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" ' +
      'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + ICON[name] + '</svg>';
    b.title = title || "";
    b.setAttribute("aria-label", title || name);
    b.onclick = fn;
    return b;
  }
  function paintDot() {
    var d = $("syncDot");
    if (!d) return;
    var dirty = state.updatedAt > syncedAt;
    d.className = "dot" + (syncing ? "" : dirty ? " dirty" : " ok");
    d.title = syncing ? "Syncing…" : dirty ? "Not yet on your other devices" : lastStamp ? "Synced " + lastStamp : "Synced";
    var note = $("syncNote");
    if (note) {
      note.textContent = autoOff ? "Sync isn't available in this view — the book is saved on this device only."
        : dirty ? (state.settings.auto ? "Changes go to your other devices shortly." : "Tap the dot to sync now.")
          : lastStamp ? "Everything synced at " + lastStamp + "." : "Everything synced.";
    }
  }
  function paintTop() {
    var eb = $("eyebrow"), ti = $("title"), ac = $("topAct");
    ac.innerHTML = "";
    var d = parseKey(sel);

    if (view === "day") {
      eb.textContent = WEEK[d.getDay()] + (sel === today ? " · today" : "");
      ti.innerHTML = "";
      ti.appendChild(document.createTextNode(d.getDate() + " "));
      var m = el("span", "dim", MON[d.getMonth()]);
      ti.appendChild(m);
      ac.appendChild(iconAct("prev", function () { sel = addDays(sel, -1); paintAll(); }, "Previous day"));
      if (sel !== today) ac.appendChild(act("today", function () { sel = today; paintAll(); }));
      ac.appendChild(iconAct("next", function () { sel = addDays(sel, 1); paintAll(); }, "Next day"));
    } else if (view === "loops") {
      eb.textContent = "open loops";
      ti.textContent = "Unfinished";
      ac.appendChild(act("migrate", startMigration, "Walk each one and decide"));
    } else if (view === "search") {
      eb.textContent = "index";
      ti.textContent = "Search";
      ac.appendChild(act("‹ back", function () { show("month"); }));
    } else if (view === "migrate") {
      eb.textContent = "migration";
      ti.textContent = "Carry over";
      ac.appendChild(act("‹ stop", function () { paintAll(); show("loops"); }));
    } else if (view === "lots") {
      eb.textContent = "lot summary";
      ti.textContent = state.lots && state.lots.rows && state.lots.rows.length ? "Cattle on feed" : "No lot data";
      ac.appendChild(act("load", openLots));
    } else if (view === "month") {
      eb.textContent = "month";
      ti.textContent = MON[d.getMonth()] + " " + d.getFullYear();
      ac.appendChild(iconAct("prev", function () { sel = addMonths(sel, -1); paintAll(); }, "Previous month"));
      ac.appendChild(iconAct("next", function () { sel = addMonths(sel, 1); paintAll(); }, "Next month"));
    } else if (view === "lists") {
      eb.textContent = lseg === "who" ? "delegation" : lseg === "inbox" ? "capture" : "collections";
      ti.textContent = lseg === "who" ? "Waiting on" : lseg === "inbox" ? "Inbox" : "Lists";
      if (lseg === "colls") ac.appendChild(act("+ new", newList));
    } else if (view === "notes") {
      eb.textContent = d.getDate() + " " + MON[d.getMonth()];
      ti.textContent = "End of day";
      ac.appendChild(act("‹ day", function () { show("day"); }));
    } else if (view === "more") {
      eb.textContent = "tally book";
      ti.textContent = "More";
    } else if (view === "panel") {
      eb.textContent = panelEyebrow;
      ti.textContent = panelTitle;
      ac.appendChild(act("‹ back", function () { show("more"); }));
      if (panelAction) {
        var pa = act(panelAction.label, panelAction.run);
        pa.id = "topActPrimary";
        ac.appendChild(pa);
      }
    }

    if (view !== "search" && view !== "migrate" && view !== "panel") {
      ac.appendChild(iconAct("search", function () {
        show("search");
        setTimeout(function () { $("qText").focus(); }, 60);
      }, "Search everything"));
    }

    var dot = el("button", "dot");
    dot.id = "syncDot";
    dot.onclick = function () { sync(false); };
    ac.appendChild(dot);
    paintDot();
  }

  /* ---------------- day view ---------------- */
  var SIG = { task: ["•", "×", "›", "~", "→"], event: ["○", "×", "›", "~", "→"], note: ["–", "–", "–", "~", "→"] };
  var STCLASS = ["", " done", " moved", " struck", " handed"];

  function paintDayView() {
    var rec = day(sel);
    ensureOrd(rec);
    var entries = sortEntries(rec, rec.entries.filter(function (e) { return e.st !== 4; }));
    var open = entries.filter(function (e) { return e.type !== "note" && e.st === 0; }).length;
    var done = entries.filter(function (e) { return e.st === 1; }).length;

    var n = $("pulseN");
    n.textContent = open;
    n.className = "n" + (open ? "" : " clear");
    $("pulseLab").innerHTML = open
      ? "<b>" + (open === 1 ? "thing open" : "things open") + "</b>" + (done ? done + " done" : "on today's page")
      : "<b>" + (entries.length ? "all clear" : "empty page") + "</b>" + (done ? done + " done" : "nothing logged yet");

    $("dayLabel").textContent = sel === today ? "Today's page" : parseKey(sel).getDate() + " " + MON[parseKey(sel).getMonth()];

    var box = $("log"); box.innerHTML = "";
    if (!entries.length) {
      var em = el("div", "empty");
      em.innerHTML = "Capture below — <b>tasks</b>, <b>events</b> and <b>notes</b> all land on this page.";
      box.appendChild(em);
      return;
    }
    var lastGrp = null;
    entries.forEach(function (e) {
      var g = e.grp || null;
      if (g !== lastGrp) {
        lastGrp = g;
        if (g) {
          var gh = el("div", "grp-head");
          gh.appendChild(el("span", null, g));
          gh.appendChild(el("span", "gline"));
          var ung = el("button", null, "ungroup");
          ung.title = "Remove this grouping";
          ung.onclick = function () {
            rec.entries.forEach(function (x) { if (x.grp === g) x.grp = null; });
            var gs = groupsOf(rec);
            if (gs.indexOf(g) >= 0) gs.splice(gs.indexOf(g), 1);
            touch(); paintAll();
          };
          gh.appendChild(ung);
          box.appendChild(gh);
        }
      }
      var wrap = el("div", "entry-wrap");
      wrap.dataset.eid = e.id;
      wrap.dataset.grp = e.grp || "";
      var row = el("div", "entry " + e.type + (STCLASS[e.st] || "") + (e.prio ? " prio" : ""));
      var b = el("button", "bullet", SIG[e.type][e.st] || "•");
      b.title = e.type === "note" ? "Toggle priority" : "open → done → migrated";
      b.onclick = function () { cycle(e); };
      row.appendChild(b);
      if (e.time) row.appendChild(el("span", "when", e.time));
      var t = el("div", "txt", e.text);
      t.contentEditable = "true";
      t.spellcheck = false;
      t.onblur = function () {
        var v = t.textContent.trim();
        if (!v) { t.textContent = e.text; return; }
        if (v !== e.text) { e.text = v; touch(); }
      };
      t.onkeydown = function (ev) { if (ev.key === "Enter") { ev.preventDefault(); t.blur(); } };
      row.appendChild(t);

      if (e.rid) {
        var rp = el("span", "rep", "↻");
        rp.title = "Repeats";
        row.appendChild(rp);
      }
      if (e.subs && e.subs.length) {
        var doneN = e.subs.filter(function (x) { return x.done; }).length;
        row.appendChild(el("span", "meta", doneN + "/" + e.subs.length));
      }

      var more = el("button", "more", "⋯");
      more.title = "Steps, hand off, reorder";
      more.setAttribute("aria-expanded", "false");
      more.onclick = function () {
        var open = wrap.querySelector(".acts");
        if (open) { open.remove(); more.setAttribute("aria-expanded", "false"); return; }
        more.setAttribute("aria-expanded", "true");
        wrap.appendChild(actionBar(e, wrap));
      };
      row.appendChild(more);

      var grip = el("button", "grip");
      grip.innerHTML = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">' +
        '<circle cx="9" cy="6" r="1.7"/><circle cx="15" cy="6" r="1.7"/>' +
        '<circle cx="9" cy="12" r="1.7"/><circle cx="15" cy="12" r="1.7"/>' +
        '<circle cx="9" cy="18" r="1.7"/><circle cx="15" cy="18" r="1.7"/></svg>';
      grip.title = "Drag to reorder";
      grip.setAttribute("aria-label", "Drag to reorder");
      grip.addEventListener("pointerdown", function (ev) { startDrag(ev, wrap, e); });
      row.appendChild(grip);
      wrap.appendChild(row);
      if (e.subs && e.subs.length) wrap.appendChild(subList(e));
      box.appendChild(wrap);
    });
  }

  /* ---------------- drag to reorder ----------------
     Pointer events with capture, so a drag that starts on the grip can't be
     stolen by the scroller. Only siblings in the same group can swap. */
  var drag = null;

  function startDrag(ev, wrap, e) {
    if (ev.button != null && ev.button !== 0) return;
    ev.preventDefault();
    var view = $("v-day");
    var sibs = [].filter.call($("log").children, function (n) {
      return n.classList.contains("entry-wrap") && n.dataset.grp === wrap.dataset.grp;
    });
    if (sibs.length < 2) { toast("Nothing to reorder here"); return; }

    drag = { wrap: wrap, e: e, sibs: sibs, view: view, y: ev.clientY, scroller: null };
    wrap.classList.add("lifted");
    $("log").classList.add("dragging-list");
    try { ev.target.setPointerCapture(ev.pointerId); } catch (err) { /* ignore */ }

    var move = function (mv) {
      if (!drag) return;
      mv.preventDefault();
      var y = mv.clientY;
      drag.y = y;

      /* nudge the pane when you drag near its edges */
      var r = view.getBoundingClientRect();
      var edge = 56;
      var speed = y < r.top + edge ? -12 : y > r.bottom - edge ? 12 : 0;
      if (speed && !drag.scroller) {
        drag.scroller = setInterval(function () { view.scrollTop += drag.speed || 0; }, 16);
      }
      drag.speed = speed;
      if (!speed && drag.scroller) { clearInterval(drag.scroller); drag.scroller = null; }

      var cur = [].filter.call($("log").children, function (n) {
        return n.classList.contains("entry-wrap") && n.dataset.grp === wrap.dataset.grp;
      });
      for (var i = 0; i < cur.length; i++) {
        var n = cur[i];
        if (n === wrap) continue;
        var b = n.getBoundingClientRect();
        var mid = b.top + b.height / 2;
        if (y < mid && n.compareDocumentPosition(wrap) & Node.DOCUMENT_POSITION_FOLLOWING) {
          n.parentNode.insertBefore(wrap, n);
          break;
        }
        if (y > mid && n.compareDocumentPosition(wrap) & Node.DOCUMENT_POSITION_PRECEDING) {
          n.parentNode.insertBefore(wrap, n.nextSibling);
          break;
        }
      }
    };

    var end = function () {
      if (!drag) return;
      if (drag.scroller) clearInterval(drag.scroller);
      document.removeEventListener("pointermove", move);
      document.removeEventListener("pointerup", end);
      document.removeEventListener("pointercancel", end);
      wrap.classList.remove("lifted");
      $("log").classList.remove("dragging-list");

      /* read the DOM back into ord values for this group */
      var rec = day(sel);
      ensureOrd(rec);
      var order = [].filter.call($("log").children, function (n) {
        return n.classList.contains("entry-wrap") && n.dataset.grp === wrap.dataset.grp;
      }).map(function (n) { return n.dataset.eid; });
      var pool = rec.entries.filter(function (x) {
        return x.st !== 4 && (x.grp || "") === wrap.dataset.grp;
      });
      var slots = pool.map(function (x) { return x.ord; }).sort(function (a, b) { return a - b; });
      order.forEach(function (id, i) {
        var ent = pool.filter(function (x) { return x.id === id; })[0];
        if (ent && slots[i] != null) ent.ord = slots[i];
      });
      drag = null;
      touch(); paintAll();
    };

    document.addEventListener("pointermove", move, { passive: false });
    document.addEventListener("pointerup", end);
    document.addEventListener("pointercancel", end);
  }

  /* ---------------- per-entry actions ---------------- */
  function actionBar(e, wrap) {
    var bar = el("div", "acts");
    function act2(label, fn) {
      var b = el("button", null, label);
      b.onclick = fn;
      bar.appendChild(b);
      return b;
    }
    if (e.type !== "note") act2("+ step", function () { bar.remove(); addSub(e, wrap); });
    if (e.type !== "note") act2("→ hand off", function () { handOff(e); });
    act2("↑ up", function () { if (!moveEntry(e, -1)) toast("Already at the top"); });
    act2("↓ down", function () { if (!moveEntry(e, 1)) toast("Already at the bottom"); });
    act2(e.grp ? "▤ " + e.grp : "▤ group", function () { groupPicker(e); });
    var del = act2("× delete", function () {
      var arr = day(sel).entries;
      arr.splice(arr.indexOf(e), 1);
      if (e.rid) skipRule(e.rid, sel);
      touch(); paintAll();
    });
    del.className = "danger";
    return bar;
  }

  function groupPicker(e) {
    var rec = day(sel), inp;
    panel("today's page", "Group", {
      label: "make group", run: function () {
        var v = inp.value.trim();
        if (!v) return;
        setGroup(e, v);
      }
    }, function (body) {
      var p = el("p", "mnote", "Cluster related work under a heading — “work the north trap”, “shop”, “corn”. Grouped items sort together on the page.");
      p.style.padding = "0 0 8px";
      body.appendChild(p);
      var gs = groupsOf(rec);
      if (gs.length) {
        gs.forEach(function (g) {
          var b = el("button", "mrow");
          b.appendChild(el("span", "mk", g));
          b.appendChild(el("span", "chev", "›"));
          b.onclick = function () { setGroup(e, g); };
          body.appendChild(b);
        });
      }
      if (e.grp) {
        var out = el("button", "mrow");
        out.appendChild(el("span", "mk", "Take out of " + e.grp));
        out.appendChild(el("span", "chev", "›"));
        out.onclick = function () { setGroup(e, null); };
        body.appendChild(out);
      }
      var lab = el("p", "mnote", "New group");
      lab.style.padding = "14px 0 6px";
      body.appendChild(lab);
      inp = el("input", "field");
      inp.placeholder = "north trap";
      body.appendChild(inp);
    });
  }

  function setGroup(e, g) {
    var rec = day(sel);
    ensureOrd(rec);
    e.grp = g;
    if (g) {
      var gs = groupsOf(rec);
      if (gs.indexOf(g) < 0) gs.push(g);
      /* land it at the bottom of that group so it reads as newest */
      var inGrp = rec.entries.filter(function (x) { return x.grp === g && x !== e; });
      var max = -10;
      inGrp.forEach(function (x) { if (x.ord > max) max = x.ord; });
      e.ord = max + 10;
    }
    touch(); paintAll(); show("day");
    toast(g ? "Grouped under " + g : "Ungrouped");
  }

  /* ---------------- inbox ---------------- */
  function inboxTo(item, fn, msg) {
    fn();
    state.inbox.splice(state.inbox.indexOf(item), 1);
    touch(); paintAll();
    toast(msg);
  }

  function inboxEntry(item, extra) {
    var e = {
      id: uid(), type: item.type || "task", text: item.text, st: 0,
      prio: !!item.prio, time: null, subs: []
    };
    if (extra) for (var k in extra) e[k] = extra[k];
    return e;
  }

  function inboxOptions(item) {
    var dateIn;
    panel("inbox", "Move it out", null, function (body) {
      var p = el("p", "mnote", item.text);
      p.style.cssText = "color:var(--ink);font-size:calc(17px * var(--s));padding:0 0 12px";
      body.appendChild(p);

      function row(label, note, fn) {
        var b = el("button", "mrow");
        b.appendChild(el("span", "mk", label));
        if (note) b.appendChild(el("span", "mv", note));
        b.appendChild(el("span", "chev", "›"));
        b.onclick = fn;
        body.appendChild(b);
      }
      row("Today's page", whenLabel(today, null), function () {
        inboxTo(item, function () {
          var d = day(today);
          d.entries.push(inboxEntry(item, { ord: nextOrd(d) }));
        }, "On today's page");
      });
      row("The day I'm looking at", whenLabel(sel, null), function () {
        inboxTo(item, function () {
          var d = day(sel);
          d.entries.push(inboxEntry(item, { ord: nextOrd(d) }));
        }, "On " + whenLabel(sel, null));
      });
      row("This month", monthLabel(mKey(sel)), function () {
        inboxTo(item, function () {
          month(mKey(sel)).entries.push({ id: uid(), type: "task", text: item.text, st: 0, prio: !!item.prio, time: null });
        }, "Parked in " + monthLabel(mKey(sel)));
      });
      state.colls.forEach(function (c) {
        row("Add to " + c.name, "list", function () {
          inboxTo(item, function () {
            c.items.push({ id: uid(), text: item.text, done: false });
          }, "Added to " + c.name);
        });
      });
      row("Hand off", "someone else", function () {
        var d = day(today);
        var e = inboxEntry(item, { ord: nextOrd(d) });
        d.entries.push(e);
        state.inbox.splice(state.inbox.indexOf(item), 1);
        touch();
        handOff(e);
      });

      var lab = el("p", "mnote", "Or pick a day");
      lab.style.padding = "16px 0 6px";
      body.appendChild(lab);
      var r2 = el("div", "rowflex");
      dateIn = el("input");
      dateIn.type = "date";
      dateIn.className = "datebox";
      dateIn.style.width = "auto";
      dateIn.value = addDays(today, 1);
      r2.appendChild(dateIn);
      var go = el("button", "pill", "move");
      go.onclick = function () {
        var k = dateIn.value;
        if (!k) return;
        inboxTo(item, function () {
          var d = day(k);
          d.entries.push(inboxEntry(item, { ord: nextOrd(d) }));
        }, "On " + whenLabel(k, null));
      };
      r2.appendChild(go);
      body.appendChild(r2);

      var del = el("button", "pull", "delete");
      del.style.marginTop = "18px";
      del.onclick = function () {
        inboxTo(item, function () { }, "Deleted");
      };
      body.appendChild(del);
    });
  }

  function paintInbox() {
    var box = $("inbox");
    if (!box) return;
    box.innerHTML = "";
    var line = $("inboxLine");
    if (state.inbox.length) {
      line.hidden = false;
      $("inboxV").textContent = state.inbox.length + (state.inbox.length === 1 ? " unfiled" : " unfiled");
    } else line.hidden = true;

    if (!state.inbox.length) {
      var em = el("div", "empty");
      em.innerHTML = "Empty. Set the capture chip to <b>inbox</b> and anything you add lands here with no day attached — sort it out when you have a minute.";
      box.appendChild(em);
      return;
    }
    state.inbox.forEach(function (item) {
      var row = el("div", "inb");
      row.appendChild(el("span", "ib", item.type === "note" ? "–" : item.prio ? "*" : "•"));
      var t = el("span", "itxt", item.text);
      t.contentEditable = "true";
      t.spellcheck = false;
      t.onblur = function () {
        var v = t.textContent.trim();
        if (!v) { t.textContent = item.text; return; }
        if (v !== item.text) { item.text = v; touch(); }
      };
      t.onkeydown = function (ev) { if (ev.key === "Enter") { ev.preventDefault(); t.blur(); } };
      row.appendChild(t);
      var days = Math.round((parseKey(today) - parseKey(item.at || today)) / 86400000);
      if (days > 0) row.appendChild(el("span", "iage", days + "d"));
      var now = el("button", "ibtn", "today");
      now.onclick = function () {
        inboxTo(item, function () {
          var d = day(today);
          d.entries.push(inboxEntry(item, { ord: nextOrd(d) }));
        }, "On today's page");
      };
      row.appendChild(now);
      var more = el("button", "ibtn more2", "⋯");
      more.title = "Move it somewhere else";
      more.onclick = function () { inboxOptions(item); };
      row.appendChild(more);
      box.appendChild(row);
    });
  }

  /* ---------------- handing work off ---------------- */
  function handOff(e) {
    var inp;
    panel("delegation", "Hand off", {
      label: "hand off", run: function () {
        var v = inp.value.trim();
        if (!v) return;
        assign(e, v);
      }
    }, function (body) {
      var p = el("p", "mnote", "It leaves your page and waits under their name in Lists → waiting on, with the day you handed it over. Nothing is sent to them — this is your record of who has what.");
      p.style.padding = "0 0 8px";
      body.appendChild(p);
      state.people.forEach(function (name) {
        var b = el("button", "mrow");
        b.appendChild(el("span", "mk", name));
        var n = allDelegated().filter(function (d) { return d.e.who === name && d.e.st === 4; }).length;
        b.appendChild(el("span", "mv", n ? n + " open" : ""));
        b.appendChild(el("span", "chev", "›"));
        b.onclick = function () { assign(e, name); };
        body.appendChild(b);
      });
      var lab = el("p", "mnote", state.people.length ? "Someone else" : "Who's taking it?");
      lab.style.padding = "14px 0 6px";
      body.appendChild(lab);
      inp = el("input", "field");
      inp.placeholder = "Lauren";
      body.appendChild(inp);
      setTimeout(function () { if (!state.people.length) inp.focus(); }, 40);
    });
  }

  function assign(e, name) {
    if (state.people.indexOf(name) < 0) state.people.push(name);
    e.st = 4;
    e.who = name;
    e.handed = sel;
    touch(); paintAll(); show("day");
    toast("Handed to " + name);
  }

  function allDelegated() {
    var out = [];
    Object.keys(state.days).forEach(function (k) {
      state.days[k].entries.forEach(function (e) {
        if (e.who && (e.st === 4 || e.doneBy)) out.push({ k: k, e: e });
      });
    });
    return out;
  }

  function paintDelegated() {
    var box = $("delegated");
    if (!box) return;
    box.innerHTML = "";
    var all = allDelegated().filter(function (d) { return d.e.st === 4; });

    var line = $("waitingLine");
    if (all.length) {
      line.hidden = false;
      var names = {};
      all.forEach(function (d) { names[d.e.who] = (names[d.e.who] || 0) + 1; });
      $("waitingV").textContent = Object.keys(names).map(function (n) {
        return n + " " + names[n];
      }).join(" · ");
    } else line.hidden = true;

    if (!all.length) {
      box.appendChild(el("div", "empty", "Nothing handed off. Open any task's ⋯ and pick “hand off” to park it under someone's name."));
      return;
    }
    var by = {};
    all.forEach(function (d) { (by[d.e.who] = by[d.e.who] || []).push(d); });
    Object.keys(by).sort().forEach(function (name) {
      var head = el("div", "who-head");
      head.appendChild(el("span", "who-name", name));
      head.appendChild(el("span", "who-n", by[name].length + " open"));
      box.appendChild(head);
      by[name].sort(function (a, b) { return (a.e.handed || a.k) < (b.e.handed || b.k) ? -1 : 1; })
        .forEach(function (d) {
          var since = d.e.handed || d.k;
          var days = Math.round((parseKey(today) - parseKey(since)) / 86400000);
          var row = el("div", "dele");
          var age = el("span", "dage" + (days > 6 ? " old" : ""), days + "d");
          age.title = "Handed over " + whenLabel(since, null);
          row.appendChild(age);
          row.appendChild(el("span", "dtxt", d.e.text));
          var done = el("button", "dbtn", "done");
          done.title = "They finished it";
          done.onclick = function () {
            d.e.st = 1; d.e.doneBy = d.e.who;
            touch(); paintAll();
            toast("Closed out");
          };
          row.appendChild(done);
          var back = el("button", "dbtn back", "back to me");
          back.onclick = function () {
            /* handed off from the day it's going back to: just un-hand it,
               otherwise you get the same task twice on one page */
            if (d.k === today) {
              d.e.st = 0;
              d.e.who = null;
              d.e.handed = null;
              d.e.ord = nextOrd(day(today));
              touch(); paintAll();
              toast("Back on today's page");
              return;
            }
            d.e.st = 2;
            var copy = {
              id: uid(), type: d.e.type, text: d.e.text, st: 0, prio: d.e.prio,
              time: null, from: d.k, ord: nextOrd(day(today)),
              subs: (d.e.subs || []).filter(function (x) { return !x.done; })
                .map(function (x) { return { id: uid(), text: x.text, done: false }; })
            };
            day(today).entries.push(copy);
            touch(); paintAll();
            toast("Back on today's page");
          };
          row.appendChild(back);
          box.appendChild(row);
        });
    });
  }

  /* ---------------- subtasks ---------------- */
  function subList(e) {
    var box = el("div", "subs");
    e.subs.forEach(function (s) {
      var row = el("div", "sub" + (s.done ? " done" : ""));
      var b = el("button", "sbullet", s.done ? "×" : "◦");
      b.title = "Done";
      b.onclick = function () { s.done = !s.done; touch(); paintAll(); };
      row.appendChild(b);
      var t = el("span", "stext", s.text);
      t.contentEditable = "true";
      t.spellcheck = false;
      t.onblur = function () {
        var v = t.textContent.trim();
        if (!v) { t.textContent = s.text; return; }
        if (v !== s.text) { s.text = v; touch(); }
      };
      t.onkeydown = function (ev) { if (ev.key === "Enter") { ev.preventDefault(); t.blur(); } };
      row.appendChild(t);
      var k = el("button", "skill", "×");
      k.title = "Remove step";
      k.onclick = function () {
        e.subs.splice(e.subs.indexOf(s), 1);
        touch(); paintAll();
      };
      row.appendChild(k);
      box.appendChild(row);
    });
    return box;
  }

  function addSub(e, wrap) {
    var existing = wrap.querySelector(".sub-input");
    if (existing) { existing.focus(); return; }
    var holder = wrap.querySelector(".subs");
    if (!holder) { holder = el("div", "subs"); wrap.appendChild(holder); }
    var row = el("div", "sub");
    row.appendChild(el("span", "sbullet", "◦"));
    var inp = el("input", "sub-input");
    inp.placeholder = "a step…";
    inp.enterKeyHint = "done";

    /* the input is destroyed by every repaint, so the blur that repaint
       causes must not run commit again — that was eating the next step. */
    var closed = false;
    function close(save) {
      if (closed) return false;
      closed = true;
      var v = inp.value.trim();
      var added = false;
      if (save && v) {
        e.subs = e.subs || [];
        e.subs.push({ id: uid(), text: v, done: false });
        touch();
        added = true;
      }
      paintAll();
      return added;
    }
    inp.onkeydown = function (ev) {
      if (ev.key === "Enter") {
        ev.preventDefault();
        if (!close(true)) return;
        var again = $("log").querySelector('[data-eid="' + e.id + '"]');
        if (again) addSub(e, again);       /* straight into the next step */
      } else if (ev.key === "Escape") {
        ev.preventDefault();
        close(false);
      }
    };
    inp.onblur = function () { setTimeout(function () { close(true); }, 140); };
    row.appendChild(inp);
    holder.appendChild(row);
    inp.focus();
  }

  function cycle(e) {
    if (e.type === "note") { e.prio = !e.prio; touch(); paintAll(); return; }
    if (e.st === 0) e.st = 1;
    else if (e.st === 1) {
      e.st = 2;
      var to = addDays(sel, 1);
      day(to).entries.push({ id: uid(), type: e.type, text: e.text, st: 0, prio: e.prio, time: e.time || null, from: sel });
      toast("Moved to " + parseKey(to).getDate() + " " + MON[parseKey(to).getMonth()].slice(0, 3));
    } else {
      e.st = 0;
      var nx = day(addDays(sel, 1));
      nx.entries = nx.entries.filter(function (x) { return !(x.from === sel && x.text === e.text && x.st === 0); });
    }
    touch(); paintAll();
  }

  /* what the capture bar will do if you hit Add right now */
  function resolveCapture() {
    var text = $("capText").value.trim();
    var r = parseRepeat(text);
    var p = parseWhen(r.rest, sel);
    var date = p.date || $("capDate").value || sel;
    var time = p.time || $("capTime").value || null;
    return {
      date: date, time: time, text: p.rest || r.rest || text,
      freq: r.freq, spoken: !!(p.date || p.time || r.freq)
    };
  }

  function paintHint() {
    var h = $("capHint"), c = $("capClear"), wb = $("capWhenBtn");
    var picked = $("capDate").value && $("capDate").value !== sel;
    var timed = !!$("capTime").value;
    c.hidden = !(picked || timed);

    var text = $("capText").value.trim();
    var r = resolveCapture();
    var off = r.date !== sel || !!r.time;
    if (capUnfiled) {
      wb.textContent = "inbox";
      wb.classList.add("set");
      h.hidden = !text;
      if (text) h.textContent = "→ inbox, no day" + (r.text !== text ? "  ·  " + r.text : "");
      c.hidden = false;
      return;
    }
    wb.textContent = text ? whenLabel(r.date, r.time) : whenLabel(picked ? $("capDate").value : sel, $("capTime").value || null);
    wb.classList.toggle("set", off);

    if (!text || (r.date === sel && !r.time && !r.freq && r.text === text)) { h.hidden = true; return; }
    h.hidden = false;
    var when = r.freq
      ? freqLabel(r.freq) + (r.time ? " · " + r.time : "") + " from " + whenLabel(r.date, null)
      : whenLabel(r.date, r.time);
    h.textContent = "→ " + when + (r.text !== text ? "  ·  " + r.text : "");
  }

  function resetWhen() {
    $("capDate").value = sel;
    $("capTime").value = "";
    paintHint();
  }
  function unfiledOff() {
    if (!capUnfiled) return;
    capUnfiled = false;
    $("capUnfiled").setAttribute("aria-pressed", "false");
  }

  function add() {
    var input = $("capText");
    if (!input.value.trim()) { input.focus(); return; }
    var r = resolveCapture();
    if (!r.text) { toast("That was only a date — add something to do"); return; }
    if (capUnfiled && !r.freq) {
      state.inbox.push({ id: uid(), text: r.text, type: capType, prio: capPrio, at: today });
      input.value = "";
      capPrio = false; $("capPrio").setAttribute("aria-pressed", "false");
      resetWhen();
      touch(); paintAll(); input.focus();
      toast("In the inbox");
      return;
    }
    if (r.freq) {
      var rule = {
        id: uid(), text: r.text, type: capType, time: r.time,
        prio: capPrio, freq: r.freq, start: r.date, skips: []
      };
      state.rules.push(rule);
      input.value = "";
      capPrio = false; $("capPrio").setAttribute("aria-pressed", "false");
      resetWhen();
      materialize();
      touch(); paintAll();
      toast("Repeats " + freqLabel(r.freq));
      input.focus();
      return;
    }
    day(r.date).entries.push({ id: uid(), type: capType, text: r.text, st: 0, prio: capPrio, time: r.time, subs: [], ord: nextOrd(day(r.date)) });
    input.value = "";
    capPrio = false; $("capPrio").setAttribute("aria-pressed", "false");
    var elsewhere = r.date !== sel;
    resetWhen();
    touch(); paintAll();
    if (elsewhere) toast("On " + whenLabel(r.date, r.time));
    input.focus();
  }

  /* ---------------- voice capture ----------------
     Web Speech, where the browser and the frame allow it. The page never
     assumes it works: the button only appears if the API is there, and it
     removes itself the moment a permission error comes back. */
  var SR = window.SpeechRecognition || window.webkitSpeechRecognition;
  var rec = null, listening = false, heardBefore = "";

  function micIcon() {
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
      'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      '<rect x="9" y="2.5" width="6" height="11" rx="3"/>' +
      '<path d="M5.5 11a6.5 6.5 0 0 0 13 0"/><path d="M12 17.5V21"/><path d="M8.5 21h7"/></svg>';
  }

  var micBlocked = false;   /* this view only — a Mac may allow what a phone frame doesn't */

  function keyboardIcon() {
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" ' +
      'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      '<rect x="2" y="6" width="20" height="12" rx="2.5"/>' +
      '<path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M8 14h8"/></svg>';
  }

  function blockMic() {
    micBlocked = true;
    var b = $("capMic");
    b.classList.remove("on");
    b.classList.add("blocked");
    b.innerHTML = keyboardIcon();
    b.title = "Open the keyboard and use its mic key";
    b.setAttribute("aria-label", "Open the keyboard to dictate");
  }

  function micOff(reason) {
    listening = false;
    $("capMic").classList.remove("on");
    $("capHint").classList.remove("live");
    if (reason) toast(reason);
    paintHint();
  }

  /* blocked: hand the viewer to the system keyboard, whose mic key always works */
  function toKeyboard() {
    var i = $("capText");
    i.focus();
    try { i.setSelectionRange(i.value.length, i.value.length); } catch (e) { /* ignore */ }
    toast("Tap the 🎤 key on your keyboard to talk");
  }

  function startListening() {
    if (!SR) return;
    if (listening) { try { rec.stop(); } catch (e) { /* ignore */ } return; }
    try {
      rec = new SR();
    } catch (e) {
      micOff();
      blockMic();
      toKeyboard();
      return;
    }
    rec.lang = "en-US";
    rec.interimResults = true;
    rec.continuous = false;
    rec.maxAlternatives = 1;

    heardBefore = $("capText").value.trim();
    listening = true;
    $("capMic").classList.add("on");
    $("capHint").hidden = false;
    $("capHint").classList.add("live");
    $("capHint").textContent = "listening…";

    rec.onresult = function (ev) {
      var txt = "";
      for (var i = ev.resultIndex; i < ev.results.length; i++) txt += ev.results[i][0].transcript;
      txt = txt.replace(/^\s+/, "");
      $("capText").value = (heardBefore ? heardBefore + " " : "") + txt;
      var final = ev.results[ev.results.length - 1].isFinal;
      if (final) {
        $("capHint").classList.remove("live");
        paintHint();
      } else {
        $("capHint").textContent = "listening… " + txt;
      }
    };
    rec.onerror = function (ev) {
      var c = ev && ev.error;
      if (c === "not-allowed" || c === "service-not-allowed" || c === "audio-capture") {
        micOff();
        blockMic();
        toKeyboard();
      } else if (c === "no-speech") {
        micOff();
        toast("Didn't catch that");
      } else if (c === "aborted") {
        micOff();
      } else {
        micOff();
        blockMic();
        toKeyboard();
      }
    };
    rec.onend = function () {
      if (listening) micOff();
      if ($("capText").value.trim()) $("capText").focus();
    };
    try {
      rec.start();
    } catch (e) {
      micOff();
      blockMic();
      toKeyboard();
    }
  }

  /* ---------------- coming up ---------------- */
  function paintSoon() {
    var box = $("soon"); box.innerHTML = "";
    var out = [];
    Object.keys(state.days).forEach(function (k) {
      if (k <= sel) return;
      state.days[k].entries.forEach(function (e) {
        if (e.st === 0 && e.type !== "note") out.push({ k: k, e: e });
      });
    });
    out.sort(function (a, b) {
      if (a.k !== b.k) return a.k < b.k ? -1 : 1;
      return (a.e.time || "99") < (b.e.time || "99") ? -1 : 1;
    });
    $("soonHead").hidden = !out.length;
    out.slice(0, 8).forEach(function (o) {
      var row = el("button", "soon");
      row.appendChild(el("span", "when", whenLabel(o.k, o.e.time)));
      row.appendChild(el("span", "stxt", o.e.text));
      row.onclick = function () { sel = o.k; paintAll(); show("day"); };
      box.appendChild(row);
    });
  }

  /* ---------------- loops ---------------- */
  function paintLoops() {
    var box = $("loops"); box.innerHTML = "";
    var out = [];
    Object.keys(state.days).forEach(function (k) {
      if (k >= sel) return;
      state.days[k].entries.forEach(function (e) {
        if (e.type !== "note" && e.st === 0) out.push({ k: k, e: e });
      });
    });
    out.sort(function (a, b) { return a.k < b.k ? -1 : 1; });
    $("bLoops").textContent = out.length ? out.length : "";

    if (!out.length) {
      box.appendChild(el("div", "empty", "Nothing unfinished behind you."));
      return;
    }
    out.forEach(function (o) {
      var days = Math.round((parseKey(sel) - parseKey(o.k)) / 86400000);
      var row = el("div", "loop");
      var age = el("span", "age" + (days > 6 ? " old" : ""), days + "d");
      age.title = o.k;
      row.appendChild(age);
      row.appendChild(el("span", "ltxt", o.e.text));
      var pull = el("button", "pull", "pull");
      pull.title = "Move to " + sel;
      pull.onclick = function () {
        o.e.st = 2;
        day(sel).entries.push({
          id: uid(), type: o.e.type, text: o.e.text, st: 0, prio: o.e.prio, time: null, from: o.k,
          subs: (o.e.subs || []).filter(function (x) { return !x.done; })
            .map(function (x) { return { id: uid(), text: x.text, done: false }; })
        });
        touch(); paintAll();
      };
      row.appendChild(pull);
      box.appendChild(row);
    });
  }

  /* ---------------- month ---------------- */
  function paintMonth() {
    var d = parseKey(sel), y = d.getFullYear(), m = d.getMonth();
    var grid = $("month"); grid.innerHTML = "";
    ["S", "M", "T", "W", "T", "F", "S"].forEach(function (w) { grid.appendChild(el("div", "dow", w)); });
    var first = new Date(y, m, 1).getDay(), last = new Date(y, m + 1, 0).getDate();
    for (var i = 0; i < first; i++) grid.appendChild(el("div", "mday blank"));
    var mOpen = 0, mLogged = 0;
    for (var dd = 1; dd <= last; dd++) {
      var k = y + "-" + pad(m + 1) + "-" + pad(dd);
      var rec = state.days[k];
      var openN = openOf(k);
      mOpen += openN;
      if (rec && rec.entries.length) mLogged++;
      var cell = el("button", "mday" + (k === today ? " today" : "") + (k === sel ? " sel" : ""));
      cell.appendChild(el("span", null, String(dd)));
      var dots = el("div", "dots");
      if (rec && rec.entries.length) dots.appendChild(el("i", "d"));
      if (openN) dots.appendChild(el("i", "d open"));
      cell.appendChild(dots);
      cell.onclick = (function (kk) { return function () { sel = kk; paintAll(); show("day"); }; })(k);
      grid.appendChild(cell);
    }
    $("monthNote").textContent = mLogged + " days logged · " + (mOpen ? mOpen + " still open" : "nothing open");
  }

  /* ---------------- month tasks ---------------- */
  function monthItem(e, mk, onChange) {
    var row = el("div", "fitem" + (e.st === 1 ? " done" : ""));
    var b = el("button", "fb", e.st === 1 ? "×" : "•");
    b.title = "Done";
    b.onclick = function () { e.st = e.st === 1 ? 0 : 1; touch(); onChange(); };
    row.appendChild(b);
    row.appendChild(el("span", "ft", e.text));
    var pull = el("button", "fx", "pull");
    pull.title = "Move to the day you're on";
    pull.onclick = function () {
      var arr = month(mk).entries;
      arr.splice(arr.indexOf(e), 1);
      day(sel).entries.push({ id: uid(), type: e.type || "task", text: e.text, st: 0, prio: e.prio, time: null });
      touch(); paintAll();
      toast("Pulled onto " + whenLabel(sel, null));
    };
    row.appendChild(pull);
    var kill = el("button", "fx", "×");
    kill.onclick = function () {
      var arr = month(mk).entries;
      arr.splice(arr.indexOf(e), 1);
      touch(); onChange();
    };
    row.appendChild(kill);
    return row;
  }

  function paintMonthTasks() {
    var mk = mKey(sel);
    $("mtLabel").textContent = monthLabel(mk) + " — no day picked";
    var box = $("monthTasks"); box.innerHTML = "";
    var items = month(mk).entries;
    if (!items.length) {
      box.appendChild(el("div", "fempty", "Nothing parked at the month level."));
      return;
    }
    items.forEach(function (e) { box.appendChild(monthItem(e, mk, paintAll)); });
  }

  /* ---------------- future log ---------------- */
  function paintFuture() {
    var box = $("future"); box.innerHTML = "";
    var start = mKey(today);
    for (var i = 0; i < 6; i++) {
      (function (mk) {
        var blk = el("div", "fmonth");
        var head = el("div", "fhead");
        var p = mk.split("-");
        head.appendChild(el("span", "fm", MON[+p[1] - 1]));
        head.appendChild(el("span", "fy", p[0]));
        var dated = [];
        Object.keys(state.days).forEach(function (k) {
          if (mKey(k) !== mk || k <= today) return;   /* the future log is what's ahead */
          state.days[k].entries.forEach(function (e) {
            if (e.st === 0 && e.type !== "note") dated.push({ k: k, e: e });
          });
        });
        var add = el("button", "fadd", "+ add");
        add.onclick = function () { addToMonth(mk); };
        head.appendChild(add);
        blk.appendChild(head);

        var items = month(mk).entries;
        items.forEach(function (e) { blk.appendChild(monthItem(e, mk, paintAll)); });
        dated.sort(function (a, b) { return a.k < b.k ? -1 : 1; }).forEach(function (o) {
          var row = el("div", "fitem");
          row.appendChild(el("span", "fb", parseKey(o.k).getDate() + ""));
          row.appendChild(el("span", "ft", o.e.text));
          var go = el("button", "fx", "open");
          go.onclick = function () { sel = o.k; paintAll(); show("day"); };
          row.appendChild(go);
          blk.appendChild(row);
        });
        if (!items.length && !dated.length) blk.appendChild(el("div", "fempty", "—"));
        box.appendChild(blk);
      })(addMonthKey(start, i));
    }
  }

  function addToMonth(mk) {
    var inp;
    panel("future log", monthLabel(mk), {
      label: "add", run: function () {
        var v = inp.value.trim();
        if (!v) return;
        month(mk).entries.push({ id: uid(), type: "task", text: v, st: 0, prio: false, time: null });
        touch(); paintAll(); show("month"); segTo("future");
        toast("Parked in " + monthLabel(mk));
      }
    }, function (body) {
      var p = el("p", "mnote", "Something to handle in " + monthLabel(mk) + ", no particular day. It'll wait there until you pull it down.");
      p.style.padding = "0 0 10px";
      body.appendChild(p);
      inp = el("input", "field");
      inp.placeholder = "Preg check the fall herd";
      body.appendChild(inp);
      setTimeout(function () { inp.focus(); }, 40);
    });
  }

  /* ---------------- trackers ---------------- */
  var trkSel = null;
  function trackVal(k, id) {
    var r = state.track[k];
    return r && r[id] != null ? r[id] : null;
  }
  function setTrackVal(k, id, v) {
    if (!state.track[k]) state.track[k] = {};
    if (v == null || v === "") delete state.track[k][id];
    else state.track[k][id] = v;
    if (!Object.keys(state.track[k]).length) delete state.track[k];
    touch();
  }

  function paintTrackers() {
    var box = $("trackers"); box.innerHTML = "";
    var d = parseKey(sel), y = d.getFullYear(), m = d.getMonth();
    var last = new Date(y, m + 1, 0).getDate();

    if (!state.trackers.length) {
      box.appendChild(el("div", "empty", "No trackers yet. Add one for anything you measure daily — rain, cattle worked, miles."));
      return;
    }

    state.trackers.forEach(function (t) {
      var wrap = el("div", "trk");
      var head = el("div", "trk-head");
      head.appendChild(el("span", "trk-name", t.name));
      var sum = 0, days = 0;
      for (var i = 1; i <= last; i++) {
        var v = trackVal(y + "-" + pad(m + 1) + "-" + pad(i), t.id);
        if (v != null) { days++; sum += (t.kind === "num" ? +v : 1); }
      }
      head.appendChild(el("span", "trk-sum",
        t.kind === "num" ? (Math.round(sum * 100) / 100) + " " + (t.unit || "") + " · " + days + "d" : days + " of " + last));
      var kill = el("button", "trk-kill", "remove");
      kill.onclick = function () {
        state.trackers.splice(state.trackers.indexOf(t), 1);
        touch(); paintTrackers();
      };
      head.appendChild(kill);
      wrap.appendChild(head);

      var strip = el("div", "strip");
      var first = new Date(y, m, 1).getDay();
      for (var bl = 0; bl < first; bl++) {
        var blank = el("div", "cell off");
        strip.appendChild(blank);
      }
      for (var dd = 1; dd <= last; dd++) {
        (function (dd) {
          var k = y + "-" + pad(m + 1) + "-" + pad(dd);
          var cell = el("button", "cell");
          var v = trackVal(k, t.id);
          if (v != null) cell.classList.add("has");
          if (k === today) cell.classList.add("today");
          if (trkSel && trkSel.id === t.id && trkSel.k === k) cell.classList.add("sel");
          cell.appendChild(el("span", "cd", String(dd)));
          if (v != null) cell.appendChild(el("span", "cv", t.kind === "num" ? String(v) : "✓"));
          cell.title = dd + " " + MON[m].slice(0, 3) + (v != null ? " · " + v : "");
          cell.onclick = function () {
            if (t.kind === "check") { setTrackVal(k, t.id, v != null ? null : 1); paintTrackers(); return; }
            trkSel = { id: t.id, k: k };
            paintTrackers();
          };
          strip.appendChild(cell);
        })(dd);
      }
      wrap.appendChild(strip);

      if (t.kind === "num" && trkSel && trkSel.id === t.id) {
        var ed = el("div", "trk-edit");
        ed.appendChild(el("span", "lab", whenLabel(trkSel.k, null)));
        var inp = el("input");
        inp.type = "number";
        inp.step = "any";
        inp.inputMode = "decimal";
        var cur = trackVal(trkSel.k, t.id);
        if (cur != null) inp.value = cur;
        ed.appendChild(inp);
        if (t.unit) ed.appendChild(el("span", "lab", t.unit));
        var save = el("button", "pill", "save");
        save.onclick = function () {
          var v = inp.value.trim();
          setTrackVal(trkSel.k, t.id, v === "" ? null : parseFloat(v));
          trkSel = null; paintTrackers();
        };
        ed.appendChild(save);
        var cancel = el("button", "pull", "cancel");
        cancel.onclick = function () { trkSel = null; paintTrackers(); };
        ed.appendChild(cancel);
        wrap.appendChild(ed);
        setTimeout(function () { inp.focus(); }, 30);
      }
      box.appendChild(wrap);
    });
  }

  function newTracker() {
    var name, unit, kind = "num";
    panel("trackers", "New tracker", {
      label: "create", run: function () {
        var n = name.value.trim();
        if (!n) return;
        state.trackers.push({
          id: uid(), name: n, unit: kind === "num" ? unit.value.trim() : "", kind: kind
        });
        touch(); paintTrackers(); show("month"); segTo("track");
      }
    }, function (body) {
      var p = el("p", "mnote", "A number you record (rain, miles, hours) or a simple did-it check.");
      p.style.padding = "0 0 10px";
      body.appendChild(p);
      name = el("input", "field");
      name.placeholder = "Rain";
      body.appendChild(name);
      var row = el("div", "rowflex");
      row.style.marginTop = "10px";
      var bn = el("button", "pill", "number");
      var bc = el("button", "pill", "check");
      bn.setAttribute("aria-pressed", "true");
      bc.setAttribute("aria-pressed", "false");
      bn.onclick = function () { kind = "num"; bn.setAttribute("aria-pressed", "true"); bc.setAttribute("aria-pressed", "false"); unit.style.display = ""; };
      bc.onclick = function () { kind = "check"; bc.setAttribute("aria-pressed", "true"); bn.setAttribute("aria-pressed", "false"); unit.style.display = "none"; };
      row.appendChild(bn); row.appendChild(bc);
      unit = el("input", "timebox");
      unit.placeholder = "unit";
      unit.style.width = "90px";
      row.appendChild(unit);
      body.appendChild(row);
      setTimeout(function () { name.focus(); }, 40);
    });
  }

  /* ---------------- search ---------------- */
  function esc(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }
  function paintResults() {
    var q = $("qText").value.trim();
    var box = $("results"); box.innerHTML = "";
    if (q.length < 2) { $("qCount").textContent = "Type to search"; return; }
    var re = new RegExp(esc(q), "i");
    var hits = [];

    Object.keys(state.days).forEach(function (k) {
      var rec = state.days[k];
      rec.entries.forEach(function (e) {
        if (re.test(e.text)) hits.push({ k: k, label: whenLabel(k, e.time), text: e.text, go: function () { sel = k; paintAll(); show("day"); } });
      });
      if (rec.reflect && re.test(rec.reflect)) {
        hits.push({ k: k, label: whenLabel(k, null), text: rec.reflect, go: function () { sel = k; paintAll(); show("notes"); } });
      }
    });
    Object.keys(state.months).forEach(function (mk) {
      state.months[mk].entries.forEach(function (e) {
        if (re.test(e.text)) hits.push({ k: mk + "-00", label: monthLabel(mk), text: e.text, go: function () { sel = mk + "-01"; paintAll(); show("month"); segTo("tasks"); } });
      });
    });
    state.colls.forEach(function (c) {
      c.items.forEach(function (it) {
        if (re.test(it.text)) hits.push({ k: "z", label: c.name, text: it.text, go: function () { show("lists"); } });
      });
    });

    hits.sort(function (a, b) { return a.k > b.k ? -1 : 1; });
    $("qCount").textContent = hits.length ? hits.length + (hits.length === 1 ? " hit" : " hits") : "Nothing found";
    hits.slice(0, 80).forEach(function (h) {
      var row = el("button", "res");
      row.appendChild(el("span", "rk", h.label));
      var t = el("span", "rt");
      var i = h.text.search(re);
      t.appendChild(document.createTextNode(h.text.slice(0, i)));
      var mk2 = el("mark", null, h.text.substr(i, q.length));
      t.appendChild(mk2);
      t.appendChild(document.createTextNode(h.text.slice(i + q.length)));
      row.appendChild(t);
      row.onclick = h.go;
      box.appendChild(row);
    });
  }

  /* ---------------- migration ritual ---------------- */
  var migQ = [], migI = 0, migStats = null;
  function startMigration() {
    migQ = [];
    Object.keys(state.days).forEach(function (k) {
      if (k >= sel) return;
      state.days[k].entries.forEach(function (e) {
        if (e.type !== "note" && e.st === 0) migQ.push({ k: k, e: e });
      });
    });
    migQ.sort(function (a, b) { return a.k < b.k ? -1 : 1; });
    migI = 0;
    migStats = { moved: 0, dated: 0, monthed: 0, futured: 0, dropped: 0, skipped: 0 };
    show("migrate");
    paintMigrate();
  }

  function migAdvance() {
    migI++;
    touch();
    paintLoops();   /* badge counts down as you work */
    paintMigrate();
  }

  /* migration → put it on one specific day */
  function migPickDate(o) {
    var box = $("migBody"); box.innerHTML = "";
    var w = el("div", "mig-wrap");
    w.appendChild(el("div", "mig-count", "move to a day"));
    w.appendChild(el("div", "mig-text", o.e.text));

    var target = addDays(today, 1);
    var stamp = el("div", "mig-age");
    var dateIn = el("input");
    dateIn.type = "date";
    dateIn.className = "datebox";
    dateIn.style.width = "auto";
    var timeIn = el("input");
    timeIn.type = "time";
    timeIn.className = "timebox";
    if (o.e.time) timeIn.value = o.e.time;

    function setTarget(k) {
      target = k;
      dateIn.value = k;
      stamp.textContent = "→ " + whenLabel(k, timeIn.value || null);
    }

    var chips = el("div", "rowflex");
    [["tomorrow", 1], ["in 3 days", 3], ["next week", 7], ["two weeks", 14]].forEach(function (c) {
      var b = el("button", "pill", c[0]);
      b.onclick = function () { setTarget(addDays(today, c[1])); };
      chips.appendChild(b);
    });
    w.appendChild(chips);

    var row = el("div", "rowflex");
    row.style.marginTop = "2px";
    dateIn.onchange = function () { if (dateIn.value) setTarget(dateIn.value); };
    timeIn.onchange = function () { setTarget(target); };
    row.appendChild(dateIn);
    row.appendChild(timeIn);
    w.appendChild(row);
    w.appendChild(stamp);

    var acts = el("div", "mig-acts");
    var go = el("button");
    go.appendChild(el("span", null, "Move it"));
    go.appendChild(el("span", "k", "›"));
    go.onclick = function () {
      o.e.st = 2;
      day(target).entries.push({
        id: uid(), type: o.e.type, text: o.e.text, st: 0,
        prio: o.e.prio, time: timeIn.value || null, from: o.k
      });
      migStats.dated++;
      toast("On " + whenLabel(target, timeIn.value || null));
      migAdvance();
    };
    acts.appendChild(go);
    var back = el("button");
    back.appendChild(el("span", null, "Back"));
    back.onclick = paintMigrate;
    acts.appendChild(back);
    w.appendChild(acts);

    box.appendChild(w);
    setTarget(target);
  }

  function paintMigrate() {
    var box = $("migBody"); box.innerHTML = "";
    if (migI >= migQ.length) {
      var s = migStats || { moved: 0, dated: 0, monthed: 0, futured: 0, dropped: 0, skipped: 0 };
      var w = el("div", "mig-wrap");
      w.appendChild(el("div", "mig-count", migQ.length ? "review complete" : "nothing to review"));
      var lines = [];
      if (s.moved) lines.push(s.moved + " pulled onto " + whenLabel(sel, null));
      if (s.dated) lines.push(s.dated + " given a date");
      if (s.monthed) lines.push(s.monthed + " parked in " + monthLabel(mKey(sel)));
      if (s.futured) lines.push(s.futured + " pushed to a later month");
      if (s.dropped) lines.push(s.dropped + " struck out");
      if (s.skipped) lines.push(s.skipped + " left where they were");
      var d = el("div", "mig-done", lines.length ? lines.join(" · ") : "Nothing was carrying over.");
      w.appendChild(d);
      var back = el("button", "pill", "back to the day");
      back.onclick = function () { paintAll(); show("day"); };
      w.appendChild(back);
      box.appendChild(w);
      return;
    }

    var o = migQ[migI];
    var days = Math.round((parseKey(sel) - parseKey(o.k)) / 86400000);
    var w2 = el("div", "mig-wrap");
    w2.appendChild(el("div", "mig-count", (migI + 1) + " of " + migQ.length));
    w2.appendChild(el("div", "mig-text", o.e.text));
    w2.appendChild(el("div", "mig-age", "written " + days + (days === 1 ? " day" : " days") + " ago · " + whenLabel(o.k, o.e.time)));

    var acts = el("div", "mig-acts");
    function action(label, hint, fn, cls) {
      var b = el("button", cls || "");
      b.appendChild(el("span", null, label));
      if (hint) b.appendChild(el("span", "k", hint));
      b.onclick = fn;
      acts.appendChild(b);
    }
    action("Do it " + (sel === today ? "today" : "on " + whenLabel(sel, null)), "›", function () {
      o.e.st = 2;
      day(sel).entries.push({ id: uid(), type: o.e.type, text: o.e.text, st: 0, prio: o.e.prio, time: null, from: o.k });
      migStats.moved++; migAdvance();
    });
    action("Pick a date", "›", function () { migPickDate(o); });
    action("This month", monthLabel(mKey(sel)), function () {
      o.e.st = 2;
      month(mKey(sel)).entries.push({ id: uid(), type: "task", text: o.e.text, st: 0, prio: o.e.prio, time: null });
      migStats.monthed++; migAdvance();
    });
    action("Push to a later month", "›", function () {
      var box2 = $("migBody"); box2.innerHTML = "";
      var w3 = el("div", "mig-wrap");
      w3.appendChild(el("div", "mig-count", "push to"));
      w3.appendChild(el("div", "mig-text", o.e.text));
      var opts = el("div", "mig-acts");
      for (var i = 1; i <= 6; i++) {
        (function (mk) {
          var b = el("button");
          b.appendChild(el("span", null, monthLabel(mk)));
          b.onclick = function () {
            o.e.st = 2;
            month(mk).entries.push({ id: uid(), type: "task", text: o.e.text, st: 0, prio: o.e.prio, time: null });
            migStats.futured++; migAdvance();
          };
          opts.appendChild(b);
        })(addMonthKey(mKey(sel), i));
      }
      var back = el("button", "pill", "back");
      back.onclick = paintMigrate;
      w3.appendChild(opts);
      w3.appendChild(back);
      box2.appendChild(w3);
    });
    action("Strike it — no longer matters", "×", function () {
      o.e.st = 3;
      migStats.dropped++; migAdvance();
    }, "drop");
    action("Leave it", "skip", function () { migStats.skipped++; migAdvance(); });
    w2.appendChild(acts);
    box.appendChild(w2);
  }

  /* ---------------- lists ---------------- */
  function newList() {
    panel("collections", "New list", null, function (body) {
      var inp = el("input", "field");
      inp.placeholder = "Parts to order";
      body.appendChild(inp);
      var go = el("button", "pill", "create list");
      go.style.marginTop = "10px";
      go.onclick = function () {
        var v = inp.value.trim();
        if (!v) return;
        state.colls.push({ id: uid(), name: v, items: [] });
        touch(); paintLists(); show("lists");
      };
      body.appendChild(go);
      setTimeout(function () { inp.focus(); }, 40);
    });
  }

  function paintLists() {
    var box = $("colls"); box.innerHTML = "";
    if (!state.colls.length) {
      box.appendChild(el("div", "empty", "Running lists live here — parts to order, pastures to check, calls to make."));
      return;
    }
    state.colls.forEach(function (c) {
      var d = el("details", "coll");
      var s = el("summary", null, c.name);
      var openN = c.items.filter(function (i) { return !i.done; }).length;
      s.appendChild(el("span", "cnt", openN + "/" + c.items.length));
      d.appendChild(s);
      var ul = el("ul");
      c.items.forEach(function (it) {
        var li = el("li", "citem" + (it.done ? " done" : ""));
        var tog = el("button", null, it.done ? "×" : "•");
        tog.onclick = function () { it.done = !it.done; touch(); paintLists(); };
        li.appendChild(tog);
        li.appendChild(el("span", null, it.text));
        var rm = el("button", null, "–");
        rm.title = "Remove";
        rm.onclick = function () { c.items.splice(c.items.indexOf(it), 1); touch(); paintLists(); };
        li.appendChild(rm);
        ul.appendChild(li);
      });
      var addLi = el("li", "citem adder");
      var inp = el("input", "field");
      inp.style.cssText = "padding:6px 9px;font-size:14px";
      inp.placeholder = "Add…";
      inp.onkeydown = function (ev) {
        if (ev.key !== "Enter") return;
        var v = inp.value.trim(); if (!v) return;
        c.items.push({ id: uid(), text: v, done: false });
        inp.value = ""; touch(); paintLists();
        var reopened = $("colls").querySelectorAll("details")[state.colls.indexOf(c)];
        if (reopened) { reopened.open = true; reopened.querySelector("input").focus(); }
      };
      addLi.appendChild(inp);
      var del = el("button", "pull", "delete list");
      del.onclick = function () { state.colls.splice(state.colls.indexOf(c), 1); touch(); paintLists(); };
      addLi.appendChild(del);
      ul.appendChild(addLi);
      d.appendChild(ul);
      box.appendChild(d);
    });
  }

  /* ---------------- lots ---------------- */
  var LOT_COLS = [
    { k: "lot", label: "Lot" }, { k: "head", label: "Head" }, { k: "inWt", label: "In wt" },
    { k: "dof", label: "Days" }, { k: "adg", label: "ADG" }, { k: "doctored", label: "Dr" }, { k: "dead", label: "Dead" }
  ];
  var ALIAS = {
    lot: ["lot", "lot_name", "lot_id", "name", "pasture"],
    head: ["head", "head_in", "headin", "count", "hd", "current_head"],
    inWt: ["inwt", "in_wt", "avg_in_wt", "in_weight", "avg_in_weight", "payweight"],
    dof: ["dof", "days", "days_on_feed", "head_days", "dayson", "doi"],
    adg: ["adg", "avg_daily_gain", "gain"],
    doctored: ["doctored", "dr", "treated", "pulls", "doctor"],
    dead: ["dead", "deads", "death", "deathloss", "death_loss", "mort"]
  };
  function normKey(s) { return String(s).toLowerCase().replace(/[^a-z0-9]/g, "_").replace(/_+/g, "_").replace(/^_|_$/g, ""); }
  function mapRow(obj) {
    var out = {};
    LOT_COLS.forEach(function (c) { out[c.k] = null; });
    Object.keys(obj).forEach(function (rawK) {
      var nk = normKey(rawK);
      Object.keys(ALIAS).forEach(function (target) {
        if (ALIAS[target].indexOf(nk) >= 0 && out[target] == null) {
          var v = obj[rawK];
          out[target] = target === "lot" ? String(v).trim()
            : (v === "" || v == null ? null : parseFloat(String(v).replace(/[^0-9.\-]/g, "")));
        }
      });
    });
    return out;
  }
  function parseLots(text) {
    text = text.trim();
    if (!text) return [];
    if (text.charAt(0) === "[" || text.charAt(0) === "{") {
      var j = JSON.parse(text);
      if (!Array.isArray(j)) j = j.rows || j.data || j.lots || [];
      return j.map(mapRow);
    }
    var lines = text.split(/\r?\n/).filter(function (l) { return l.trim(); });
    var delim = lines[0].indexOf("\t") >= 0 ? "\t" : ",";
    var head = lines[0].split(delim).map(function (h) { return h.trim().replace(/^"|"$/g, ""); });
    return lines.slice(1).map(function (l) {
      var cells = l.split(delim).map(function (c) { return c.trim().replace(/^"|"$/g, ""); });
      var o = {};
      head.forEach(function (h, i) { o[h] = cells[i]; });
      return mapRow(o);
    }).filter(function (r) { return r.lot; });
  }
  function num(v, dec) {
    if (v == null || isNaN(v)) return "—";
    return dec ? v.toFixed(dec) : Math.round(v).toLocaleString();
  }

  function paintLots() {
    var box = $("lotBody"); box.innerHTML = "";
    var L = state.lots;
    $("mLotsV").textContent = L && L.rows && L.rows.length ? L.rows.length + " lots · " + L.stamp : "none";
    if (!L || !L.rows || !L.rows.length) {
      var em = el("div", "empty");
      em.innerHTML = "No lot data yet. Paste an export from the ranch app, or wire the Supabase view once RLS is in.";
      box.appendChild(em);
      var b = el("button", "pill", "paste lot data");
      b.style.marginTop = "6px";
      b.onclick = openLots;
      box.appendChild(b);
      return;
    }
    var totHead = 0, totDr = 0, totDead = 0, adgW = 0, adgN = 0;
    L.rows.forEach(function (r) {
      if (r.head) totHead += r.head;
      if (r.doctored) totDr += r.doctored;
      if (r.dead) totDead += r.dead;
      if (r.adg != null && !isNaN(r.adg) && r.head) { adgW += r.adg * r.head; adgN += r.head; }
    });
    function tile(k, v, sub) {
      var t = el("div", "tile");
      t.appendChild(el("div", "k", k));
      var val = el("div", "v", v);
      if (sub) val.appendChild(el("small", null, sub));
      t.appendChild(val);
      return t;
    }
    var tiles = el("div", "tiles");
    tiles.appendChild(tile("Head", totHead.toLocaleString()));
    tiles.appendChild(tile("Lots", String(L.rows.length)));
    tiles.appendChild(tile("ADG", adgN ? (adgW / adgN).toFixed(2) : "—", "lb"));
    tiles.appendChild(tile("Death", totHead ? ((totDead / (totHead + totDead)) * 100).toFixed(1) : "—", "%"));
    box.appendChild(tiles);

    var sc = el("div", "scroller");
    var tb = el("table", "lots");
    var thead = el("thead"), trh = el("tr");
    LOT_COLS.forEach(function (c) { trh.appendChild(el("th", null, c.label)); });
    thead.appendChild(trh); tb.appendChild(thead);
    var tbody = el("tbody");
    L.rows.forEach(function (r) {
      var tr = el("tr");
      LOT_COLS.forEach(function (c) {
        var td;
        if (c.k === "lot") td = el("td", null, r.lot || "—");
        else if (c.k === "adg") {
          td = el("td", null, num(r.adg, 2));
          if (r.adg != null && !isNaN(r.adg)) td.className = r.adg >= 2 ? "flag ok" : r.adg >= 1.4 ? "flag warn" : "flag";
        } else if (c.k === "dead") {
          td = el("td", null, r.dead == null ? "—" : num(r.dead));
          if (r.dead) td.className = "flag";
        } else td = el("td", null, num(r[c.k]));
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });
    var tot = el("tr", "total");
    [["Total", 0], [totHead.toLocaleString(), 1], ["—", 1], ["—", 1],
    [adgN ? (adgW / adgN).toFixed(2) : "—", 1], [String(totDr), 1], [String(totDead), 1]]
      .forEach(function (p) { tot.appendChild(el("td", null, p[0])); });
    tbody.appendChild(tot);
    tb.appendChild(tbody);
    sc.appendChild(tb);
    box.appendChild(sc);
  }

  /* ---------------- panels ---------------- */
  var panelTitle = "", panelEyebrow = "", panelAction = null;
  function panel(eyebrow, title, action, build) {
    panelEyebrow = eyebrow; panelTitle = title; panelAction = action;
    var body = $("panelBody"); body.innerHTML = "";
    build(body);
    show("panel");
  }

  function openLots() {
    var ta;
    panel("lot summary", "Load lot data", {
      label: "load", run: function () {
        try {
          var rows = parseLots(ta.value);
          if (!rows.length) { toast("Nothing parsed — check the header row"); return; }
          var n = new Date();
          state.lots = { rows: rows, raw: ta.value, stamp: n.getDate() + " " + MON[n.getMonth()].slice(0, 3) + " " + pad(n.getHours()) + ":" + pad(n.getMinutes()) };
          touch(); paintLots(); show("lots");
          toast(rows.length + " lots loaded");
        } catch (err) { toast("Could not read that: " + err.message); }
      }
    }, function (body) {
      var p = el("p", "mnote", "CSV or JSON from the ranch app. Column names match loosely: lot, head, in_wt, dof, adg, doctored, dead.");
      p.style.padding = "0 0 10px";
      body.appendChild(p);
      ta = el("textarea", "field");
      ta.placeholder = "lot,head,in_wt,dof,adg,doctored,dead";
      ta.value = state.lots && state.lots.raw ? state.lots.raw : "";
      body.appendChild(ta);
      var clear = el("button", "pull", "clear lot data");
      clear.style.marginTop = "10px";
      clear.onclick = function () { state.lots = null; touch(); paintLots(); show("lots"); };
      body.appendChild(clear);
    });
  }

  function parseCapture(text, base) {
    return text.split(/\r?\n/).map(function (raw) {
      var l = raw.trim();
      if (!l) return null;
      l = l.replace(/^[-–—•○]\s*/, "").replace(/^\d+[.)]\s*/, "").replace(/^\[[ xX]\]\s*/, "");
      if (!l) return null;
      var prio = false;
      if (/^\*\s*/.test(l)) { prio = true; l = l.replace(/^\*\s*/, ""); }
      if (/!!$/.test(l)) { prio = true; l = l.replace(/\s*!!$/, ""); }
      var w = parseWhen(l, base);
      if (!w.rest) return null;
      return {
        date: w.date || base,
        dated: !!(w.date || w.time),
        entry: { id: uid(), type: w.time ? "event" : "task", text: w.rest, st: 0, prio: prio, time: w.time }
      };
    }).filter(Boolean);
  }

  function openMap() {
    panel("reference", "Where things live", null, function (body) {
      [
        ["Daily log", "Day", "Today's page. Capture at the bottom — tap a bullet to cycle open → done → migrated."],
        ["Future log", "Logs → future", "Six months ahead. Items park at the month level with no day picked; + add puts one there."],
        ["Monthly log", "Logs → calendar / month", "Calendar grid, and the month's task list on the next segment."],
        ["Inbox", "Lists → inbox", "Unfiled capture. Set the capture chip to inbox, then move things out when you have a minute."],
        ["Collections", "Lists → collections", "Running lists — parts, pastures, calls."],
        ["Index", "the ⌕ in the top bar", "Searches every entry, end-of-day note, month item and list item."],
        ["Migration", "Loops → migrate", "Walks each unfinished item: do it, date it, park it, push it, or strike it."],
        ["Trackers", "Logs → trackers", "A calendar per thing you measure. Tap a day to set it."],
        ["Reflection", "Day → End of day", "Weather, cattle worked, what got away."],
        ["Waiting on", "Lists → waiting on", "Work you handed to someone, with how long they have had it."],
        ["Lot summary", "Lots", "Head, ADG, doctored, death loss. Load an export under More."]
      ].forEach(function (r) {
        var row = el("div");
        row.style.cssText = "padding:13px 0;border-top:1px solid var(--hair-2)";
        var top = el("div");
        top.style.cssText = "display:flex;gap:10px;align-items:baseline";
        var k = el("span", null, r[0]);
        k.style.cssText = "font-size:calc(16.5px * var(--s));font-weight:500";
        top.appendChild(k);
        var w = el("span", null, r[1]);
        w.style.cssText = "margin-left:auto;font-family:var(--f-mono);font-size:calc(13px * var(--s2));color:var(--accent);text-align:right";
        top.appendChild(w);
        row.appendChild(top);
        row.appendChild(el("p", "mnote", r[2]));
        body.appendChild(row);
      });
      var sig = el("p", "mnote",
        "Signifiers — • task · × done · › migrated · ~ struck · → handed off · ○ event · – note · * priority");
      sig.style.cssText = "padding-top:16px;border-top:1px solid var(--hair-2);margin-top:8px";
      body.appendChild(sig);
    });
  }

  function openRepeats() {
    panel("repeating", "Repeats", null, function (body) {
      var p = el("p", "mnote", "Say it once in the capture box — \u201cevery friday 7:30 check the water\u201d, \u201cevery weekday feed\u201d, \u201cevery other tuesday\u201d, \u201cmonthly\u201d. Deleting a single day's copy skips just that day.");
      p.style.padding = "0 0 6px";
      body.appendChild(p);
      if (!state.rules.length) {
        body.appendChild(el("div", "empty", "Nothing repeating yet."));
        return;
      }
      state.rules.forEach(function (r) {
        var row = el("div", "rule");
        row.appendChild(el("span", "rwhen", freqLabel(r.freq) + (r.time ? " " + r.time : "")));
        row.appendChild(el("span", "rtxt", r.text));
        var kill = el("button", "pull", "stop");
        kill.title = "Stop repeating (days already filled in stay)";
        kill.onclick = function () {
          state.rules.splice(state.rules.indexOf(r), 1);
          touch(); openRepeats();
          toast("Stopped repeating");
        };
        row.appendChild(kill);
        body.appendChild(row);
      });
    });
  }

  function openInbox() {
    var ta;
    panel("capture", "Inbox", {
      label: "capture", run: function () {
        var rows = parseCapture(ta.value, sel);
        if (!rows.length) { toast("Nothing to capture"); return; }
        var dated = 0, unfiled = 0;
        rows.forEach(function (r) {
          if (r.dated) {
            var d = day(r.date);
            r.entry.ord = nextOrd(d);
            d.entries.push(r.entry);
            dated++;
          } else {
            state.inbox.push({ id: uid(), text: r.entry.text, type: r.entry.type, prio: r.entry.prio, at: today });
            unfiled++;
          }
        });
        touch(); paintAll();
        if (unfiled) { show("lists"); lsegTo("inbox"); } else show("day");
        toast(dated + " dated · " + unfiled + " to the inbox");
      }
    }, function (body) {
      var p = el("p", "mnote", "Paste what Siri collected — one per line. Anything with a date or time lands on that day; everything else drops into the Inbox to sort later. * or !! marks priority.");
      p.style.padding = "0 0 10px";
      body.appendChild(p);
      ta = el("textarea", "field");
      ta.placeholder = "Check Sandy Creek trough\n* Doctor 4 head north trap\n2026-08-24 07:30 Load out to Groesbeck";
      body.appendChild(ta);
      var row = el("div", "rowflex");
      row.style.marginTop = "10px";
      var cb = el("button", "pill", "paste from clipboard");
      cb.onclick = async function () {
        try {
          var t = await navigator.clipboard.readText();
          if (t) ta.value = ta.value ? ta.value + "\n" + t : t;
          else toast("Clipboard was empty");
        } catch (e) { toast("Long-press the box and paste instead"); }
      };
      row.appendChild(cb);
      body.appendChild(row);

      var h = el("p", "mnote", "Build the Shortcut once — “Send to tally book”");
      h.style.color = "var(--ink-2)";
      body.appendChild(h);
      [
        "1 · Find Reminders — Filter: Is Completed → No. Sort by Due Date.",
        "2 · Repeat with Each",
        "3 ·  ↳ If — Repeat Item Due Date → has any value",
        "4 ·     Format Date — Repeat Item Due Date, Custom: yyyy-MM-dd HH:mm",
        "5 ·     Text — [Formatted Date] [Repeat Item Name]",
        "6 ·  ↳ Otherwise — Text: [Repeat Item Name]",
        "7 ·  ↳ End If — Add [Text] to Variable: lines",
        "8 · Combine Text — lines, Separator: New Lines",
        "9 · Copy to Clipboard",
        "10 · optional: Mark Reminders as Completed — clears what you moved"
      ].forEach(function (line) {
        var s = el("p", "mnote", line);
        s.style.padding = "2px 0";
        body.appendChild(s);
      });
      var tail = el("p", "mnote", "Then say “Hey Siri, send to tally book”, open this page, tap Inbox and paste. Reminders with a due date land on that day; the rest land on the day you're looking at.");
      body.appendChild(tail);

      var h2 = el("p", "mnote", "Straight-to-voice — “Log it”");
      h2.style.cssText = "color:var(--ink-2);padding-top:16px;border-top:1px solid var(--hair-2);margin-top:12px";
      body.appendChild(h2);
      [
        "1 · Dictate Text — Stop Listening: After Pause",
        "2 · Add New Reminder — Dictated Text, List: Inbox",
        "3 · Show Notification: “Logged”  (optional)"
      ].forEach(function (line) {
        var s2 = el("p", "mnote", line);
        s2.style.padding = "2px 0";
        body.appendChild(s2);
      });
      var tail2 = el("p", "mnote", "Add that one to your Home Screen, the Action Button, or Back Tap. Speak, it's captured, and it comes over next time you run “send to tally book”.");
      body.appendChild(tail2);
    });
  }

  function openRestore() {
    var ta;
    panel("backup", "Restore", {
      label: "restore", run: function () {
        var v = ta.value.trim();
        if (!v) { toast("Paste a backup first"); return; }
        try {
          var j = JSON.parse(v);
          if (!j.days) throw new Error("not a tally book backup");
          state = j;
          state.days = state.days || {}; state.colls = state.colls || [];
          state.settings = state.settings || { auto: true };
          touch(); paintAll(); show("day"); toast("Restored");
        } catch (e) { toast("Bad backup: " + e.message); }
      }
    }, function (body) {
      var p = el("p", "mnote", "Paste a JSON backup to replace everything in this book.");
      p.style.padding = "0 0 10px";
      body.appendChild(p);
      ta = el("textarea", "field");
      body.appendChild(ta);
    });
  }

  async function doExport() {
    var json = JSON.stringify(state, null, 2);
    var dl = (window.claude && window.claude.use) ? await window.claude.use("downloads") : null;
    if (dl) {
      try { await dl.save({ filename: "tally-book-" + today + ".json", data: json }); return; }
      catch (e) { /* fall through */ }
    }
    panel("backup", "Export", null, function (body) {
      var p = el("p", "mnote", "Copy this and keep it somewhere safe.");
      p.style.padding = "0 0 10px";
      body.appendChild(p);
      var ta = el("textarea", "field");
      ta.value = json;
      ta.style.minHeight = "220px";
      body.appendChild(ta);
      setTimeout(function () { ta.select(); }, 40);
    });
  }

  /* ---------------- sync ---------------- */  function stamp() { var n = new Date(); return pad(n.getHours()) + ":" + pad(n.getMinutes()); }
  function editing() {
    var a = document.activeElement;
    if (!a) return false;
    if (a.isContentEditable) return true;
    var t = a.tagName;
    return t === "INPUT" || t === "TEXTAREA" || t === "SELECT";
  }
  function busy() { return syncing || editing() || view === "panel"; }  function scheduleAuto() {
    clearTimeout(idleT);
    if (autoOff || !state.settings.auto) return;
    idleT = setTimeout(autoSync, SYNC_IDLE);
  }
  function autoSync() {
    if (autoOff || !state.settings.auto) return;
    /* Deliberately NOT gated on "is there anything to push". A device with
       nothing of its own to send still has to PULL, and gating here is what
       made the laptop sit on an empty book while the phone's entries were
       already in Postgres: nothing local was dirty, so it never asked.
       The rate limit below is what stops this becoming chatter. */
    if (busy()) { scheduleAuto(); return; }
    var wait = SYNC_GAP - (Date.now() - lastSyncAt);
    if (wait > 0) { clearTimeout(idleT); idleT = setTimeout(autoSync, wait); return; }
    sync(true);
  }
  /* ---------------- sync ----------------
     One row per day in tally_days, one row per long-tail key in tally_book.

     WHAT GETS PUSHED IS WORKED OUT BY DIFFING, not by having each of the
     ~50 touch() call sites declare what it changed. A call site that forgot
     to name its day would be an entry that silently never leaves the phone,
     and that failure is invisible until the day you go looking for it on
     the laptop. A diff cannot forget. */

  var SNAP = "jfr-tally-synced-v1";
  var BOOK_KEYS = ["colls", "months", "rules", "people", "inbox",
                   "trackers", "track", "settings", "lots"];

  var snapshot;
  try {
    snapshot = JSON.parse(localStorage.getItem(SNAP) || "null");
  } catch (e) { snapshot = null; }
  if (!snapshot || !snapshot.days) snapshot = { days: {}, book: {}, pulledAt: null };

  function saveSnapshot() {
    try { localStorage.setItem(SNAP, JSON.stringify(snapshot)); } catch (e) { /* quota */ }
  }
  function ser(v) { return JSON.stringify(v === undefined ? null : v); }
  function clone(v) { return v === undefined ? null : JSON.parse(JSON.stringify(v)); }

  /* paintAll() calls day(sel), which CREATES {entries:[],reflect:""} for
     whatever day you are looking at. That placeholder is not something you
     typed, and treating it as local work is what kept the laptop showing an
     empty page: opening the app minted an empty "today", the pull saw a
     locally dirty day and refused to overwrite it, and the phone's real
     entries were declined every single sync. */
  /* "Has anything actually been written here?" - by content, not by shape.
     months is an object of six month keys even when the future log is
     untouched, so counting keys would call it populated and let a blank
     one overwrite a real one. */
  function bookEmpty(key, v) {
    if (v === null || v === undefined) return true;
    if (Array.isArray(v)) return v.length === 0;
    if (typeof v === "object") {
      var ks = Object.keys(v);
      if (!ks.length) return true;
      if (key === "months") {
        return ks.every(function (k) {
          var m = v[k];
          return !m || !m.entries || !m.entries.length;
        });
      }
      return false;
    }
    return false;
  }

  /* Painting a day MUTATES it: groupsOf() lazily assigns groups:[] and
     ensureOrd() fills in a missing ord. Neither goes through touch(), so
     the day you are looking at silently stops matching the snapshot and is
     judged "locally dirty" - which made the pull refuse every later update
     to it. Entries arriving from another device routinely lack ord, so
     merely viewing a day was enough to freeze it.

     So dirtiness is judged on a NORMALISED record: both sides get the same
     defaults applied before they are compared. It is a copy - the real
     record is left alone. */
  function normDay(doc) {
    if (!doc) return null;
    var d = JSON.parse(JSON.stringify(doc));
    if (!Array.isArray(d.entries)) d.entries = [];
    if (typeof d.reflect !== "string") d.reflect = "";
    if (!Array.isArray(d.groups)) d.groups = [];   /* default, not discard - a
                                                      real grouping must survive */
    if (d.entries.some(function (e) { return typeof e.ord !== "number"; })) {
      d.entries.slice().sort(function (a, b) {
        if (!!a.time !== !!b.time) return a.time ? -1 : 1;
        if (a.time && b.time && a.time !== b.time) return a.time < b.time ? -1 : 1;
        return 0;
      }).forEach(function (e, i) { if (typeof e.ord !== "number") e.ord = i * 10; });
    }
    return d;
  }
  function serDay(doc) { return JSON.stringify(normDay(doc)); }

  function emptyDay(doc) {
    if (!doc) return true;
    if (doc.entries && doc.entries.length) return false;
    return !(doc.reflect && doc.reflect.trim());
  }

  function dirtyDays() {
    return Object.keys(state.days).filter(function (k) {
      if (serDay(state.days[k]) === serDay(snapshot.days[k])) return false;
      /* Never push a placeholder we invented ourselves - it would land as an
         empty row on top of a day another device had filled in. Emptying a
         day you HAD written still counts, because then it is in the snapshot. */
      if (emptyDay(state.days[k]) && !(k in snapshot.days)) return false;
      return true;
    });
  }
  function dirtyBookKeys() {
    return BOOK_KEYS.filter(function (k) {
      return ser(state[k]) !== ser(snapshot.book[k]);
    });
  }

  /* Every write checks the rows it got back. PostgREST answers a refused
     write with an empty result and no error, so without this a sync that
     RLS rejected outright reports success and the dot goes green. */
  function wrote(res, n, what) {
    if (res.error) throw res.error;
    if (!res.data || res.data.length !== n) {
      throw new Error("the database refused the " + what + " write");
    }
  }

  async function pushChanges() {
    var days = dirtyDays(), keys = dirtyBookKeys();
    if (!days.length && !keys.length) return 0;

    if (days.length) {
      var dayRows = days.map(function (k) {
        return { user_id: TB_USER_ID, day: k, doc: state.days[k] };
      });
      wrote(await sb.from("tally_days")
        .upsert(dayRows, { onConflict: "user_id,day" }).select("day"),
        dayRows.length, "day");
      days.forEach(function (k) { snapshot.days[k] = clone(state.days[k]); });
    }

    if (keys.length) {
      var bookRows = keys.map(function (k) {
        return { user_id: TB_USER_ID, key: k, doc: state[k] === undefined ? null : state[k] };
      });
      wrote(await sb.from("tally_book")
        .upsert(bookRows, { onConflict: "user_id,key" }).select("key"),
        bookRows.length, "book");
      keys.forEach(function (k) { snapshot.book[k] = clone(state[k]); });
    }

    saveSnapshot();
    return days.length + keys.length;
  }

  /* Pull everything of mine touched since the last look. First run has no
     watermark and takes the lot, which is also the restore path onto a new
     device.

     CONFLICT RULE: a locally dirty day is NOT overwritten by the remote
     copy. The person is typing on THIS device; throwing that away to honour
     a row written elsewhere is the one outcome that loses work you can see.
     The local copy wins and is pushed immediately after, so the two ends
     agree again within the same sync. */
  async function pullChanges() {
    var since = snapshot.pulledAt || "1970-01-01T00:00:00.000Z";
    var mine = dirtyDays(), mineKeys = dirtyBookKeys();
    var applied = 0, skipped = 0;

    /* The watermark is the newest updated_at we have actually SEEN, not the
       time on this device. updated_at is stamped by Postgres; a laptop clock
       running a few minutes fast would otherwise write a watermark into the
       future and skip every row the phone wrote in between - permanently,
       and silently. */
    var seen = snapshot.pulledAt;
    function mark(ts) {
      if (!ts) return;
      if (!seen || Date.parse(ts) > Date.parse(seen)) seen = ts;
    }

    var d = await sb.from("tally_days").select("day,doc,updated_at").gt("updated_at", since);
    if (d.error) throw d.error;
    (d.data || []).forEach(function (row) {
      mark(row.updated_at);
      /* An EMPTY remote day never replaces a local day that has content -
         whatever is wrong upstream, deleting what is in front of the person
         is not the recovery. This is asymmetric on purpose: clearing a day
         deliberately is rare and easily redone, losing a day of entries is
         not. Advancing the snapshot to the remote copy makes the local day
         read as dirty, so the very next push repairs the server too. */
      if (emptyDay(row.doc) && !emptyDay(state.days[row.day])) {
        snapshot.days[row.day] = clone(row.doc);
        skipped++;
        return;
      }
      /* A day this device has never synced cannot outrank the server: it
         has no history to be "ahead" of. This is the fresh-device case -
         everything looks locally dirty against an empty snapshot, so
         without this the pull refuses the real book and the push then
         writes defaults over it. */
      var neverSynced = !(row.day in snapshot.days);
      if (neverSynced && !emptyDay(row.doc)) {
        state.days[row.day] = row.doc;
        snapshot.days[row.day] = clone(row.doc);
        applied++;
        return;
      }
      /* Local wins only if there is actually something local to lose. */
      if (mine.indexOf(row.day) >= 0 && !emptyDay(state.days[row.day])) { skipped++; return; }
      /* Our own push comes back on the next pull. Applying it would repaint
         the screen for no reason - and a repaint mid-sentence eats the
         caret - so an identical doc only advances the snapshot. */
      if (serDay(state.days[row.day]) === serDay(row.doc)) {
        snapshot.days[row.day] = clone(row.doc);
        return;
      }
      state.days[row.day] = row.doc;
      snapshot.days[row.day] = clone(row.doc);
      applied++;
    });

    var b = await sb.from("tally_book").select("key,doc,updated_at").gt("updated_at", since);
    if (b.error) throw b.error;
    (b.data || []).forEach(function (row) {
      mark(row.updated_at);
      if (ser(state[row.key]) === ser(row.doc)) {
        snapshot.book[row.key] = clone(row.doc);
        return;
      }
      /* Never let a blank value overwrite a populated one - this is what
         emptied John's collections on 2026-08-31: a device with no
         snapshot pushed its defaults over two real lists. Advancing the
         snapshot marks ours dirty so the next push repairs the server. */
      if (bookEmpty(row.key, row.doc) && !bookEmpty(row.key, state[row.key])) {
        snapshot.book[row.key] = clone(row.doc);
        skipped++;
        return;
      }
      var neverSyncedKey = !(row.key in snapshot.book);
      if (neverSyncedKey || bookEmpty(row.key, state[row.key])) {
        if (row.doc !== null) state[row.key] = row.doc;
        snapshot.book[row.key] = clone(row.doc);
        applied++;
        return;
      }
      if (mineKeys.indexOf(row.key) >= 0) { skipped++; return; }
      if (row.doc !== null) state[row.key] = row.doc;
      snapshot.book[row.key] = clone(row.doc);
      applied++;
    });

    snapshot.pulledAt = seen || snapshot.pulledAt;
    saveSnapshot();
    if (applied) {
      try { localStorage.setItem(LS, JSON.stringify(state)); } catch (e) { /* quota */ }
    }
    return { applied: applied, skipped: skipped };
  }

  async function sync(auto) {
    if (syncing) return;
    if (!TB_USER_ID) {
      autoOff = true;
      if (!auto) toast("Not signed in — the book is saved on this device only.");
      return;
    }
    if (!navigator.onLine) {
      if (!auto) toast("No signal — saved here, it'll go up when you're back.");
      return;
    }
    syncing = true; paintDot();
    try {
      var got = await pullChanges();
      var sent = await pushChanges();

      syncedAt = state.updatedAt;
      lastSyncAt = Date.now();
      lastStamp = stamp();
      autoOff = false;

      if (got.applied) paintAll();
      if (!auto) {
        toast(sent || got.applied
          ? "Synced" + (sent ? " · " + sent + " up" : "") + (got.applied ? " · " + got.applied + " down" : "")
          : "Already up to date");
      }
    } catch (e) {
      lastSyncAt = Date.now();
      var msg = (e && e.message) ? e.message : "unknown";
      /* 42501 is an RLS refusal — the account was deactivated, or the
         session belongs to someone else now. Never silent: this is the
         case where the book looks fine and is quietly going nowhere. */
      if (e && e.code === "42501") {
        autoOff = true;
        toast("The database refused the write — check you're still signed in.");
      } else if (!auto) {
        toast("Sync failed: " + msg);
      }
      if (window.console) console.error("tally sync", e);
    } finally {
      syncing = false;
      paintDot();
      scheduleAuto();
    }
  }

  /* Reachable from the auth layer so signing in pulls straight away. */
  window.__tallySync = sync;

  /* The dot is also the manual sync. paintDot() has always looked for it;
     the artifact simply never had one in its markup, so the whole sync
     indicator was dead code. */
  (function () {
    var d = $("syncDot");
    if (d) d.onclick = function () { sync(false); };
  })();

  /* ---------------- paint ---------------- */
  function paintAll() {
    paintDayView();
    paintSoon();
    paintLoops();
    paintMonth();
    paintLists();
    paintInbox();
    paintDelegated();
    paintLots();
    paintMonthTasks();
    paintFuture();
    paintTrackers();
    $("reflect").value = day(sel).reflect || "";
    $("mRepeatsV").textContent = state.rules.length ? state.rules.length + " running" : "none";
    $("mAutoV").textContent = state.settings.auto ? "on" : "off";
    if (!$("capText").value.trim() && !capUnfiled) { $("capDate").value = sel; $("capTime").value = ""; }
    paintHint();
    applySize();
    paintTop();
  }

  /* ---------------- wiring ---------------- */
  $("capMic").hidden = false;
  $("capMic").innerHTML = SR ? micIcon() : keyboardIcon();
  if (!SR) blockMic();
  $("capMic").onclick = function () {
    if (micBlocked || !SR) { toKeyboard(); return; }
    startListening();
  };
  $("capAdd").onclick = add;
  $("capText").addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); add(); } });
  ["task", "event", "note"].forEach(function (t) {
    $("tType-" + t).onclick = function () {
      capType = t;
      ["task", "event", "note"].forEach(function (x) { $("tType-" + x).setAttribute("aria-pressed", String(x === t)); });
    };
  });
  $("capText").addEventListener("input", paintHint);
  $("capDate").addEventListener("change", function () { unfiledOff(); paintHint(); });
  $("capTime").addEventListener("change", paintHint);
  $("capToday").onclick = function () { unfiledOff(); $("capDate").value = today; paintHint(); };
  $("capTom").onclick = function () { unfiledOff(); $("capDate").value = addDays(today, 1); paintHint(); };
  $("capClear").onclick = function () { unfiledOff(); resetWhen(); };
  $("capWhenBtn").onclick = function () {
    var row = $("capWhenRow");
    row.hidden = !row.hidden;
    this.setAttribute("aria-expanded", String(!row.hidden));
  };
  $("capPrio").onclick = function () { capPrio = !capPrio; this.setAttribute("aria-pressed", String(capPrio)); };
  $("toNotes").onclick = function () { show("notes"); };
  [].forEach.call($("tabs").children, function (t) {
    t.onclick = function () { show(t.getAttribute("data-v")); };
  });
  [].forEach.call($("monthSeg").children, function (b) {
    b.onclick = function () { segTo(b.getAttribute("data-p")); };
  });
  function addMonthTask() {
    var i = $("mtText"), v = i.value.trim();
    if (!v) return;
    month(mKey(sel)).entries.push({ id: uid(), type: "task", text: v, st: 0, prio: false, time: null });
    i.value = "";
    touch(); paintAll(); segTo("tasks"); i.focus();
  }
  $("mtAdd").onclick = addMonthTask;
  $("mtText").addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); addMonthTask(); } });
  $("trkAdd").onclick = newTracker;
  $("qText").addEventListener("input", paintResults);
  [].forEach.call($("listSeg").children, function (b) {
    b.onclick = function () { lsegTo(b.getAttribute("data-l")); };
  });
  $("waitingLine").onclick = function () { show("lists"); lsegTo("who"); };
  $("inboxLine").onclick = function () { show("lists"); lsegTo("inbox"); };
  $("capUnfiled").onclick = function () {
    capUnfiled = !capUnfiled;
    this.setAttribute("aria-pressed", String(capUnfiled));
    paintHint();
  };
  $("mMap").onclick = openMap;
  $("mRepeats").onclick = openRepeats;
  $("mInbox").onclick = openInbox;
  $("mLots").onclick = openLots;
  $("mExport").onclick = doExport;
  $("mRestore").onclick = openRestore;
  $("mSize").onclick = function () {
    var i = 0;
    SIZES.forEach(function (x, n) { if (Math.abs(x.v - state.settings.size) < 0.001) i = n; });
    var next = SIZES[(i + 1) % SIZES.length];
    state.settings.size = next.v;
    applySize();
    touch();
    toast("Text size: " + next.name);
  };
  $("mAuto").onclick = function () {
    state.settings.auto = !state.settings.auto;
    $("mRepeatsV").textContent = state.rules.length ? state.rules.length + " running" : "none";
    $("mAutoV").textContent = state.settings.auto ? "on" : "off";
    touch();
    toast(state.settings.auto ? "Auto-sync on" : "Auto-sync off");
  };
  var refT;
  $("reflect").addEventListener("input", function () {
    clearTimeout(refT);
    var v = this.value;
    refT = setTimeout(function () { day(sel).reflect = v; touch(); }, 400);
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && view !== "day") { show("day"); return; }
    if (e.key === "/" && !editing()) { e.preventDefault(); show("day"); $("capText").focus(); }
  });
  document.addEventListener("visibilitychange", function () {
    if (autoOff || !state.settings.auto) return;
    if (document.visibilityState === "hidden") {
      /* leaving: push what this device is holding, if anything */
      if (state.updatedAt <= syncedAt) return;
      clearTimeout(idleT);
      sync(true);
      return;
    }
    /* coming back: pull. Picking the laptop up after a day of capture on the
       phone is exactly when the book is most likely to be stale. */
    clearTimeout(idleT);
    sync(true);
  });
  window.addEventListener("blur", function () { setTimeout(autoSync, 800); });

  materialize();
  paintAll();
  show(view);
  if (resume && resume.draft) $("capText").value = resume.draft;
  if (resume) lastSyncAt = Date.now();
  scheduleAuto();
};
