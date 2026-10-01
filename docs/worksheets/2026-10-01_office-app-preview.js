// Renders the office app's medicine screens outside the app, using its OWN
// stylesheet and its OWN template strings, filled with real count rows. It
// exists because the screens cannot be looked at without a login, and a screen
// nobody looked at is where the Excede 0.9 open-box problem lived.
//
//   node 2026-10-01_office-app-preview.js     (needs app.css.html alongside:
//   the <style> block lifted out of index.html, and the data json)

const fs=require('fs');
const CSS=fs.readFileSync('app.css.html','utf8');
const L=require('./data.json');

// ---- the app's own helpers, copied verbatim from index.html ----
function fmtMoney(n){if(n==null||isNaN(n)) return '—';return '$'+Number(n).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2});}
function fmtNum(n,d=0){if(n==null||isNaN(n)) return '—';return Number(n).toLocaleString('en-US',{minimumFractionDigits:d,maximumFractionDigits:d});}
const escapeHtml=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

const countedUnits=l=>{
  if(l.barn_full==null&&l.barn_open==null&&l.crew_full==null&&l.crew_open==null) return null;
  return l.bottle_size*((l.barn_full||0)+(l.barn_open||0)+(l.crew_full||0)+(l.crew_open||0));
};

// ================= 1. COUNTS LIST (what is there today) =================
let counts=`<table><thead><tr><th>Date</th><th>Location</th><th>Counted by</th>
  <th>Status</th><th>Crew</th><th></th></tr></thead><tbody>
  <tr><td>2026-09-30 <span class="muted">(opening)</span></td><td>Ranch</td><td>John Reagan</td>
  <td><span style="color:#b45309">draft</span></td><td></td>
  <td><button>Continue</button></td></tr>
  </tbody></table>`;

// ================= 2. COUNT ENTRY GRID ==================================
const dis='';
const box=(l,field,step)=>`<input type="number" step="${step}" min="0"`+
  (field.endsWith('open')?' max="0.75"':'')+
  ` style="width:78px;text-align:right;"${dis}`+
  ` value="${l[field]==null?'':l[field]}">`;
let grid=`<table><thead><tr>
  <th>Medication</th><th>Unit</th><th class="num">Bottle size</th>
  <th class="num">Barn full</th><th class="num">Barn open</th>
  <th class="num">Crew full</th><th class="num">Crew open</th>
  <th class="num">Counted</th><th class="num">Variance</th></tr></thead><tbody>`;
L.forEach(l=>{
  const counted=countedUnits(l);
  const variance=counted==null?null:counted-0;
  if(l.needs_size){
    grid+=`<tr><td>${escapeHtml(l.name)}</td><td class="muted">—</td>
      <td colspan="7" style="color:#b45309;font-size:12px;">
      Needs a container size on the Medications tab before it can be stocked or counted.</td></tr>`;
    return;
  }
  const over = (l.crew_open!=null && l.crew_open>0.75);
  grid+=`<tr${over?' style="background:#fef2f2;"':''}>
    <td>${escapeHtml(l.name)}${l.unpriced?' <span class="muted" style="font-size:11px;color:#b45309">unpriced</span>':''}</td>
    <td class="muted">${escapeHtml(l.unit||'')}</td>
    <td class="num muted">${l.bottle_size?fmtNum(l.bottle_size,0):'—'}</td>
    <td class="num">${box(l,'barn_full','1')}</td>
    <td class="num">${box(l,'barn_open','0.25')}</td>
    <td class="num">${box(l,'crew_full','1')}</td>
    <td class="num">${box(l,'crew_open','0.25')}${over?' <span style="color:#b91c1c;font-size:11px;font-weight:600">&gt; max 0.75</span>':''}</td>
    <td class="num">${counted==null?'<span class="muted">not counted</span>':fmtNum(counted,1)}</td>
    <td class="num"${variance?` style="color:${variance<0?'#b91c1c':'#15803d'}"`:''}>${
      variance==null?'—':(variance>0?'+':'')+fmtNum(variance,1)}</td>
  </tr>`;
});
grid+='</tbody></table>';
grid+=`<p class="muted" style="font-size:12px;margin-top:8px;">
  Open bottles are a <strong>fraction of a bottle</strong> — write ¼, ½, ¾, not millilitres.
  Barn and crew are counted separately and added into one figure; leaving all four blank
  means <strong>not counted</strong>, which is not the same as zero.</p>`;

