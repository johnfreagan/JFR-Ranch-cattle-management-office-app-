(function(){
  const calls = window.__calls = [];
  const S = window.__state = { role: 'owner', approveError: null };
  const list = () => ([
    {report_date:'2026-09-30',status:'pending',loads:2,drop_target_lb:14200,drop_fed_lb:14191,ingredient_fed_lb:14191,
     by_pen:[{pen:'Corner - 1',pasture:'Corner 1',ranch:'Corner',pasture_name:'1',target_lb:6600,fed_lb:6591,moved:false,split:false},
             {pen:'Corner - 2',pasture:'Corner 2',ranch:'Corner',pasture_name:'2',target_lb:4600,fed_lb:4610,moved:false,split:false}],
     by_ingredient:[{pb_name:'Corn (Feed)',item:'Corn (Feed)',target_lb:5680,fed_lb:5676},{pb_name:'DDG',item:'DDG',target_lb:8520,fed_lb:8515}],
     bunk_scores:[],problems:[],notes:[],usage_rows:0},
    {report_date:'2026-09-29',status:'pending',loads:1,drop_target_lb:4600,drop_fed_lb:4520,ingredient_fed_lb:4520,
     by_pen:[{pen:'Garrett Hosp',pasture:null,ranch:null,pasture_name:null,target_lb:4600,fed_lb:4520}],
     by_ingredient:[{pb_name:'Cottonseed',item:null,target_lb:4600,fed_lb:4520}],
     bunk_scores:[],problems:['Pen "Garrett Hosp" does not match a pasture - tell Claude which pasture it is.'],
     notes:['PB shows MANUAL DELIVERY CHANGES this day - check them in PB; they are not imported.'],usage_rows:0},
    {report_date:'2026-09-28',status:'approved',loads:2,drop_target_lb:100,drop_fed_lb:0,ingredient_fed_lb:0,
     by_pen:[{pen:'Corner - 1',pasture:'Corner 1',target_lb:100,fed_lb:0}],by_ingredient:[],bunk_scores:[],problems:[],notes:[],
     usage_rows:15,reviewed_by:'John Reagan',reviewed_at:'2026-09-29T12:12:00Z',review_notes:null}
  ]);
  function builder(table){
    const q = { table, filters: [], head:false, single:false };
    const res = () => {
      calls.push({ kind:'from', table, filters:q.filters, op:q.op });
      if (q.op && q.op !== 'select') return { data: [], error: null };
      if (table === 'user_profiles') return { data: { id:'u1', role:S.role, is_active:true, full_name:'Test '+S.role }, error:null };
      if (q.head && table === 'pending_field_entries') return { data:null, count:3, error:null };
      if (q.head && table === 'pb_daily_reports') return { data:null, count:2, error:null };
      if (table === 'pb_daily_reports') return { data: [
        {report_date:'2026-09-30',gmail_message_id:'19a1b2c3d4',staged_at:'2026-09-25T11:05:00Z',status:'pending'},
        {report_date:'2026-09-29',gmail_message_id:'19a0ffff',staged_at:'2026-09-24T11:04:00Z',status:'pending'},
        {report_date:'2026-09-28',gmail_message_id:'19a0eeee',staged_at:'2026-09-23T11:04:00Z',status:'approved'}], error:null };
      if (table === 'ranch_settings') return { data: [{ pb_email_post_from: '2026-09-20' }], error:null };
      if (table === 'pastures') return { data: [
        {name:'1',ranches:{name:'Corner'}},{name:'2',ranches:{name:'Corner'}},{name:'H1',ranches:{name:'Corner'}},
        {name:'Front',ranches:{name:'Garrett'}}], error:null };
      return { data: q.single ? null : [], error: null, count: 0 };
    };
    const p = new Proxy(function(){}, {
      get(t, k){
        if (k === 'then') return (ok, bad) => Promise.resolve(res()).then(ok, bad);
        if (k === 'single' || k === 'maybeSingle') return () => { q.single = true; return p; };
        if (['insert','update','upsert','delete'].includes(k)) return () => { q.op = k; return p; };
        if (k === 'select') return (cols, o) => { if (o && o.head) q.head = true; return p; };
        return (...a) => { q.filters.push([k, ...a]); return p; };
      }
    });
    return p;
  }
  const client = {
    from: builder,
    rpc: async (fn, args) => {
      calls.push({ kind:'rpc', fn, args });
      if (fn === 'pb_report_list') return { data: list(), error: null };
      if (fn === 'approve_pb_report' && S.approveError) return { data:null, error:{ message:S.approveError } };
      return { data: {}, error: null };
    },
    auth: {
      getSession: async () => ({ data: { session: { user: { id:'u1', email:'t@x' } } } }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
      signOut: async () => ({}), getUser: async () => ({ data:{ user:{ id:'u1' } } })
    },
    get storage(){ return { from: () => ({ upload: async()=>({}), remove: async()=>({}), update: async()=>({}), createSignedUrl: async()=>({data:null}) }) }; },
    channel: () => ({ on(){ return this; }, subscribe(){ return this; } }), removeChannel(){}
  };
  window.supabase = { createClient: () => client };
})();
