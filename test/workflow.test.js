'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loadCore, loginAs } = require('./helpers/core');

// Dati demo: q90 bozza (u-ed), q91 in revisione (u-ed2), q92 modifiche richieste (u-ed),
// q12 pubblicata v1 con v2 in revisione (u-ed2). Utenti: u-ed/u-ed2 editor, u-rev revisore, u-adm admin.
const user = (BL, id) => BL.state().users.find(u => u.id === id);
const q = (BL, id) => BL.bank('demo').questions.find(x => x.id === id);
const last = (BL) => BL.state().audit[0];

function fullDraft(BL, actor) {
  const id = BL.createQuestion(actor).id;
  const r = BL.updateDraft(actor, id, {
    text: 'Quale organo approva il bilancio dello Stato?', options: ['Il Parlamento', 'Il Governo', 'La Corte dei conti', 'Il CNEL'],
    correct: 0, explanation: 'Il bilancio è approvato con legge.', subject: 's-amm', topic: BL.state().users && BL.bank('demo').taxonomy.topics.find(t => t.subject === 's-amm').id,
    difficulty: 2, source: 'Cost. art. 81', sourceUrl: 'https://www.normattiva.it', lastVerified: '2026-10-01', nextReview: '2027-10-01' });
  assert.ok(r.ok, JSON.stringify(r));
  return id;
}

test('permessi: matrice ruolo/azione', () => {
  const { BL } = loginAs('u-adm');
  const can = (uid, a) => BL.can(user(BL, uid), a).ok;
  assert.equal(can('u-reg', 'q.create'), false);
  assert.equal(can('u-ed', 'q.create'), true);
  assert.equal(can('u-ed', 'q.publish'), false);
  assert.equal(can('u-rev', 'q.publish'), true);
  assert.equal(can('u-rev', 'q.create'), false);
  assert.equal(can('u-adm', 'users.edit'), true);
  assert.equal(can('u-rev', 'tax.edit'), false);
  assert.equal(BL.can(null, 'q.create').ok, false);
});

test('permessi: l\'autore non revisiona il proprio contenuto, l\'admin sì', () => {
  const { BL } = loginAs('u-adm');
  const t = q(BL, 'q91'); // autore u-ed2
  // un revisore che fosse autore verrebbe bloccato: simuliamo cambiando l'autore
  BL.working(t).author = 'u-rev';
  const blocked = BL.can(user(BL, 'u-rev'), 'q.review', t);
  assert.equal(blocked.ok, false);
  assert.match(blocked.why, /Solo un amministratore/);
  BL.working(t).author = 'u-adm';
  assert.equal(BL.can(user(BL, 'u-adm'), 'q.review', t).ok, true);
});

test('validate: bozza vuota produce tutti gli errori attesi', () => {
  const { BL } = loginAs('u-adm');
  const id = BL.createQuestion(user(BL, 'u-ed')).id;
  const e = BL.validate(BL.working(q(BL, id)), BL.state().settings);
  ['text', 'options', 'correct', 'explanation', 'subject', 'topic', 'difficulty', 'source', 'sourceUrl', 'lastVerified', 'nextReview'].forEach(k => assert.ok(e[k], 'manca ' + k));
});

test('validate: date incoerenti e impostazioni opzionali', () => {
  const { BL } = loginAs('u-adm');
  const v = BL.working(q(BL, 'q91'));
  assert.deepEqual(Object.keys(BL.validate(v, BL.state().settings)), []);
  const bad = Object.assign({}, JSON.parse(JSON.stringify(v)), { nextReview: v.lastVerified });
  assert.ok(BL.validate(bad, BL.state().settings).nextReview);
  const noUrl = Object.assign({}, JSON.parse(JSON.stringify(v)), { sourceUrl: '' });
  assert.ok(BL.validate(noUrl, { requireUrl: true, requireExplanation: true }).sourceUrl);
  assert.equal(BL.validate(noUrl, { requireUrl: false, requireExplanation: true }).sourceUrl, undefined);
});

