'use strict';
// Client Supabase finto: registra le chiamate e risponde con dati preimpostati.
//   fake.rpcResults[nome] = { data, error } oppure funzione(args)
//   fake.tables[nome] = [righe]  (filtri eq applicati, order/limit ignorati salvo ordinamento semplice)
function makeFake() {
  const fake = { calls: [], rpcResults: {}, tables: {}, tableErrors: {}, session: null, authListeners: [], signedOut: false, oauth: null };
  fake.rpc = async (name, args) => {
    fake.calls.push({ type: 'rpc', name, args });
    const r = fake.rpcResults[name];
    if (r instanceof Error) throw r;
    return typeof r === 'function' ? r(args) : (r || { data: null, error: { message: 'nessun risultato preimpostato per ' + name } });
  };
  fake.from = table => {
    const f = { table, filters: [], cols: null };
    const builder = {
      select(cols) { f.cols = cols; return builder; },
      eq(col, val) { f.filters.push([col, val]); return builder; },
      order() { return builder; },
      limit() { return builder; },
      then(res, rej) {
        fake.calls.push({ type: 'select', table, cols: f.cols, filters: f.filters.slice() });
        if (fake.tableErrors[table]) return Promise.resolve({ data: null, error: fake.tableErrors[table] }).then(res, rej);
        const rows = (fake.tables[table] || []).filter(r => f.filters.every(([c, v]) => r[c] === v));
        return Promise.resolve({ data: rows, error: null }).then(res, rej);
      }
    };
    return builder;
  };
  fake.auth = {
    async signInWithOAuth(o) { fake.oauth = o; return { error: null }; },
    async signOut() { fake.signedOut = true; fake.session = null; return { error: null }; },
    async getSession() { return { data: { session: fake.session }, error: null }; },
    onAuthStateChange(cb) { fake.authListeners.push(cb); return { data: { subscription: { unsubscribe() { fake.authListeners = fake.authListeners.filter(x => x !== cb); } } } }; }
  };
  return fake;
}
module.exports = { makeFake };
