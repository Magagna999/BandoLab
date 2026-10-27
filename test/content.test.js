'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loginAs } = require('./helpers/core');

const user = (BL, id) => BL.state().users.find(u => u.id === id);
const q = (BL, id) => BL.bank('demo').questions.find(x => x.id === id);

test('search: query vuota, accenti, refusi (distanza 1) e categorie', () => {
  const { BL, plain } = loginAs('u-new');
  const bank = BL.bank();
  assert.deepEqual(plain(BL.search(bank, '')), []);
  assert.deepEqual(plain(BL.search(bank, '   ')), []);
  const ids = r => plain(r.map(g => g.id));
  const hit = BL.search(bank, 'amministrativo');
  assert.ok(ids(hit).includes('topics') || ids(hit).includes('materials') || ids(hit).includes('quiz'));
  assert.deepEqual(plain(BL.search(bank, 'zzzzqqq')), []);
  const typo = BL.search(bank, 'amministrativa'); // refuso/variante: tollerato
  assert.ok(Array.isArray(typo));
  const only = BL.search(bank, 'amministrativo', 'quiz');
  assert.ok(only.every(g => g.id === 'quiz'));
});

test('search: non restituisce contenuti non pubblicati', () => {
  const { BL } = loginAs('u-new');
  const bank = BL.bank();
  const draft = bank.materials.find(m => m.status !== 'published');
  assert.ok(draft, 'serve almeno un materiale non pubblicato nei dati demo');
  const res = BL.search(bank, draft.title, 'materials');
  assert.ok(res.every(g => g.items.every(i => i.id !== draft.id)));
});

test('duplicates: coppie simili nello stesso argomento, ordinate per similarità', () => {
  const { BL, plain } = loginAs('u-adm');
  const bank = BL.bank();
  const base = BL.working(q(BL, 'q01'));
  const a = q(BL, 'q02'); const va = BL.working(a);
  // forza una quasi-copia di q01 in q02
  Object.assign(va, { topic: base.topic, text: base.text, source: base.source, options: base.options.slice(), correct: base.correct });
  const d = plain(BL.duplicates(bank));
  const pair = d.find(x => (x.a === 'q01' && x.b === 'q02'));
  assert.ok(pair, 'la coppia deve essere rilevata');
  assert.ok(pair.sim >= 0.99);
  for (let i = 1; i < d.length; i++) assert.ok(d[i - 1].sim >= d[i].sim);
});

test('duplicates: le domande consolidate sono escluse; decideDuplicate merge', () => {
  const { BL, plain } = loginAs('u-adm');
  const base = BL.working(q(BL, 'q01')); const va = BL.working(q(BL, 'q02'));
  Object.assign(va, { topic: base.topic, text: base.text, source: base.source, options: base.options.slice(), correct: base.correct });
  assert.equal(BL.decideDuplicate(user(BL, 'u-ed'), 'q01', 'q02', 'merge').ok, false);
  assert.ok(BL.decideDuplicate(user(BL, 'u-rev'), 'q01', 'q02', 'merge', 'identiche').ok);
  assert.equal(q(BL, 'q02').mergedInto, 'q01');
  assert.equal(BL.isLive(q(BL, 'q02')), false);
  assert.ok(!plain(BL.duplicates(BL.bank())).some(x => x.a === 'q02' || x.b === 'q02'));
  assert.equal(BL.state().dupDecisions['q01|q02'].decision, 'merge');
});

test('decideDuplicate keep: mantiene entrambe', () => {
  const { BL } = loginAs('u-adm');
  assert.ok(BL.decideDuplicate(user(BL, 'u-rev'), 'q01', 'q02', 'keep').ok);
  assert.equal(q(BL, 'q02').mergedInto, null);
});