test('createQuestion: solo chi può creare; scrive audit', () => {
  const { BL } = loginAs('u-adm');
  assert.equal(BL.createQuestion(user(BL, 'u-reg')).ok, false);
  const r = BL.createQuestion(user(BL, 'u-ed'));
  assert.ok(r.ok);
  assert.equal(BL.working(q(BL, r.id)).status, 'draft');
  assert.equal(last(BL).action, 'Creazione bozza');
});

test('updateDraft: modifica bozza, rifiuta stati non modificabili e ruoli non autorizzati', () => {
  const { BL } = loginAs('u-adm');
  assert.ok(BL.updateDraft(user(BL, 'u-ed'), 'q90', { text: 'Testo aggiornato della bozza' }).ok);
  assert.equal(BL.working(q(BL, 'q90')).text, 'Testo aggiornato della bozza');
  assert.equal(BL.updateDraft(user(BL, 'u-ed'), 'q91', { text: 'xxxxxxxxxxxx' }).ok, false); // in revisione
  assert.equal(BL.updateDraft(user(BL, 'u-rev'), 'q90', { text: 'xxxxxxxxxxxx' }).ok, false); // ruolo
});

test('updateDraft: cambiando materia si ricalcolano i campi derivati', () => {
  const { BL } = loginAs('u-adm');
  const w = BL.working(q(BL, 'q90'));
  BL.updateDraft(user(BL, 'u-ed'), 'q90', { subject: 's-cost' });
  assert.equal(w.subject, 's-cost');
  assert.ok(Array.isArray(w.profiles));
});

test('updateDraft: id inesistente restituisce un errore senza eccezioni (comportamento voluto)', () => {
  const { BL } = loginAs('u-adm');
  const r = BL.updateDraft(user(BL, 'u-ed'), 'non-esiste', { text: 'xxxxxxxxxxxx' });
  assert.equal(r.ok, false);
  assert.match(r.why, /non trovata/i);
});

test('materialTransition: id inesistente restituisce un errore senza eccezioni (comportamento voluto)', () => {
  const { BL } = loginAs('u-adm');
  const r = BL.materialTransition(user(BL, 'u-adm'), 'non-esiste', 'submit');
  assert.equal(r.ok, false);
  assert.match(r.why, /non trovato/i);
});

test('transition: ciclo completo bozza → revisione → approvata → pubblicata', () => {
  const { BL } = loginAs('u-adm');
  const ed = user(BL, 'u-ed'), rev = user(BL, 'u-rev');
  const id = fullDraft(BL, ed);
  assert.ok(BL.transition(ed, id, 'submit').ok);
  assert.equal(BL.working(q(BL, id)).status, 'review');
  assert.ok(BL.transition(rev, id, 'approve').ok);
  const w = BL.working(q(BL, id));
  assert.equal(w.status, 'approved'); assert.equal(w.reviewer, 'u-rev');
  assert.ok(BL.transition(rev, id, 'publish').ok);
  const qq = q(BL, id);
  assert.equal(qq.current, 1); assert.equal(BL.isLive(qq), true);
  assert.equal(last(BL).action, 'Pubblicazione');
});

test('transition: invio bloccato se la validazione fallisce, con elenco errori', () => {
  const { BL } = loginAs('u-adm');
  const id = BL.createQuestion(user(BL, 'u-ed')).id;
  const r = BL.transition(user(BL, 'u-ed'), id, 'submit');
  assert.equal(r.ok, false);
  assert.ok(r.errors && r.errors.text);
});

test('transition: un editor non può approvare né pubblicare', () => {
  const { BL } = loginAs('u-adm');
  assert.equal(BL.transition(user(BL, 'u-ed'), 'q91', 'approve').ok, false);
  assert.equal(BL.transition(user(BL, 'u-ed'), 'q91', 'publish').ok, false);
});

