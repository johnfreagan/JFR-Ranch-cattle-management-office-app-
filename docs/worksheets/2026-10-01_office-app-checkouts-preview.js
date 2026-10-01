const fs=require('fs');
const CSS=fs.readFileSync('/tmp/claude-0/-home-user/3faedbbc-c217-55e7-8621-b0074313ab00/scratchpad/app.css.html','utf8');
function fmtNum(n,d=0){if(n==null||isNaN(n)) return '—';return Number(n).toLocaleString('en-US',{minimumFractionDigits:d,maximumFractionDigits:d});}
const esc=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

// The med-room sheet, transcribed. Two men on Excede at different sizes -
// the thing the screen could not record until today.
const log=[
 {date:'2026-10-01', who:'Luke',   med:'Excede',            bottles:2, size:100, unit:'mL', ret:false},
 {date:'2026-10-01', who:'Beto',   med:'Excede',            bottles:1, size:250, unit:'mL', ret:false},
 {date:'2026-10-01', who:'Luke',   med:'Resflor',           bottles:1, size:500, unit:'mL', ret:false},
 {date:'2026-09-28', who:'Beto',   med:'Enroflox(Baytril)', bottles:2, size:500, unit:'mL', ret:false},
 {date:'2026-09-26', who:'Luke',   med:'Draxxin KP',        bottles:0.5, size:250, unit:'mL', ret:true},
];
let rows='';
log.forEach(r=>{
  rows+=`<tr>
    <td>${r.date}</td><td>${esc(r.who)}</td><td>${esc(r.med)}</td>
    <td class="num">${fmtNum(r.bottles,2)}</td>
    <td class="num muted">${fmtNum(r.size,0)}</td>
    <td class="num">${fmtNum(r.bottles*r.size,1)}</td>
    <td class="muted">${esc(r.unit)}</td>
    <td>${r.ret?'<span class="muted">returned</span>':''}</td></tr>`;
});

const page=`<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Checkouts</title>${CSS}
<style>body{background:#f3f4f6;padding:18px}
 .shot{max-width:1180px;margin:0 auto 22px}
 .shot > h3{font:600 12px/1.4 -apple-system,Segoe UI,Roboto,sans-serif;letter-spacing:.4px;
   text-transform:uppercase;color:#6b7280;margin:0 0 6px}
 .preview-note{border-left:3px solid #15803d;background:#f0fdf4;padding:10px 12px;margin:0 0 16px;font-size:12px}
</style></head><body>
<div class="shot"><div class="preview-note"><strong>There is a Checkouts screen</strong> &mdash; Inventory &rarr; Meds
&rarr; Checkouts. It is the med-room sheet, typed. <strong>Bottle size is new as of this change</strong>: it fills in
from the catalog and you change it when the size that left the room is not that one.</div></div>

<div class="shot"><h3>Inventory → Meds → Checkouts</h3>
<div class="card">
<div class="card-header"><h2>Checkouts</h2></div>
<p class="muted" style="font-size:12px;margin:-6px 0 12px 0;">
  Who has what. A checkout does <strong>not</strong> move stock &mdash; the bottle is still ranch inventory,
  just in somebody's hand. Custody only.</p>
<div class="form-grid">
 <div><label>Date</label><input type="date" value="2026-10-01"></div>
 <div><label>Crew member</label><select><option>Luke</option><option>Beto</option></select></div>
 <div><label>Medication</label><select><option selected>Excede</option><option>Resflor</option></select></div>
 <div><label>Bottles</label><input type="number" step="0.25" value="2"></div>
 <div><label>Bottle size</label><input type="number" step="0.01" value="100">
   <div class="muted" style="font-size:11px;margin-top:2px;">Fills in from the catalog.
   <strong>Change it</strong> when the size that left the room is not that one &mdash; the med-room sheet says which.</div></div>
</div>
<div style="display:flex;gap:8px;margin-top:12px;">
  <button class="primary">Record checkout</button><button>Record return</button></div>

<h4 style="margin:22px 0 6px 0;">Checkout log</h4>
<p class="muted" style="font-size:12px;margin:0 0 8px 0;">
  Who has bottles &mdash; and deliberately nothing more. Two men work together, draw out of one man's box, and
  the other writes the treatment up, so doses recorded by a man are not doses drawn from his box.
  <strong>Shrink is a crew number.</strong> This list is for finding a bottle.</p>
<table><thead><tr><th>Date</th><th>Crew member</th><th>Medication</th>
  <th class="num">Bottles</th><th class="num">Bottle size</th><th class="num">Units</th><th>Unit</th><th></th>
</tr></thead><tbody>${rows}</tbody></table>
<p class="muted" style="font-size:12px;margin-top:10px;">Luke's two Excede are <strong>100 mL</strong> bottles and
Beto's one is a <strong>250</strong>. Before today both read off the catalog's single size, so Luke's 200 mL was
recorded as 500.</p>
</div></div>
</body></html>`;
fs.writeFileSync('checkouts.html',page);
console.log('ok');
