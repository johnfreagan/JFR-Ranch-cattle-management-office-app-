#!/usr/bin/env node
// =====================================================================
// Pre-deploy check for the JFR office + field apps.
//
// CLAUDE.md already requires two gates after any index.html edit: the big
// script block must parse, and <div> open/close must balance outside
// script/style. This runs both, plus the one that was missing.
//
// The missing one: index.html declares ~265 functions in a SINGLE 13,000
// line scope. On 2026-08-25 `renderDoctoringTable` was declared twice at
// top level. Function declarations hoist and the LAST one wins, so the
// Doctoring report silently called the lot-detail renderer, passed it a
// `rows` argument it ignored, and never wrote its own table. No error, no
// stack trace, just a report that stopped rendering. `ceilTo` was doubled
// the same way and only got away with it by being identical.
//
// Until the script is split into modules, this check is what stands
// between that class of bug and production.
//
//   node tools/check.mjs
//
// Exits non-zero on failure so it can gate a deploy.
// =====================================================================
import { readFileSync } from 'node:fs';

let failures = 0;
const fail = (m) => { console.error(`  FAIL  ${m}`); failures++; };
const pass = (m) => console.log(`  ok    ${m}`);

// --- helpers ---------------------------------------------------------

// Strip strings, template literals, comments and regex literals so brace
// counting and declaration scanning see code and nothing else.
function stripLiterals(src) {
    let out = '', i = 0, prev = '';
    const n = src.length;
    while (i < n) {
        const c = src[i];
        if (c === '/' && src[i + 1] === '/') { while (i < n && src[i] !== '\n') i++; continue; }
        if (c === '/' && src[i + 1] === '*') {
            i += 2;
            while (i < n && !(src[i] === '*' && src[i + 1] === '/')) { if (src[i] === '\n') out += '\n'; i++; }
            i += 2; continue;
        }
        if (c === '"' || c === "'") {
            const q = c; i++;
            while (i < n && src[i] !== q) { if (src[i] === '\\') i++; i++; }
            i++; out += '""'; prev = q; continue;
        }
        if (c === '`') {
            i++; let depth = 0;
            while (i < n) {
                const d = src[i];
                if (d === '\\') { i += 2; continue; }
                if (d === '\n') { out += '\n'; i++; continue; }
                if (d === '$' && src[i + 1] === '{') { depth++; i += 2; continue; }
                if (d === '}' && depth > 0) { depth--; i++; continue; }
                if (d === '`' && depth === 0) { i++; break; }
                i++;
            }
            out += '""'; prev = '`'; continue;
        }
        if (c === '/' && (prev === '' || '(,=:[!&|?{};+-*%~^<>'.includes(prev))) {
            i++; let inClass = false;
            while (i < n) {
                const d = src[i];
                if (d === '\\') { i += 2; continue; }
                if (d === '[') { inClass = true; i++; continue; }
                if (d === ']') { inClass = false; i++; continue; }
                if (d === '/' && !inClass) { i++; break; }
                if (d === '\n') break;
                i++;
            }
            while (i < n && /[gimsuyd]/.test(src[i])) i++;
            out += '/RE/'; prev = '/'; continue;
        }
        out += c;
        if (!/\s/.test(c)) prev = c;
        i++;
    }
    return out;
}

// Every `function name(` declared at brace depth 0 of the given source.
function topLevelFunctions(code) {
    const clean = stripLiterals(code);
    const found = new Map();
    let depth = 0, line = 1;
    for (let i = 0; i < clean.length; i++) {
        const c = clean[i];
        if (c === '\n') { line++; continue; }
        if (c === '{') { depth++; continue; }
        if (c === '}') { depth--; continue; }
        if (depth !== 0) continue;
        const m = /^(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/.exec(clean.slice(i, i + 80));
        if (m && (i === 0 || !/[\w$.]/.test(clean[i - 1]))) {
            if (!found.has(m[1])) found.set(m[1], []);
            found.get(m[1]).push(line);
            i += m[0].length - 1;
        }
    }
    return found;
}

function inlineScripts(html) {
    return [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
}

async function parses(code, label) {
    // node --check equivalent, without shelling out.
    try { new (async function () {}).constructor(code); return true; }
    catch (e) { fail(`${label} does not parse: ${e.message}`); return false; }
}

// --- checks ----------------------------------------------------------

async function checkHtmlApp(path) {
    console.log(`\n${path}`);
    const src = readFileSync(path, 'utf8');

    const scripts = inlineScripts(src);
    if (!scripts.length) { fail('no inline <script> block found'); return; }

    for (const [i, s] of scripts.entries()) {
        if (await parses(s, `inline script block ${i + 1}/${scripts.length}`)) {
            pass(`inline script block ${i + 1}/${scripts.length} parses`);
        }
    }

    // Duplicate top-level declarations across ALL inline blocks sharing
    // the page's global scope.
    const seen = new Map();
    for (const s of scripts) {
        for (const [name, lines] of topLevelFunctions(s)) {
            seen.set(name, (seen.get(name) || []).concat(lines));
        }
    }
    const dupes = [...seen].filter(([, l]) => l.length > 1);
    if (dupes.length) {
        for (const [name, lines] of dupes) {
            fail(`function "${name}" declared ${lines.length}x at top level (script-relative lines ${lines.join(', ')}) - the last one silently wins`);
        }
    } else {
        pass(`no duplicate top-level function declarations (${seen.size} checked)`);
    }

    // <div> balance outside script/style, per CLAUDE.md.
    const bare = src.replace(/<script[\s\S]*?<\/script>/g, '').replace(/<style[\s\S]*?<\/style>/g, '');
    const open = (bare.match(/<div\b/g) || []).length;
    const close = (bare.match(/<\/div>/g) || []).length;
    if (open !== close) fail(`<div> unbalanced outside script/style: ${open} open, ${close} close`);
    else pass(`<div> balanced outside script/style (${open})`);
}

async function checkJsFile(path) {
    console.log(`\n${path}`);
    const src = readFileSync(path, 'utf8');
    if (await parses(src, 'file')) pass('parses');

    const dupes = [...topLevelFunctions(src)].filter(([, l]) => l.length > 1);
    if (dupes.length) {
        for (const [name, lines] of dupes) {
            fail(`function "${name}" declared ${lines.length}x at top level (lines ${lines.join(', ')}) - the last one silently wins`);
        }
    } else {
        pass('no duplicate top-level function declarations');
    }
}

await checkHtmlApp('index.html');
await checkHtmlApp('field-app/index.html');
await checkJsFile('field-app/app.js');

console.log('');
if (failures) { console.error(`${failures} check(s) failed - do NOT deploy.\n`); process.exit(1); }
console.log('All checks passed.\n');