test('quizChecks: controlli superati sui dati demo e fallimento con troppe domande richieste', () => {
  const { BL, plain } = loginAs('u-adm');
  const bank = BL.bank(); const settings = BL.state().settings;
  const z = bank.quizzes[0];
  const ok = plain(BL.quizChecks(bank, z, settings));
  assert.equal(ok.length, 7);
  const big = plain(BL.quizChecks(bank, Object.assign({}, z, { count: 9999 }), settings));
  assert.equal(big.find(c => c.label === 'Numero di domande sufficiente').ok, false);
  const badAssoc = plain(BL.quizChecks(bank, Object.assign({}, z, { filter: { subjects: ['s-inesistente'] } }), settings));
  assert.equal(badAssoc.find(c => c.label === 'Associazioni valide').ok, false);
  assert.equal(badAssoc.find(c => c.label === 'Domande approvate e pubblicate').ok, false);
});

test('report: crea segnalazione per l\'utente corrente e notifica', () => {
  const { BL } = loginAs('u-reg');
  const n = BL.state().reports.length;
  assert.ok(BL.report('q01', 1, 'errore', 'Testo non chiaro').ok);
  const r = BL.state().reports[0];
  assert.equal(BL.state().reports.length, n + 1);
  assert.equal(r.status, 'open'); assert.equal(r.by, 'u-reg'); assert.equal(r.qid, 'q01');
  assert.ok(BL.rec().notifications.some(x => x.title === 'Segnalazione inviata'));
});

test('updateReport: assegnazione e risoluzione con permessi e notifica al segnalatore', () => {
  const ctx = loginAs('u-reg'); const { BL } = ctx;
  BL.report('q01', 1, 'errore', 'x');
  const rid = BL.state().reports[0].id;
  assert.equal(BL.updateReport(user(BL, 'u-ed'), rid, { assignee: 'u-rev' }, 'Assegnata').ok, false);
  assert.ok(BL.updateReport(user(BL, 'u-rev'), rid, { assignee: 'u-rev' }, 'Assegnata').ok);
  assert.ok(BL.updateReport(user(BL, 'u-rev'), rid, { status: 'resolved' }, 'Risolta').ok);
  const r = BL.state().reports.find(x => x.id === rid);
  assert.equal(r.status, 'resolved'); assert.equal(r.log.length, 2);
  assert.ok(BL.rec('u-reg', 'demo').notifications.some(n => n.title === 'Segnalazione gestita'));
});

test('parseText: titolo, sezioni, introduzione implicita e concetti chiave', () => {
  const { BL, plain } = loginAs('u-new');
  const r = plain(BL.parseText('# Titolo\nTesto iniziale\nsu due righe\n\n## Sezione A\nCorpo A\n\nSeconda parte\n\n## Concetti chiave\n- uno\n* due\n• tre\n'));
  assert.equal(r.title, 'Titolo');
  assert.equal(r.sections.length, 2);
  assert.equal(r.sections[0].title, 'Introduzione');
  assert.equal(r.sections[0].body, 'Testo iniziale su due righe');
  assert.equal(r.sections[1].body, 'Corpo A\n\nSeconda parte');
  assert.deepEqual(r.keyConcepts, ['uno', 'due', 'tre']);
  assert.deepEqual(plain(BL.parseText(null)), { title: '', sections: [], keyConcepts: [] });
  assert.deepEqual(plain(BL.parseText('\r\n# T\r\n## S\r\ncorpo\r\n')).sections, [{ title: 'S', body: 'corpo' }]);
});

test('validateMaterial: scheda e PDF', () => {
  const { BL, plain } = loginAs('u-new');
  const base = { title: 'Titolo valido', subject: 's-amm', topic: 't', source: 'Fonte', lastVerified: '2026-01-01', nextReview: '2027-01-01', format: 'scheda', sections: [{ title: 'A', body: 'x'.repeat(20) }] };
  assert.deepEqual(Object.keys(BL.validateMaterial(base, false)), []);
  assert.ok(BL.validateMaterial(Object.assign({}, base, { sections: [{ title: 'A', body: 'corto' }] }), false).sections);
  assert.ok(BL.validateMaterial(Object.assign({}, base, { title: 'ab' }), false).title);
  assert.ok(BL.validateMaterial(Object.assign({}, base, { nextReview: '2026-01-01' }), false).nextReview);
  const pdf = Object.assign({}, base, { format: 'pdf' });
  assert.ok(BL.validateMaterial(pdf, false).file);
  assert.equal(BL.validateMaterial(pdf, true).file, undefined);
});

