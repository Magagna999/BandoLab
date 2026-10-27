'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loginAs, DAY } = require('./helpers/core');

const cfg = (o = {}) => Object.assign({ mode: 'training', title: 'Prova', key: 'k1', count: 5, filter: {} }, o);
// risponde a tutte le domande della sessione: correct = n corrette, wrong = n errate, il resto omesse
function answer(ctx, correct, wrong) {
  const { BL } = ctx; const rec = BL.rec(); const bank = BL.bank(); const ans = {};
  rec.session.items.forEach((it, i) => {
    const v = BL.versionOf(bank, it.qid, it.v);
    if (i < correct) ans[it.qid] = v.correct; else if (i < correct + wrong) ans[it.qid] = (v.correct + 1) % 4;
  });
  BL.saveSession({ answers: ans });
}

test('pool: solo domande pubblicate, non sospese né consolidate; filtri combinati', () => {
  const { BL } = loginAs('u-new');
  const bank = BL.bank();
  assert.equal(BL.pool(bank).length, 50);
  assert.equal(BL.pool(bank, { subjects: ['s-amm'] }).length, 13);
  assert.ok(BL.pool(bank, { difficulty: '2' }).every(q => BL.live(q).difficulty === 2));
  assert.equal(BL.pool(bank, { difficulty: 'mix' }).length, 50);
  const q = BL.pool(bank)[0]; q.suspended = true;
  assert.equal(BL.pool(bank).length, 49);
  q.suspended = false; q.mergedInto = 'x';
  assert.equal(BL.pool(bank).length, 49);
});

test('plan: distribuzione bilanciata tra materie, mai oltre il disponibile', () => {
  const { BL } = loginAs('u-new');
  const p = BL.plan(BL.bank(), {}, 12);
  assert.equal(p.rows.reduce((n, r) => n + r.planned, 0), 12);
  assert.ok(p.rows.every(r => r.planned === 2)); // 6 materie, round robin
  const small = BL.plan(BL.bank(), { subjects: ['s-eell'] }, 20);
  assert.equal(small.enough, false);
  assert.equal(small.available, 7);
  assert.equal(BL.plan(BL.bank(), {}, 0).enough, false);
});

test('buildQuiz: elementi unici, versione corrente, errore se non bastano domande', () => {
  const ctx = loginAs('u-new'); const { BL } = ctx;
  const b = BL.buildQuiz(BL.bank(), cfg({ count: 10 }), BL.rec());
  assert.equal(b.ok, true);
  assert.equal(b.items.length, 10);
  assert.equal(new Set(b.items.map(i => i.qid)).size, 10);
  const none = BL.buildQuiz(BL.bank(), cfg({ count: 500 }), BL.rec());
  assert.equal(none.ok, false); assert.equal(none.error, 'insufficient');
});

test('buildQuiz: con almeno 30 risposte in allenamento priorità agli errori passati', () => {
  const ctx = loginAs('u-reg'); const { BL } = ctx;
  const rec = BL.rec();
  const answers = rec.attempts.flatMap(a => a.items);
  assert.ok(answers.length >= 30);
  const wrong = new Set(answers.filter(i => i.answer != null && !i.correct).map(i => i.qid));
  assert.ok(wrong.size > 0);
  const b = BL.buildQuiz(BL.bank(), cfg({ count: 10 }), rec);
  assert.equal(b.prioritized, true);
  const nWrong = b.items.filter(i => wrong.has(i.qid)).length;
  assert.ok(nWrong >= Math.min(wrong.size, 5), 'gli errori devono essere inclusi');
  const ex = BL.buildQuiz(BL.bank(), cfg({ mode: 'exam', count: 10 }), rec);
  assert.equal(ex.prioritized, false); // la simulazione non priorizza
});

test('startSession: crea la sessione, simulazione con scadenza', () => {
  const ctx = loginAs('u-new'); const { BL } = ctx;
  const r = BL.startSession(cfg({ mode: 'exam', count: 10, durationMin: 20, key: 'e1' }));
  assert.equal(r.ok, true);
  assert.equal(r.session.deadline, ctx.now() + 20 * 60e3);
  assert.equal(BL.rec().session.items.length, 10);
  const t = loginAs('u-new'); // allenamento: nessuna scadenza
  assert.equal(t.BL.startSession(cfg()).session.deadline, null);
  assert.equal(loginAs('u-new').BL.startSession(cfg({ count: 999 })).ok, false);
});

