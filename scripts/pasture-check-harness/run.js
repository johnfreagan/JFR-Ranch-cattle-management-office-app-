const fs=require('fs');
const html=fs.readFileSync(require('path').join(__dirname,'../../index.html'),'utf8');
function grab(name){
  const i=html.search(new RegExp('\\n\\s*(async )?function '+name+'\\('));
  if(i<0) throw new Error('missing '+name);
  let j=html.indexOf('{',html.indexOf('(',i)); // first brace after params
  // find end of params properly
  let depth=0,k=html.indexOf('(',i); for(;;k++){ if(html[k]==='(')depth++; else if(html[k]===')'){depth--; if(!depth)break;} }
  j=html.indexOf('{',k); depth=0;
  for(let m=j;;m++){ const c=html[m];
    if(c==='{')depth++; else if(c==='}'){depth--; if(!depth) return html.slice(i,m+1);} }
}
const names=['escapeHtml','addDaysIso','chicagoDayOf','approvalOverride','resolveApprovalEntry','apprFixPastureHtml','apprPlaceLabel','apprPlaceOptions'];
let src=names.map(grab).join('\n');
const R={Corner:'fe29e1f8-da13-4300-adb4-7df5458c5b78',Shop:'c200682c-0584-4a8f-8f49-b0436112fe82',Terrell:'501d4022-a0b9-4ac3-aa4f-976dacbd6a26',Garrett:'7105c0c4-a8d5-47de-a57b-257f40a6968b',R413:'d7f3e45e-3927-4629-b944-1d461b4dfcfa'};
const ranches=[['Corner',R.Corner],['Shop',R.Shop],['Terrell',R.Terrell],['Garrett',R.Garrett],['413',R.R413]].map(([n,id])=>({id,name:n,is_active:true}));
const P=[['1db5f291-2d7f-4077-a350-7e5ff883f0ee','1',R.Corner],['f360cf03-f82a-4fa8-9eb9-3da85cdd9a82','2',R.Corner],['f0bed281-9853-4fcf-b727-1dfcb1c679fc','3',R.Corner],['645b7f76-50de-4573-ac19-399864a3d5de','4',R.Corner],['14f28d10-2e1f-48ba-af92-1a4b193d662c','7',R.Corner],['4560744d-54dd-40fc-bc8b-014327dec022','8',R.Corner],['b4801c4a-3d1d-442c-a6bc-d394d1fb8079','H1',R.Corner],['6b64fefb-cc80-4d55-b764-6cebb4dcd910','H2',R.Corner],['e6641f75-169b-4a3d-b988-08ddebc89870','H3',R.Corner],['b4c902b6-c0c2-48dc-a8eb-84be4f0e09c7','Shop House',R.Shop],['faef017b-9f33-4dad-90ae-cc6330fc16dc','Goat Hill',R.Garrett],['b84d7363-dfa2-4012-8f36-ee5b23427aa8','Shelton',R.Terrell],['14285cd6-6a26-42fb-bc47-34ce68f58f82','Trap',R.R413]].map(([id,name,ranch_id])=>({id,name,ranch_id,is_active:true}));
const L36='5975076e-571d-4b24-bc60-bfcd15cf80d8', L32='512ab7b2-6ff8-4654-9f34-0f316d10d331', L32X='aaaaaaaa-0000-0000-0000-000000000032';
const lots=[{id:L36,lot_number:'36-27'},{id:L32,lot_number:'32-27'},{id:L32X,lot_number:'99-27'}];
const assign=[[L36,'b4c902b6-c0c2-48dc-a8eb-84be4f0e09c7',149],[L36,'e6641f75-169b-4a3d-b988-08ddebc89870',2],[L36,'faef017b-9f33-4dad-90ae-cc6330fc16dc',230],[L36,'14285cd6-6a26-42fb-bc47-34ce68f58f82',13],[L36,'b84d7363-dfa2-4012-8f36-ee5b23427aa8',299],[L36,'6b64fefb-cc80-4d55-b764-6cebb4dcd910',7],[L32,'1db5f291-2d7f-4077-a350-7e5ff883f0ee',84],[L32,'f360cf03-f82a-4fa8-9eb9-3da85cdd9a82',80],[L32,'f0bed281-9853-4fcf-b727-1dfcb1c679fc',42],[L32X,'b4801c4a-3d1d-442c-a6bc-d394d1fb8079',5]].map(([lot_id,pasture_id,head_count])=>({lot_id,pasture_id,head_count,moved_out:null}));
const actions=[{id:'a-fp',name:'First Pull EX',is_dead:false,once_per_animal:true,is_active:true},{id:'a-oth',name:'Other',is_dead:false,once_per_animal:false,is_active:true},{id:'a-dead',name:'Dead',is_dead:true,once_per_animal:true,is_active:true}];
const meds=[{id:'m-drax',name:'Draxxin',is_active:true,cost_per_unit:1,withdrawal_days:18},{id:'m-exc',name:'Excede',is_active:true,cost_per_unit:2,withdrawal_days:13},{id:'m-enro',name:'Enroflox(Baytril)',is_active:true,cost_per_unit:.2,withdrawal_days:28}];
const by=(rows,k)=>rows.reduce((m,r)=>(m[String(r[k]).trim().toLowerCase()]=r,m),{});
const id=rows=>rows.reduce((m,r)=>(m[r.id]=r,m),{});
const lk={lots:by(lots,'lot_number'),ranches:by(ranches,'name'),pastures:P,actions:by(actions,'name'),meds:by(meds,'name'),medsById:id(meds),lotsById:id(lots),actionsById:id(actions),pasturesById:id(P),ranchesById:id(ranches),assignments:assign};
const ctx={};
new Function('ctx',src+'\nctx.resolve=resolveApprovalEntry;ctx.fix=apprFixPastureHtml;')(ctx);
global.approvalsCache={lookups:lk};
// apprFixPastureHtml refers to approvalsCache global: rebind
new Function('ctx','approvalsCache',src+'\nctx.resolve=resolveApprovalEntry;ctx.fix=apprFixPastureHtml;')(ctx,{lookups:lk});
const mk=(o)=>Object.assign({id:'e'+Math.random(),entry_type:'doctoring',status:'pending',event_datetime:'2026-10-08T15:00:00Z',lot_id:null,pasture_id:null,to_pasture_id:null,field_action_id:null,tag_number:o.raw.tagNumber,head_count:null,resolved_meds:[],resolved_detail:null},o);
const raw=(loc,lot,tag,act='Other',m1='Draxxin',d1='6')=>({location:loc,lotNumber:lot,tagNumber:tag,treatmentType:act,medication1:m1,dosage1:d1,medication2:'',dosage2:'',medication3:'',dosage3:'',dateTime:'2026-10-08T10:55:00'});
let fails=0; const t=(name,cond)=>{console.log((cond?'PASS ':'FAIL ')+name); if(!cond)fails++;};
// 1 empty pasture, recall -> block, 6 places, fixable
let r=ctx.resolve(mk({raw:raw('Corner - 4','36-27','8569')}),lk);
t('empty pasture blocks', !r.ready && r.issues.some(i=>/empty on the books/.test(i)));
t('names where lot is', r.issues.some(i=>/Shop – Shop House/.test(i)));
t('six places, fixable', r.lotPlaces.length===6 && r.quickFixable);
t('row shows select for many', /appr-fixpast-sel/.test(ctx.fix(r)) && /Shelton \(299 hd\)/.test(ctx.fix(r)));
// 2 pasture with other lot
r=ctx.resolve(mk({raw:raw('Corner - 3','36-27','8458')}),lk);
t('other-lot pasture blocks', !r.ready && r.issues.some(i=>/not in Corner – 3 \(42 hd of other lots\)/.test(i)));
// 3 correct pasture -> ready
r=ctx.resolve(mk({raw:raw('Shop - Shop House','36-27','8824','First Pull EX','Excede','6')}),lk);
t('right pasture ready', r.ready && !r.lotPlaces.length);
r=ctx.resolve(mk({raw:raw('Corner - 1','32-27','22','First Pull EX','Excede','5')}),lk);
t('32-27 Corner 1 ready', r.ready);
// 4 single place -> button
r=ctx.resolve(mk({raw:raw('Corner - 4','99-27','5')}),lk);
t('single place button', r.quickFixable && r.lotPlaces.length===1 && /appr-fixpast"/.test(ctx.fix(r)) && /Use Corner – H1/.test(ctx.fix(r)));
// 5 unmatched med -> not quickfixable
r=ctx.resolve(mk({raw:raw('Corner - 4','36-27','1','Other','Mystery','5')}),lk);
t('bad med not quickfixable', !r.quickFixable && /✎ first/.test(ctx.fix(r)));
// 6 office chose a different pasture where lot is not -> warning only
r=ctx.resolve(mk({raw:raw('Corner - 4','36-27','9'),lot_id:L36,pasture_id:'1db5f291-2d7f-4077-a350-7e5ff883f0ee',field_action_id:'a-oth',resolved_meds:[{position:1,medication_id:'m-drax',dose:6}]}),lk);
t('office-chosen other pasture warns not blocks', r.ready && r.warnings.some(w=>/office chose/.test(w)));
// 7 office edited but kept the recall -> still blocks
r=ctx.resolve(mk({raw:raw('Corner - 4','36-27','9'),lot_id:L36,pasture_id:'645b7f76-50de-4573-ac19-399864a3d5de',field_action_id:'a-oth',resolved_meds:[{position:1,medication_id:'m-drax',dose:6}]}),lk);
t('office edit keeping recall still blocks', !r.ready);
// 8 quick-fix patch result: lot's pasture + meds kept -> ready, meds intact
r=ctx.resolve(mk({raw:raw('Corner - 4','36-27','9'),lot_id:L36,pasture_id:'b4c902b6-c0c2-48dc-a8eb-84be4f0e09c7',field_action_id:'a-oth',resolved_meds:[{position:1,medication_id:'m-drax',dose:6}]}),lk);
t('after fix ready with Draxxin 6', r.ready && r.meds.length===1 && r.meds[0].med.id==='m-drax' && r.meds[0].dose===6 && !r.warnings.length);
// 9 dead on empty pasture blocks too
r=ctx.resolve(mk({raw:Object.assign(raw('Corner - 4','36-27','8871','Dead','',''),{drugOff:'Yes'})}),lk);
t('dead on empty pasture blocks', !r.ready && r.kind==='dead');
// 10 cowboy confirmed off-books (field app v26) -> warn, not block
r=ctx.resolve(mk({raw:Object.assign(raw('Corner - 8','36-27','777'),{pastureOffBooks:true})}),lk);
t('cowboy-confirmed off-books warns', r.ready && r.warnings.some(w=>/cowboy confirmed/.test(w)));
// 11 office Keep as recorded -> warn, meds still the cowboy's
r=ctx.resolve(mk({raw:raw('Corner - 4','36-27','8569'),resolved_detail:{pasture_confirmed:true}}),lk);
t('office keep warns, raw meds kept', r.ready && r.warnings.some(w=>/Kept as recorded/.test(w)) && r.meds.length===1 && r.meds[0].med.id==='m-drax');
// 12 blocked row offers Keep next to the fix
r=ctx.resolve(mk({raw:raw('Corner - 4','36-27','8569')}),lk);
t('blocked row offers Keep', /appr-keeppast/.test(ctx.fix(r)) && /Keep Corner – 4/.test(ctx.fix(r)));
console.log(fails?fails+' FAILED':'ALL PASS'); process.exit(fails?1:0);