// ================= 3. ON HAND (after the count is posted) ===============
const oh=L.filter(l=>l.counted>0).map(l=>({
  medication_name:l.name, generic_category:l.cat, qty_units:l.counted, unit:l.unit,
  bottles_equiv:l.bottle_size?l.counted/l.bottle_size:null,
  avg_unit_cost:l.cost, value_fifo:l.counted*l.cost,
  oldest_layer_date:'2026-09-30',
  needs_container_size:false, unpriced_in_catalog:false,
  uncovered_units:0, unpriced_usage_units:0, expired_layer_count:0, expiring_soon_count:0
})).sort((a,b)=>a.generic_category.localeCompare(b.generic_category)||a.medication_name.localeCompare(b.medication_name));
const total=oh.reduce((s,r)=>s+(Number(r.value_fifo)||0),0);
let onhand=`<table><thead><tr>
  <th>Medication</th><th>Category</th><th class="num">Units</th><th>Unit</th>
  <th class="num">Bottles</th><th class="num">Avg $/unit</th><th class="num">Value</th>
  <th>Oldest</th><th>Flags</th></tr></thead><tbody>`;
oh.forEach(r=>{
  onhand+=`<tr>
    <td>${escapeHtml(r.medication_name)}</td>
    <td class="muted">${escapeHtml(r.generic_category||'')}</td>
    <td class="num">${fmtNum(r.qty_units,1)}</td>
    <td class="muted">${escapeHtml(r.unit||'')}</td>
    <td class="num">${r.bottles_equiv==null?'—':fmtNum(r.bottles_equiv,2)}</td>
    <td class="num">${r.avg_unit_cost==null?'—':'$'+Number(r.avg_unit_cost).toFixed(4)}</td>
    <td class="num">${fmtMoney(r.value_fifo)}</td>
    <td class="muted">${r.oldest_layer_date||'—'}</td>
    <td style="font-size:11px;"></td>
  </tr>`;
});
onhand+=`</tbody><tfoot><tr>
  <th colspan="6">Total at FIFO</th><th class="num">${fmtMoney(total)}</th><th colspan="2"></th>
</tr></tfoot></table>`;

const page=`<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Medicine inventory — office app preview</title>${CSS}
<style>
 body{background:#f3f4f6;padding:18px;}
 .preview-note{border-left:3px solid #b45309;background:#fffbeb;padding:10px 12px;margin:0 0 16px;font-size:12px;max-width:1180px}
 .shot{max-width:1180px;margin:0 auto 22px}
 .shot > h3{font:600 12px/1.4 -apple-system,Segoe UI,Roboto,sans-serif;letter-spacing:.4px;
   text-transform:uppercase;color:#6b7280;margin:0 0 6px}
</style></head><body>

<div class="shot">
<div class="preview-note"><strong>Preview, not a live screenshot.</strong> These are the office app's own
screens and stylesheet, filled with the real 9/30 count rows out of the database. Screen 3 shows what
<em>On hand</em> will read once the count is posted — today it is empty, because a draft count creates no
FIFO layers.</div>
</div>

<div class="shot"><h3>Inventory → Meds → Counts (today)</h3>
<div class="card"><div class="card-header"><h2>Counts</h2>
<button class="primary">+ New count</button></div>
<div id="a">${counts}</div></div></div>

<div class="shot"><h3>Count 2026-09-30 — the entry grid</h3>
<div class="card"><div class="card-header"><h2>Count 2026-09-30</h2>
<div style="display:flex;gap:8px;"><button>Print</button><button class="primary">Post count</button></div></div>
<div class="form-grid" style="margin-bottom:12px;">
 <div><label>Date</label><input type="date" value="2026-09-30"></div>
 <div><label>Location</label><select><option>Ranch</option></select></div>
 <div><label>Counted by</label><input value="John Reagan"></div>
 <div><label><input type="checkbox" checked> Opening count</label></div>
</div>
${grid}</div></div>

<div class="shot"><h3>Inventory → Meds → On hand (after the count is posted)</h3>
<div class="card"><div class="card-header"><h2>On hand</h2>
<div style="display:flex;gap:8px;"><button>Print count sheet</button><button>Refresh</button></div></div>
<div class="form-grid" style="margin-bottom:12px;">
 <div><label>Location</label><select><option>Ranch</option><option>Jake Taylor</option></select></div>
 <div><label><input type="checkbox"> Show meds with no stock</label></div>
</div>
${onhand}</div></div>

</body></html>`;
fs.writeFileSync('preview.html',page);
console.log('on hand rows',oh.length,'total',total.toFixed(2));
