#!/usr/bin/env node
// The same post-edit gate as validate.jxa.js, for a machine that has node.
// CLAUDE.md requires both checks before shipping; the JXA copy exists because
// John's machine has no node, and this one exists because the build sessions
// have no osascript. Keep the two in step - they must agree on PASS/FAIL.
const fs = require('fs');
const path = process.argv[2] || 'index.html';
const html = fs.readFileSync(path, 'utf8');
const out = [];
let ok = true;

// 1. every <script> block must parse
const re = /<script\b[^>]*>([\s\S]*?)<\/script>/g;
const blocks = [];
let m;
while ((m = re.exec(html)) !== null) blocks.push(m[1]);
let largest = 0;
blocks.forEach((b, i) => {
    if (b.length > largest) largest = b.length;
    if (!b.trim()) return;
    try { new Function(b); }
    catch (e) { ok = false; out.push('PARSE FAIL in script block ' + i + ': ' + e.message); }
});
out.push(`script blocks: ${blocks.length}, largest ${largest} chars — ` +
         (ok ? 'all parse OK' : 'PARSE ERRORS'));

// 2. div balance outside script/style
const stripped = html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/g, '')
    .replace(/<!--[\s\S]*?-->/g, '');
const opens  = (stripped.match(/<div\b/g)  || []).length;
const closes = (stripped.match(/<\/div>/g) || []).length;
if (opens !== closes) ok = false;
out.push(`divs: ${opens} open / ${closes} close — ` + (opens === closes ? 'BALANCED' : 'UNBALANCED'));

out.push(ok ? 'RESULT: PASS' : 'RESULT: FAIL');
console.log(out.join('\n'));
process.exit(ok ? 0 : 1);