test('transition: stati incoerenti vengono rifiutati', () => {
  const { BL } = loginAs('u-adm');
  const rev = user(BL, 'u-rev');
  assert.equal(BL.transition(rev, 'q90', 'approve').ok, false);   // bozza, non in revisione
  assert.equal(BL.transition(rev, 'q91', 'publish').ok, false);   // non approvata
  assert.equal(BL.transition(user(BL, 'u-ed'), 'q91', 'submit').ok, false); // già in revisione
  assert.equal(BL.transition(user(BL, 'u-ed'), 'q90', 'newVersion').ok, false); // non pubblicata
  assert.equal(BL.transition(user(BL, 'u-ed'), 'q90', 'reopen').ok, false);
  assert.equal(BL.transition(rev, 'zzz', 'approve').ok, false);   // inesistente
});

test('transition: modifiche richieste e sospensione richiedono una nota', () => {
  const { BL } = loginAs('u-adm');
  const rev = user(BL, 'u-rev');
  assert.equal(BL.transition(rev, 'q91', 'changes', '  ').ok, false);
  assert.equal(BL.transition(rev, 'q91', 'changes').ok, false);
  assert.ok(BL.transition(rev, 'q91', 'changes', 'Citare l\'articolo').ok);
  assert.equal(BL.working(q(BL, 'q91')).status, 'changes');
  assert.equal(BL.working(q(BL, 'q91')).reviewNote, 'Citare l\'articolo');
  assert.equal(BL.transition(rev, 'q01', 'suspend').ok, false);
  assert.ok(BL.transition(rev, 'q01', 'suspend', 'Norma abrogata').ok);
  assert.equal(q(BL, 'q01').suspended, true);
  assert.equal(BL.isLive(q(BL, 'q01')), false);
  assert.ok(BL.transition(rev, 'q01', 'unsuspend').ok);
  assert.equal(q(BL, 'q01').suspended, false);
});

test('transition: rifiuto e riapertura', () => {
  const { BL } = loginAs('u-adm');
  assert.ok(BL.transition(user(BL, 'u-rev'), 'q91', 'reject', 'Fuori programma').ok);
  assert.equal(BL.working(q(BL, 'q91')).status, 'rejected');
  assert.ok(BL.transition(user(BL, 'u-ed'), 'q91', 'reopen').ok);
  assert.equal(BL.working(q(BL, 'q91')).status, 'draft');
});

test('transition: nuova versione e pubblicazione sostituiscono la precedente', () => {
  const { BL } = loginAs('u-adm');
  const ed = user(BL, 'u-ed'), rev = user(BL, 'u-rev');
  const nv = BL.transition(ed, 'q01', 'newVersion', 'Aggiornamento');
  assert.ok(nv.ok);
  const qq = q(BL, 'q01');
  assert.equal(qq.versions.length, 2);
  const v2 = qq.versions[1];
  assert.equal(v2.status, 'draft'); assert.equal(v2.v, 2); assert.equal(v2.author, 'u-ed');
  assert.equal(BL.transition(ed, 'q01', 'newVersion').ok, false); // già in lavorazione
  assert.ok(BL.transition(ed, 'q01', 'submit').ok);
  assert.ok(BL.transition(rev, 'q01', 'approve').ok);
  assert.ok(BL.transition(rev, 'q01', 'publish').ok);
  assert.equal(qq.versions[0].status, 'superseded');
  assert.equal(qq.versions[1].status, 'published');
  assert.equal(qq.current, 2);
});

