'use strict';
// Carica bandolab-core.js in un contesto isolato (vm) con localStorage, orologio e DOM finti.
// Ogni chiamata a loadCore() restituisce un'istanza nuova e indipendente.
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const CORE_PATH = path.join(__dirname, '..', '..', 'bandolab-core.js');
const CORE_SRC = fs.readFileSync(CORE_PATH, 'utf8');
const T0 = Date.UTC(2026, 9, 27, 10, 0, 0); // 27/10/2026 10:00 UTC

function makeStorage() {
  const d = new Map();
  return {
    getItem: k => (d.has(k) ? d.get(k) : null),
    setItem: (k, v) => { d.set(k, String(v)); },
    removeItem: k => { d.delete(k); },
    clear: () => d.clear(),
    _data: d
  };
}

function loadCore(opts = {}) {
  const clock = { now: opts.now ?? T0 };
  class FakeDate extends Date {
    constructor(...a) { if (a.length === 0) super(clock.now); else super(...a); }
    static now() { return clock.now; }
  }
  const localStorage = opts.localStorage || makeStorage();
  const sessionStorage = makeStorage();
  const sandbox = {
    localStorage, sessionStorage, Date: FakeDate, console,
    document: { documentElement: { dataset: {}, setAttribute() {}, style: {} }, head: { appendChild() {} }, createElement: () => ({}) }
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(CORE_SRC, sandbox, { filename: 'bandolab-core.js' });
  const BL = sandbox.BL;
  return {
    BL, localStorage, sessionStorage,
    setNow: t => { clock.now = typeof t === 'string' ? Date.parse(t) : t; },
    advance: ms => { clock.now += ms; },
    now: () => clock.now,
    // dato che il core gira in un altro contesto, questa funzione porta i risultati nel contesto del test
    plain: o => JSON.parse(JSON.stringify(o))
  };
}

// Carica il core, accede come utente (id come in USERS) nell'ambiente indicato
function loginAs(uid, env = 'demo', opts) {
  const ctx = loadCore(opts);
  ctx.BL.load();
  ctx.BL.login(uid, env);
  ctx.user = ctx.BL.state().users.find(u => u.id === uid);
  return ctx;
}

module.exports = { loadCore, loginAs, makeStorage, T0, DAY: 864e5 };
