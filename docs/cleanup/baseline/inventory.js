// Usage: node inventory.js <repo> > functions.md
const fs = require('fs'), path = require('path');
const repo = process.argv[2];
const files = ['index.html', 'field-app/app.js', 'field-app/index.html', 'field-app/sw.js'];
const text = {}, lines = {};
for (const f of files) { text[f] = fs.readFileSync(path.join(repo, f), 'utf8'); lines[f] = text[f].split('\n'); }
const defRe = /^(\s*)(async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(/;
const defs = []; // {file, name, line, indent}
for (const f of ['index.html', 'field-app/app.js', 'field-app/index.html']) {
  lines[f].forEach((l, i) => { const m = l.match(defRe); if (m) defs.push({ file: f, name: m[3], line: i + 1, indent: m[1].length }); });
}
// The office app and the field app are separate pages: a reference only counts
// inside the same app.
const app = f => f.startsWith('field-app/') ? 'field' : 'office';
const appFiles = { office: ['index.html'], field: ['field-app/app.js', 'field-app/index.html', 'field-app/sw.js'] };
const esc = s => s.replace(/[$]/g, '\\$');
function refs(name, a) {
  const re = new RegExp('(^|[^\\w$.])' + esc(name) + '(?![\\w$])');
  const reDot = new RegExp('(window|self|globalThis)\\.' + esc(name) + '(?![\\w$])');
  const out = [];
  for (const f of appFiles[a]) lines[f].forEach((l, i) => {
    if (defRe.test(l) && l.match(defRe)[3] === name) return;
    if (re.test(l) || reDot.test(l)) {
      const inHandler = /\bon[a-z]+\s*=\s*["'`\\]/.test(l) && new RegExp('on[a-z]+\\s*=[^>]*' + esc(name)).test(l);
      out.push({ f, n: i + 1, h: inHandler });
    }
  });
  return out;
}
const byKey = {};
for (const d of defs) (byKey[app(d.file) + ':' + d.name] ||= []).push(d);
const rows = defs.map(d => ({ ...d, r: refs(d.name, app(d.file)), dup: byKey[app(d.file) + ':' + d.name].length > 1 }));
const short = f => ({ 'index.html': 'idx', 'field-app/app.js': 'app', 'field-app/index.html': 'fidx', 'field-app/sw.js': 'sw' })[f];
const fmt = r => r.slice(0, 15).map(x => short(x.f) + ':' + x.n + (x.h ? 'ʰ' : '')).join(' ') + (r.length > 15 ? ` …+${r.length - 15}` : '');
const o = [];
o.push('# Function inventory (P0 baseline)', '',
  `Generated 2026-10-09 from commit ${process.argv[3] || ''} by a text scan (script: docs/cleanup/baseline/inventory.js).`, '',
  'Every `function name(` declaration in the office app (`index.html`) and the field app (`field-app/app.js`, `field-app/index.html`), with every line in the same app that mentions the name as a word. The two apps are separate pages, so a name only counts within its own app.', '',
  'How to read it:', '',
  '- **Refs** lists `file:line` for each mentioning line (first 15). `idx` = index.html, `app` = field-app/app.js, `fidx` = field-app/index.html, `sw` = field-app/sw.js. A trailing `ʰ` marks a line where the name sits inside an inline `on…=` handler.',
  '- A text scan over-counts: a mention in a comment or a string that is not a call still counts as a ref. It also misses names built at run time (`window[\'x\' + y]`). So **zero refs** means "nothing names it in this app", **not** "safe to delete": P7 checks those across the rest of the repo before anyone proposes a deletion.',
  '- **Indent** is the declaration\'s leading spaces. Functions nested inside other functions are listed too; indent tells them apart.', '');
const dups = rows.filter(r => r.dup);
const zero = rows.filter(r => r.r.length === 0);
const count = a => rows.filter(r => app(r.file) === a).length;
o.push('## Summary', '', '| | Office | Field |', '|---|---|---|',
  `| Function declarations | ${count('office')} | ${count('field')} |`,
  `| Names declared more than once | ${new Set(dups.filter(r => app(r.file) === 'office').map(r => r.name)).size} | ${new Set(dups.filter(r => app(r.file) === 'field').map(r => r.name)).size} |`,
  `| Zero refs | ${zero.filter(r => app(r.file) === 'office').length} | ${zero.filter(r => app(r.file) === 'field').length} |`, '');
o.push('## Names declared more than once', '', 'Same name declared twice in one app. At top level the later one silently wins; nested ones may be legitimate (a local helper in two different functions). Check each before calling it a bug.', '');
if (!dups.length) o.push('None.', '');
else { o.push('| Name | Declarations (file:line, indent) |', '|---|---|');
  const seen = new Set();
  for (const r of dups) { const k = app(r.file) + ':' + r.name; if (seen.has(k)) continue; seen.add(k);
    o.push(`| \`${r.name}\` | ${byKey[k].map(d => `${short(d.file)}:${d.line} (${d.indent})`).join(', ')} |`); }
  o.push(''); }
o.push('## Zero refs (suspects for P7, not a delete list)', '');
if (!zero.length) o.push('None.', '');
else { o.push('| Name | Defined | Indent |', '|---|---|---|'); for (const r of zero) o.push(`| \`${r.name}\` | ${short(r.file)}:${r.line} | ${r.indent} |`); o.push(''); }
for (const a of ['office', 'field']) {
  o.push(`## All functions: ${a === 'office' ? 'office app' : 'field app'}`, '', '| Name | Defined | Refs | Where |', '|---|---|---|---|');
  for (const r of rows.filter(r => app(r.file) === a)) o.push(`| \`${r.name}\` | ${short(r.file)}:${r.line} | ${r.r.length} | ${fmt(r.r)} |`);
  o.push('');
}
process.stdout.write(o.join('\n'));
