// In-memory Supabase stand-in for the tap test. Reads come from window.__db
// fixtures with simple eq/is/in filters; writes and rpc() calls are recorded
// in window.__calls and answered with plausible success. Nothing leaves the page.
(function(){
  const calls = window.__calls = [];
  const db = window.__db;
  function applyFilters(rows, filters){
    return rows.filter(r => filters.every(([op, col, val]) => {
      if (typeof col !== 'string' || col.includes('(')) return true;
      const v = r[col];
      if (v === undefined) return true;
      if (op === 'eq') return String(v) === String(val);
      if (op === 'neq') return String(v) !== String(val);
      if (op === 'is') return val === null ? v == null : v === val;
      if (op === 'in') return (val || []).map(String).includes(String(v));
      if (op === 'gte') return v >= val;
      if (op === 'lte') return v <= val;
      return true;
    }));
  }
  function builder(table){
    const q = { table, filters: [], head: false, single: false, maybe: false, op: 'select', payload: null };
    const run = async () => {
      calls.push({ kind: 'from', table, op: q.op, payload: q.payload, filters: q.filters });
      if (q.op !== 'select') {
        const rows = Array.isArray(q.payload) ? q.payload : [q.payload || {}];
        const out = rows.map((r, i) => Object.assign({ id: table + '-new-' + calls.length + '-' + i }, r));
        if (q.op === 'update' || q.op === 'delete') {
          const hit = applyFilters(db[table] || [], q.filters);
          const res = hit.length ? hit.map(h => Object.assign({}, h, q.payload || {})) : out;
          return { data: q.single ? res[0] : res, error: null, count: res.length };
        }
        if (q.op === 'insert' || q.op === 'upsert') (db[table] = db[table] || []).push(...out);
        return { data: q.single ? out[0] : out, error: null, count: out.length };
      }
      const rows = applyFilters(db[table] || [], q.filters);
      if (q.head) return { data: null, count: rows.length, error: null };
      if (q.single) return { data: rows[0] || null, error: rows[0] || q.maybe ? null : { message: 'no rows' } };
      return { data: rows, error: null, count: rows.length };
    };
    const p = new Proxy(function(){}, {
      get(t, k){
        if (k === 'then') return (ok, bad) => run().then(ok, bad);
        if (k === 'single') return () => { q.single = true; return p; };
        if (k === 'maybeSingle') return () => { q.single = true; q.maybe = true; return p; };
        if (['insert','update','upsert','delete'].includes(k)) return (pl) => { q.op = k; q.payload = pl; return p; };
        if (k === 'select') return (cols, o) => { if (o && o.head) q.head = true; return p; };
        return (...a) => { q.filters.push([k, ...a]); return p; };
      }
    });
    return p;
  }
  const client = {
    from: builder,
    rpc: async (fn, args) => {
      calls.push({ kind: 'rpc', fn, args });
      const h = (window.__rpcAnswers || {})[fn];
      if (h !== undefined) return { data: typeof h === 'function' ? h(args) : h, error: null };
      return { data: [], error: null };
    },
    auth: {
      getSession: async () => ({ data: { session: { user: { id: window.__uid, email: 'office@test' } } } }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }),
      signOut: async () => ({}), getUser: async () => ({ data: { user: { id: window.__uid } } }),
      signInWithPassword: async () => ({ data: { user: { id: window.__uid } } })
    },
    get storage(){ return { from: () => ({ upload: async()=>({}), remove: async()=>({}), list: async()=>({data:[]}), createSignedUrl: async()=>({data:null}) }) }; },
    channel: () => ({ on(){ return this; }, subscribe(){ return this; } }), removeChannel(){}
  };
  window.supabase = { createClient: () => client };
})();