test('finishSession: punteggio, XP 10 + corrette, notifica e sessione chiusa', () => {
  const ctx = loginAs('u-new'); const { BL } = ctx;
  BL.startSession(cfg({ count: 10 }));
  answer(ctx, 6, 3);
  ctx.advance(90e3);
  const r = BL.finishSession('completed');
  assert.equal(r.ok, true);
  const a = ctx.plain(r.attempt);
  assert.deepEqual([a.score.C, a.score.E, a.score.O, a.score.N], [6, 3, 1, 10]);
  assert.equal(a.durationSec, 90);
  assert.equal(BL.xp(BL.rec()), 16);
  assert.equal(BL.rec().session, null);
  assert.ok(BL.rec().notifications.some(n => n.title === 'Quiz completato'));
  assert.equal(BL.finishSession('x').ok, false); // nessuna sessione attiva
});

test('XP: dalla terza ripetizione dello stesso quiz in 24 ore non si guadagna XP', () => {
  const ctx = loginAs('u-new'); const { BL } = ctx;
  const run = () => { BL.startSession(cfg({ count: 5 })); answer(ctx, 5, 0); ctx.advance(60e3); return BL.finishSession('completed'); };
  assert.equal(ctx.plain(run().xp)[0].amount, 15);
  assert.equal(ctx.plain(run().xp)[0].amount, 15);
  const third = ctx.plain(run().xp)[0];
  assert.equal(third.amount, 0);
  ctx.advance(DAY);
  assert.equal(ctx.plain(run().xp)[0].amount, 15);
});

test('XP: +15 per il miglioramento in una simulazione comparabile', () => {
  const ctx = loginAs('u-new'); const { BL } = ctx;
  const exam = (c, w, key) => { BL.startSession(cfg({ mode: 'exam', count: 10, durationMin: 30, key })); answer(ctx, c, w); ctx.advance(60e3); return ctx.plain(BL.finishSession('completed').xp); };
  assert.equal(exam(4, 4, 'e1').length, 1);
  const second = exam(8, 1, 'e2');
  assert.equal(second.length, 2);
  assert.equal(second[1].amount, 15);
  assert.equal(exam(5, 0, 'e3').length, 1); // peggiore del precedente
  assert.ok(BL.badges(BL.rec()).find(b => b.id === 'improve').earned);
});

test('checkSession: simulazione scaduta consegnata in automatico al limite del tempo', () => {
  const ctx = loginAs('u-new'); const { BL } = ctx;
  assert.equal(BL.checkSession().state, 'none');
  BL.startSession(cfg({ mode: 'exam', count: 10, durationMin: 10, key: 'e1' }));
  answer(ctx, 5, 0);
  ctx.advance(5 * 60e3);
  assert.equal(BL.checkSession().state, 'active');
  ctx.advance(60 * 60e3);
  const r = BL.checkSession();
  assert.equal(r.state, 'expired');
  const a = ctx.plain(BL.rec().attempts.slice(-1)[0]);
  assert.equal(a.reason, 'timeout');
  assert.equal(a.durationSec, 600); // limitata alla scadenza, non all'ora attuale
  assert.equal(a.score.C, 5);
});

test('abandonSession e logInterruption', () => {
  const ctx = loginAs('u-new'); const { BL } = ctx;
  BL.startSession(cfg());
  BL.logInterruption('blur');
  assert.equal(BL.rec().session.interruptions.length, 1);
  assert.ok(BL.abandonSession().ok);
  const a = BL.rec().attempts.slice(-1)[0];
  assert.equal(a.status, 'abandoned'); assert.equal(a.score, null);
  assert.equal(BL.rec().session, null);
  assert.equal(BL.xp(BL.rec()), 0);
  assert.equal(BL.logInterruption('x'), undefined); // senza sessione non fa nulla
});

test('percorso: terminare una sessione di un percorso segna il passo come completato', () => {
  const ctx = loginAs('u-new'); const { BL } = ctx;
  const p = BL.bank().paths[0];
  const step = p.steps.find(s => s.type === 'quiz') || p.steps[0];
  BL.startSession(cfg({ count: 5, pathRef: { pid: p.id, sid: step.id } }));
  answer(ctx, 3, 1);
  BL.finishSession('completed');
  assert.equal(BL.rec().paths[p.id].status[step.id], 'done');
});