test('transition: verifica normativa aggiorna le date (12 mesi ≈ 365 giorni)', () => {
  const { BL } = loginAs('u-adm');
  assert.ok(BL.transition(user(BL, 'u-rev'), 'q01', 'verify').ok);
  const v = BL.live(q(BL, 'q01'));
  assert.equal(v.lastVerified, '2026-10-27');
  assert.equal(v.nextReview, BL.addDays('2026-10-27', Math.round(12 * 30.4)));
  assert.equal(BL.transition(user(BL, 'u-rev'), 'q90', 'verify').ok, false); // nessuna versione pubblicata
});

test('transition: revisore autore bloccato, admin autore consentito', () => {
  const { BL } = loginAs('u-adm');
  BL.working(q(BL, 'q91')).author = 'u-rev';
  assert.equal(BL.transition(user(BL, 'u-rev'), 'q91', 'approve').ok, false);
  BL.working(q(BL, 'q91')).author = 'u-adm';
  assert.ok(BL.transition(user(BL, 'u-adm'), 'q91', 'approve').ok);
  assert.ok(BL.transition(user(BL, 'u-adm'), 'q91', 'publish').ok);
});

test('materialTransition: cicli consentiti e vietati', () => {
  const { BL } = loginAs('u-adm');
  const draft = BL.bank('demo').materials.find(m => m.status === 'draft' && m.format === 'scheda');
  if (!draft) return; // nessuna scheda in bozza nei dati demo
  assert.equal(BL.materialTransition(user(BL, 'u-ed'), draft.id, 'publish').ok, false);
  assert.equal(BL.materialTransition(user(BL, 'u-rev'), draft.id, 'submit').ok, false); // ruolo
});

test('audit: ogni transizione aggiunge una riga con attore e versione', () => {
  const { BL } = loginAs('u-adm');
  const n = BL.state().audit.length;
  BL.transition(user(BL, 'u-rev'), 'q91', 'changes', 'nota');
  assert.equal(BL.state().audit.length, n + 1);
  const a = last(BL);
  assert.equal(a.actor, 'u-rev'); assert.equal(a.target, 'q91'); assert.equal(a.note, 'nota');
});

test('commit: se il salvataggio fallisce lo stato viene ripristinato', () => {
  const { BL } = loginAs('u-adm');
  BL.setDebug({ failSave: true });
  const before = JSON.stringify(q(BL, 'q90'));
  const r = BL.updateDraft(user(BL, 'u-ed'), 'q90', { text: 'Testo che non verrà salvato' });
  assert.equal(r.ok, false);
  assert.equal(JSON.stringify(q(BL, 'q90')), before);
});

test('setRole: protegge l\'ultimo amministratore e richiede il permesso', () => {
  const { BL } = loginAs('u-adm');
  const adm = user(BL, 'u-adm');
  assert.equal(BL.setRole(adm, 'u-adm', 'editor').ok, false);
  assert.equal(BL.setRole(user(BL, 'u-rev'), 'u-ed', 'admin').ok, false);
  assert.ok(BL.setRole(adm, 'u-reg', 'editor').ok);
  assert.equal(user(BL, 'u-reg').role, 'editor');
  assert.ok(BL.setRole(adm, 'u-reg', 'admin').ok);
  assert.ok(BL.setRole(adm, 'u-adm', 'editor').ok); // ora c'è un altro admin
});

test('taxEdit: crea e modifica voci del catalogo', () => {
  const { BL } = loginAs('u-adm');
  const adm = user(BL, 'u-adm');
  assert.equal(BL.taxEdit(user(BL, 'u-ed'), 'subjects', null, { name: 'X' }).ok, false);
  const n = BL.bank('demo').taxonomy.subjects.length;
  assert.ok(BL.taxEdit(adm, 'subjects', null, { name: 'Nuova materia' }).ok);
  assert.equal(BL.bank('demo').taxonomy.subjects.length, n + 1);
  assert.ok(BL.taxEdit(adm, 'subjects', 's-amm', { name: 'Amministrativo' }).ok);
  assert.equal(BL.bank('demo').taxonomy.subjects.find(s => s.id === 's-amm').name, 'Amministrativo');
});