test('materiali: creazione, modifica in bozza, ciclo di pubblicazione con ritiro', () => {
  const { BL } = loginAs('u-adm');
  const ed = user(BL, 'u-ed'), rev = user(BL, 'u-rev');
  assert.equal(BL.createMaterial(user(BL, 'u-reg')).ok, false);
  const id = BL.createMaterial(ed).id;
  const tp = BL.bank().taxonomy.topics.find(t => t.subject === 's-amm').id;
  assert.ok(BL.updateMaterial(ed, id, { title: 'Scheda di prova', subject: 's-amm', topic: tp, source: 'Fonte', sections: [{ title: 'Intro', body: 'Contenuto della scheda di prova.' }] }).ok);
  const m = BL.bank().materials.find(x => x.id === id);
  assert.equal(m.sections[0].id.startsWith(id + '-s1-'), true);
  assert.ok(Array.isArray(m.profiles));
  assert.ok(BL.materialTransition(ed, id, 'submit').ok);
  assert.equal(BL.updateMaterial(ed, id, { title: 'Altro titolo' }).ok, false); // non più in bozza
  assert.equal(BL.materialTransition(ed, id, 'approve').ok, false);
  assert.ok(BL.materialTransition(rev, id, 'approve').ok);
  assert.ok(BL.materialTransition(rev, id, 'publish').ok);
  assert.equal(m.status, 'published');
  assert.ok(BL.publishedMaterials(BL.bank()).some(x => x.id === id));
  assert.ok(BL.materialTransition(rev, id, 'unpublish').ok);
  assert.equal(m.status, 'draft');
  assert.equal(BL.updateMaterial(ed, 'zzz', {}).ok, false);
});

test('storeFile/getFile: salvataggio e lettura', () => {
  const { BL } = loginAs('u-new');
  assert.equal(BL.getFile('m1'), null);
  assert.ok(BL.storeFile('m1', { name: 'a.pdf', data: 'xx' }).ok);
  assert.equal(BL.getFile('m1').name, 'a.pdf');
});

test('stato: reset ripristina i dati demo; login/logout/me/env', () => {
  const { BL } = loginAs('u-adm');
  assert.equal(BL.me().id, 'u-adm'); assert.equal(BL.env(), 'demo');
  BL.updateDraft(user(BL, 'u-ed'), 'q90', { text: 'Modificato per il test' });
  BL.reset();
  assert.equal(BL.me(), null);
  assert.notEqual(BL.working(q(BL, 'q90')).text, 'Modificato per il test');
  BL.login('u-reg', 'real');
  assert.equal(BL.env(), 'real');
  BL.logout();
  assert.equal(BL.me(), null); assert.equal(BL.env(), 'demo');
});

test('persistenza: lo stato salvato sopravvive a un nuovo caricamento', () => {
  const a = loginAs('u-adm');
  a.BL.updateDraft(user(a.BL, 'u-ed'), 'q90', { text: 'Testo persistente nel browser' });
  const { loadCore } = require('./helpers/core');
  const b = loadCore({ localStorage: a.localStorage });
  b.BL.load();
  assert.equal(b.BL.working(q(b.BL, 'q90')).text, 'Testo persistente nel browser');
});

test('migrazione: domande mancanti vengono aggiunte a uno stato salvato più vecchio', () => {
  const a = loginAs('u-adm');
  const key = [...a.localStorage._data.keys()].find(k => /state|bandolab/.test(k) && !/files/.test(k));
  const st = JSON.parse(a.localStorage.getItem(key));
  st.data.demo.questions = st.data.demo.questions.filter(x => x.id !== 'q90');
  a.localStorage.setItem(key, JSON.stringify(st));
  const { loadCore } = require('./helpers/core');
  const b = loadCore({ localStorage: a.localStorage });
  b.BL.load();
  assert.ok(q(b.BL, 'q90'), 'q90 deve essere reinserita');
  assert.equal(b.BL.bank('demo').questions.length, 53);
});
