// Supabase stand-in for run-local.js: every rpc() and the few from()
// reads the Feed tab makes go to window.__rpc / window.__from, which the
// harness binds to psql on the scratch copy of the database, signed in as
// the user in window.__uid. Other tables answer empty.
(function(){
  const calls = window.__calls = [];
  function builder(table){
    const q = { table, filters: [], head: false, single: false, op: 'select' };
    const run = () => { calls.push({ kind: 'from', table }); return window.__from(q); };
    const p = new Proxy(function(){}, {
      get(t, k){
        if (k === 'then') return (ok, bad) => run().then(ok, bad);
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
    rpc: async (fn, args) => { calls.push({ kind: 'rpc', fn, args }); return window.__rpc(fn, args || {}); },
    auth: {
      getSession: async () => ({ data: { session: { user: { id: window.__uid, email: 't@x' } } } }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
      signOut: async () => ({}), getUser: async () => ({ data: { user: { id: window.__uid } } })
    },
    get storage(){ return { from: () => ({ upload: async()=>({}), remove: async()=>({}), update: async()=>({}), createSignedUrl: async()=>({data:null}) }) }; },
    channel: () => ({ on(){ return this; }, subscribe(){ return this; } }), removeChannel(){}
  };
  window.supabase = { createClient: () => client };
})();