test('completeMaterial: +8 XP una sola volta e avanza i percorsi', () => {
  const ctx = loginAs('u-new'); const { BL } = ctx;
  const p = BL.bank().paths.find(x => x.steps.some(s => s.type === 'material'));
  const st = p.steps.find(s => s.type === 'material');
  BL.completeMaterial(st.ref); BL.completeMaterial(st.ref);
  assert.equal(BL.xp(BL.rec()), 8);
  assert.equal(BL.rec().paths[p.id].status[st.id], 'done');
});

test('markReviewed: +5 XP una sola volta per tentativo', () => {
  const { BL } = loginAs('u-new');
  assert.ok(BL.markReviewed('a1').ok);
  assert.equal(BL.markReviewed('a1').already, true);
  assert.equal(BL.xp(BL.rec()), 5);
});

test('notify: rispetta le preferenze dell\'utente', () => {
  const { BL } = loginAs('u-new');
  const rec = BL.rec();
  rec.prefs.notif.progress = false;
  BL.notify(rec, 'progress', 'T', 'B');
  assert.equal(rec.notifications.length, 0);
  BL.notify(rec, 'content', 'T', 'B');
  assert.equal(rec.notifications.length, 1);
  BL.notify(rec, 'altro', 'T', 'B'); // tipo senza preferenza: sempre consegnato
  assert.equal(rec.notifications.length, 2);
});

test('streak e attività: giorni consecutivi, anche partendo da ieri', () => {
  const ctx = loginAs('u-new'); const { BL } = ctx;
  assert.deepEqual(ctx.plain(BL.streak(BL.rec())), { days: 0, today: false });
  const day = () => { BL.startSession(cfg({ count: 5, key: 'd' + ctx.now() })); answer(ctx, 5, 0); ctx.advance(60e3); BL.finishSession('completed'); };
  day(); ctx.advance(DAY); day(); ctx.advance(DAY); day();
  assert.deepEqual(ctx.plain(BL.streak(BL.rec())), { days: 3, today: true });
  assert.ok(BL.badges(BL.rec()).find(b => b.id === 'streak3').earned);
  ctx.advance(DAY); // oggi non ancora attivo: la serie resta fino a ieri
  assert.deepEqual(ctx.plain(BL.streak(BL.rec())), { days: 3, today: false });
  ctx.advance(DAY); // un giorno saltato
  assert.equal(BL.streak(BL.rec()).days, 0);
});

test('badge: primo quiz e dieci quiz', () => {
  const ctx = loginAs('u-new'); const { BL } = ctx;
  const earned = () => ctx.plain(BL.badges(BL.rec()).filter(b => b.earned).map(b => b.id));
  assert.deepEqual(earned(), []);
  for (let i = 0; i < 10; i++) { BL.startSession(cfg({ count: 5, key: 'b' + i })); ctx.advance(1000); BL.finishSession('completed'); }
  assert.ok(earned().includes('first') && earned().includes('ten'));
});

test('stats: soglia dei 30 risposte e livello di preparazione per materia', () => {
  const ctx = loginAs('u-reg'); const { BL } = ctx;
  const s = BL.stats(BL.rec(), BL.bank(), {});
  assert.equal(s.nAttempts, 13);
  assert.equal(s.enough, s.nGiven >= 30);
  assert.ok(s.accuracy > 0 && s.accuracy < 1);
  s.bySubject.forEach(x => { if (x.readiness) assert.ok(['Base', 'Intermedio', 'Avanzato'].includes(x.readiness.level)); });
  const empty = loginAs('u-new').BL.stats(loginAs('u-new').BL.rec(), loginAs('u-new').BL.bank(), {});
  assert.equal(empty.enough, false); assert.equal(empty.accuracy, null);
});

test('stats: filtri per modalità e periodo', () => {
  const ctx = loginAs('u-reg'); const { BL } = ctx;
  const all = BL.stats(BL.rec(), BL.bank(), {}).nAttempts;
  const tr = BL.stats(BL.rec(), BL.bank(), { mode: 'training' }).nAttempts;
  const ex = BL.stats(BL.rec(), BL.bank(), { mode: 'exam' }).nAttempts;
  assert.equal(tr + ex, all);
  assert.ok(BL.stats(BL.rec(), BL.bank(), { period: '7' }).nAttempts <= all);
});
